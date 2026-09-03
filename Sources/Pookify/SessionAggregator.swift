import Foundation
import IslandCore

/// One session as the UI shows it: its effective (display) state plus the strings the pill and
/// the session stack render. `id` is the hook's session id, so a row keeps its identity across
/// polls (SwiftUI diffing and terminal activation).
struct SessionInfo: Identifiable, Equatable {
    let id: String
    var pid: Int32            // Copilot CLI process; its ancestry identifies the terminal app
    var provider: Provider
    var state: AgentState   // effective state (caps/lingers applied)
    var label: String       // "Editing", "Thinking…", "Awaiting permission", …
    var detail: String      // file basename while in a tool, else empty
    var project: String     // basename of the session's cwd
    var startedAt: Double   // turn clock start (0 = no active turn)
}

/// Turns the set of on-disk session files into a single decision about what the island should
/// show. Stateless: it reaps dead sessions, recovers frozen ones, and surfaces every live
/// session, ordered by urgency (a permission request always beats one merely working).
struct IslandDecision {
    /// Open sessions, most deserving of attention first: highest priority, then the newest turn.
    /// `startedAt` (not `ts`) breaks ties so rows don't shuffle mid-turn as heartbeats land.
    var sessions: [SessionInfo]
    var visible: Bool
    var liveCount: Int
    var forceExpand: Bool

    static let hidden = IslandDecision(sessions: [], visible: false,
                                       liveCount: 0, forceExpand: false)
}

enum SessionAggregator {

    /// How long a transient state stays on screen before the island collapses.
    static let doneLinger: TimeInterval = 2.5
    static let errorLinger: TimeInterval = 3.5
    // Display caps: when a session stops updating unexpectedly, its last
    // state must not stay on screen forever, so a quiet session goes *display-idle* after a
    // while — WITHOUT deleting its file, so a tool that finally reports back (a 10-minute build,
    // a long test run) resumes with its label and turn clock intact.
    // A tool that is still running (toolEndsAt == 0) gets a long window; quiet reasoning
    // (thinking / a finished tool) goes idle much sooner; permission may legitimately sit.
    static let permissionCap: TimeInterval = 7200
    // Generous backstop for a turn that ends without an agentStop or sessionEnd hook. A later hook
    // immediately revives the session, so a long-running tool can still report completion.
    static let workBackstopCap: TimeInterval = 900
    // Snapshots without a process identifier cannot prove liveness, so eventually reap them.
    // A snapshot with a live Copilot PID must never age out: users routinely leave an idle
    // terminal open for hours and still expect it to remain selectable.
    static let orphanReapCap: TimeInterval = 7200

    static func pidAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// The state a session effectively contributes right now.
    ///
    /// Time caps are only zombie backstops. Copilot's agentStop and sessionEnd hooks normally
    /// provide deterministic turn and process completion.
    static func effectiveState(_ s: SessionSnapshot, now: Double) -> AgentState {
        func aliveWithin(_ cap: TimeInterval) -> Bool {
            now - s.ts <= cap
        }
        switch s.state {
        case .thinking:
            return aliveWithin(workBackstopCap) ? .thinking : .idle
        case .tool:
            // A finished tool (toolEndsAt > 0) lingers briefly so fast tools are visible, then the
            // session is back to reasoning — surface that as thinking, not a stale tool label.
            if s.toolEndsAt > 0 && now > s.toolEndsAt {
                return aliveWithin(workBackstopCap) ? .thinking : .idle
            }
            return aliveWithin(workBackstopCap) ? .tool : .idle
        case .permission:
            return (now - s.ts > permissionCap) ? .idle : .permission
        case .done:
            // A just-finished turn flashes .done briefly (the collapsed check), then settles into
            // .completed — kept in the stack as "Done" rather than vanishing, so you can glance at
            // the island and see which sessions have finished. It clears when the session's next
            // turn overwrites the file (back to thinking/tool) or the session closes (file reaped).
            return (now - s.ts <= doneLinger) ? .done : .completed
        case .error:
            // An errored turn must NOT rest as "Done" — after its flash it goes display-idle, as
            // before. (A resting "failed" row would need its own state to stay honest.)
            return (now - s.ts <= errorLinger) ? .error : .idle
        case .completed:
            return .completed
        case .idle:
            return .idle
        }
    }

