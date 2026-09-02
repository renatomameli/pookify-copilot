import Foundation
import IslandCore

// island-hook bridges GitHub Copilot CLI lifecycle hooks to the notch app.
//
// Invoked as: island-hook copilot <kind>
//   kind: session-start | prompt | pre | post | post-fail | notify |
//         subagent-start | subagent-stop | compact | stop | error | session-end
//
// Copilot sends JSON on stdin. The helper deliberately emits no stdout and always exits 0 so
// status reporting can never change a tool result or permission decision.

let args = CommandLine.arguments
let providerArg = args.count > 1 ? args[1] : ""
let kind = args.count > 2 ? args[2] : ""
let provider = Provider(rawValue: providerArg) ?? .copilot

let rawInput = FileHandle.standardInput.readDataToEndOfFile()
let payload = (try? JSONSerialization.jsonObject(with: rawInput) as? [String: Any]) ?? [:]

func value(_ keys: [String]) -> Any? {
    for key in keys {
        if let value = payload[key] { return value }
    }
    return nil
}

func string(_ keys: String...) -> String {
    value(keys) as? String ?? ""
}

func bool(_ keys: String...) -> Bool {
    value(keys) as? Bool ?? false
}

func dictionary(_ keys: String...) -> [String: Any] {
    guard let raw = value(keys) else { return [:] }
    if let object = raw as? [String: Any] { return object }
    if let text = raw as? String,
       let data = text.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return object
    }
    return [:]
}

func now() -> Double { Date().timeIntervalSince1970 }

func payloadTimestamp() -> Double {
    if let number = value(["timestamp"]) as? NSNumber {
        let raw = number.doubleValue
        return raw > 10_000_000_000 ? raw / 1000 : raw
    }
    let raw = string("timestamp")
    if !raw.isEmpty, let date = ISO8601DateFormatter().date(from: raw) {
        return date.timeIntervalSince1970
    }
    return now()
}

let hookParentPID = getppid()
let sessionPID: Int32 = {
    guard let raw = ProcessInfo.processInfo.environment["COPILOT_SESSION_PID"],
          let parsed = Int32(raw), parsed > 0 else { return hookParentPID }
    return parsed
}()

let sessionId: String = {
    let supplied = string("sessionId", "session_id")
    return supplied.isEmpty ? "pid-\(sessionPID)" : supplied
}()
let cwd = string("cwd")
let project = cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent
let prev = StateStore.read(StateStore.fileURL(provider: provider, sessionId: sessionId))
let eventAt = payloadTimestamp()

let toolLingerSeconds = 1.9
let debugOn = ProcessInfo.processInfo.environment["ISLAND_DEBUG"] == "1"
    || FileManager.default.fileExists(
        atPath: Island.supportDir.appendingPathComponent("debug-on").path
    )

func debugLog(_ message: String) {
    guard debugOn else { return }
    Island.ensureDirs()
    let line = "\(Date()) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: Island.debugLog) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: Island.debugLog)
    }
}

