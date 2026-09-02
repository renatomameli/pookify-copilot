import Foundation
import IslandCore

/// One session as the UI shows it: its effective (display) state plus the strings the pill and
/// the session stack render. `id` is the hook's session id, so a row keeps its identity across
/// polls (SwiftUI diffing and terminal activation).
struct SessionInfo: Identifiable, Equatable {
    let id: String
    var pid: Int32            // Copilot CLI process; its ancestry identifies the terminal app
    var provider: Provider
    var state: AgentState   // effective state (caps/lingers applied), never .idle here
    var label: String       // "Editing", "Thinking…", "Awaiting permission", …
    var detail: String      // file basename while in a tool, else empty
    var project: String     // basename of the session's cwd
    var startedAt: Double   // turn clock start (0 = no active turn)
}

/// Turns the set of on-disk session files into a single decision about what the island should
/// show. Stateless: it reaps dead sessions, recovers frozen ones, and surfaces every live
/// session, ordered by urgency (a permission request always beats one merely working).
struct IslandDecision {
    /// Non-idle sessions, most deserving of attention first: highest priority, then the newest
    /// turn. `startedAt` (not `ts`) breaks ties so rows don't shuffle mid-turn as heartbeats land.
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
    // How long past its last update an idle session keeps the app alive.
    static let appHold: TimeInterval = 300
    // Hard reap: delete a file this old no matter what (protects against pid reuse and junk
    // buildup from sessions that never fire sessionEnd).
    static let reapCap: TimeInterval = 7200

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
            // Delete a file only on hard evidence: its process died, or it is ancient. Mere
            // staleness hides the session (display-idle above) but keeps the file, preserving
            // turn-clock continuity for tools that go quiet for a long time.
            let processGone = snap.pid > 0 && !pidAlive(snap.pid)
            if processGone || now - snap.ts > reapCap {
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

        // Effective state per session, then a visibility rule for finished ("completed") ones.
        // A finished session stays on screen only while ANY other session is still active
        // (working / permission / a transient done-or-error flash) — that's when "1 done, 1
        // still going" is worth a glance. The moment nothing is active the completed ones go
        // display-idle too and the island recedes, exactly as a single session always has:
        // with one session the done flash plays and the notch goes dark, pixel-identical to
        // the pre-stack behavior.
        let effs = live.map { effectiveState($0, now: now) }
        let anyActive = effs.contains { $0 != .idle && $0 != .completed }
        func displayState(_ i: Int) -> AgentState {
            let e = effs[i]
            if e == .completed, !anyActive { return .idle }
            return e
        }

        // Sessions that are visibly doing something — or only went quiet moments ago — keep the
        // app alive. Long-idle files (e.g. closed extension sessions whose host pid persists)
        // don't, so the app can still quit itself.
        let liveCount = live.indices.filter {
            displayState($0) != .idle || now - live[$0].ts <= appHold
        }.count
        guard !live.isEmpty else { return .hidden }

        // Every session with something to say, as the UI will render it. Display-idle sessions
        // are omitted (they're resting, not gone — their files persist for turn-clock continuity).
        let sessions: [SessionInfo] = live.indices.compactMap { i -> SessionInfo? in
            let eff = displayState(i)
            guard eff != .idle else { return nil }
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
            visible: !sessions.isEmpty,   // hide while everything rests; the app stays alive
            liveCount: liveCount,
            forceExpand: sessions.first?.state == .permission
        )
    }
}