    /// Read all files, reap dead ones, and decide what to surface.
    static func evaluate(now: Double = Date().timeIntervalSince1970) -> IslandDecision {
        var candidates: [(url: URL, snapshot: SessionSnapshot)] = []
        for url in StateStore.listFiles() {
            guard let snap = StateStore.read(url) else { continue }
            // Delete a tracked process only on hard evidence that it died. The age cap applies
            // exclusively to pid-less snapshots, where liveness cannot be established.
            let processGone = snap.pid > 0 && !pidAlive(snap.pid)
            let orphanExpired = snap.pid <= 0 && now - snap.ts > orphanReapCap
            if processGone || orphanExpired {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            candidates.append((url, snap))
        }

        // Switching or forking a session can leave an old session ID attached to the same live
        // Copilot process. Keep only that process's newest snapshot so stale "Done" rows cannot
        // survive beside its current working state.
        var newestByPID: [Int32: (url: URL, snapshot: SessionSnapshot)] = [:]
        var live = candidates.filter { $0.snapshot.pid <= 0 }.map(\.snapshot)
        for candidate in candidates where candidate.snapshot.pid > 0 {
            let pid = candidate.snapshot.pid
            guard let existing = newestByPID[pid] else {
                newestByPID[pid] = candidate
                continue
            }
            let current = candidate.snapshot
            let previous = existing.snapshot
            let replace = current.ts > previous.ts
                || (current.ts == previous.ts && current.sessionId > previous.sessionId)
            if replace {
                try? FileManager.default.removeItem(at: existing.url)
                newestByPID[pid] = candidate
            } else {
                try? FileManager.default.removeItem(at: candidate.url)
            }
        }
        live.append(contentsOf: newestByPID.values.map(\.snapshot))

        // Finished sessions stay visible until their process exits, sessionEnd removes them, or a
        // new prompt overwrites their state. This keeps the ready count useful even after every
        // running session has finished instead of retracting precisely when results are waiting.
        let effs = live.map { effectiveState($0, now: now) }
        func displayState(_ i: Int) -> AgentState {
            effs[i]
        }

        // Every live local CLI process keeps the app available, including an idle terminal. This
        // makes all open sessions selectable rather than making an idle one disappear from a
        // two-session stack.
        let liveCount = live.count
        guard !live.isEmpty else { return .hidden }

        // Every open session gets a row. A stale working state may resolve to idle, but the live
        // process remains selectable and will update again on its next prompt.
        let sessions: [SessionInfo] = live.indices.map { i -> SessionInfo in
            let eff = displayState(i)
            let s = live[i]
            return SessionInfo(
                id: s.sessionId,
                pid: s.pid,
                provider: s.provider,
                state: eff,
                // When a tool has lingered out to thinking, show "Thinking…" rather than the stale tool label.
                label: (s.state == .tool && eff == .thinking) ? "Thinking…" : s.label,
                // The file subtitle only makes sense while actually in a tool (not once it lingers out).
                detail: eff == .tool ? s.detail : "",
                project: s.project,
                startedAt: s.startedAt
            )
        }.sorted { a, b in
            if a.state.priority != b.state.priority { return a.state.priority > b.state.priority }
            // The newest TURN first — `startedAt` is stable for a turn's whole life, so rows never
            // shuffle just because one session's heartbeat (`ts`) landed after another's.
            if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
            return a.id < b.id
        }

        return IslandDecision(
            sessions: sessions,
            visible: !sessions.isEmpty,
            liveCount: liveCount,
            forceExpand: sessions.first?.state == .permission
        )
    }
}