func launchApp() {
    guard ProcessInfo.processInfo.environment["ISLAND_NO_LAUNCH"] != "1" else { return }
    guard !FileManager.default.fileExists(atPath: Island.installLockFile.path) else {
        debugLog("    skipped app launch while installation is in progress")
        return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", "-b", Island.bundleID]
    try? process.run()
    if let path = ProcessInfo.processInfo.environment["ISLAND_APP_PATH"], !path.isEmpty {
        let developmentApp = Process()
        developmentApp.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        developmentApp.arguments = ["-g", path]
        try? developmentApp.run()
    }
}

func appIsRunning() -> Bool {
    guard let raw = try? String(contentsOf: Island.appPidFile, encoding: .utf8),
          let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          pid > 0 else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
}

func toolDetail() -> String {
    let input = dictionary("toolArgs", "tool_input")
    for key in ["file_path", "notebook_path", "path"] {
        if let path = input[key] as? String, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
    }
    return ""
}

func writeState(_ state: AgentState, label: String, tool: String = "",
                startedAt: Double, toolEndsAt: Double = 0, detail: String = "") {
    let snapshot = SessionSnapshot(
        provider: provider,
        sessionId: sessionId,
        state: state,
        label: label,
        tool: tool,
        project: project.isEmpty ? (prev?.project ?? "") : project,
        cwd: cwd.isEmpty ? (prev?.cwd ?? "") : cwd,
        pid: sessionPID,
        startedAt: startedAt,
        ts: eventAt,
        toolEndsAt: toolEndsAt,
        detail: detail
    )
    StateStore.write(snapshot)
    debugLog("[\(String(sessionId.prefix(8)))] \(kind) -> \(state.rawValue) \(label)")
}

func turnStart() -> Double {
    guard let startedAt = prev?.startedAt, startedAt > 0 else { return now() }
    return startedAt
}

// Command and asynchronous notification hooks can finish out of order. An event created before
// the current snapshot must not overwrite newer activity (for example, a delayed agentStop
// changing a newly-started turn back to Done).
if let previous = prev, eventAt + 0.001 < previous.ts {
    debugLog(
        "[\(String(sessionId.prefix(8)))] ignored stale \(kind) event "
        + "(\(eventAt) < \(previous.ts))"
    )
    exit(0)
}

switch kind {
case "session-start":
    StateStore.removeOtherSessions(provider: provider, pid: sessionPID, keeping: sessionId)
    writeState(.idle, label: "", startedAt: 0)

case "prompt":
    StateStore.removeOtherSessions(provider: provider, pid: sessionPID, keeping: sessionId)
    // Copilot does not expose a turn id, but this event fires exactly once for each submitted
    // prompt, making it the authoritative point at which to restart the turn clock.
    writeState(.thinking, label: "Thinking...", startedAt: now())

case "pre":
    let tool = string("toolName", "tool_name")
    writeState(.tool, label: toolLabel(provider: provider, tool: tool), tool: tool,
               startedAt: turnStart(), detail: toolDetail())

case "post", "post-fail":
    let eventTool = string("toolName", "tool_name")
    let tool = eventTool.isEmpty ? (prev?.tool ?? "") : eventTool
    if tool.isEmpty {
        writeState(.thinking, label: "Thinking...", startedAt: turnStart())
    } else {
        let detail = toolDetail().isEmpty ? (prev?.detail ?? "") : toolDetail()
        writeState(.tool, label: toolLabel(provider: provider, tool: tool), tool: tool,
                   startedAt: turnStart(), toolEndsAt: now() + toolLingerSeconds,
                   detail: detail)
    }

case "subagent-start":
    let agent = string("agentDisplayName", "agentName", "agent_display_name", "agent_name")
    writeState(.tool, label: agent.isEmpty ? "Delegating" : "Delegating to \(agent)",
               tool: "task", startedAt: turnStart())

case "subagent-stop":
    if let previous = prev, previous.state == .thinking || previous.state == .tool {
        writeState(.thinking, label: "Thinking...", startedAt: turnStart())
    }

case "compact":
    writeState(.tool, label: "Compacting...", tool: "compact",
               startedAt: turnStart())

case "notify":
    switch string("notification_type", "notificationType").lowercased() {
    case "permission_prompt":
        writeState(.permission, label: "Awaiting permission",
                   startedAt: turnStart())
    case "elicitation_dialog":
        writeState(.permission, label: "Input requested",
                   startedAt: turnStart())
    default:
        break
    }

case "stop":
    writeState(.done, label: "Done", startedAt: 0)

case "error":
    if bool("recoverable") {
        writeState(.thinking, label: "Recovering...", startedAt: turnStart())
    } else {
        writeState(.error, label: "Error", startedAt: 0)
    }

case "session-end":
    StateStore.remove(provider: provider, sessionId: sessionId)

default:
    break
}

if kind != "session-end", !appIsRunning() {
    launchApp()
}

exit(0)
