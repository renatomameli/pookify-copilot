import Foundation

/// Reads Copilot's own session metadata from `~/.copilot/session-state`.
///
/// Hooks remain the source of truth for activity; this only adds what hooks do not carry: the
/// session's display name and whether a turn finally failed after its retries.
enum CopilotSessionNames {
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["ISLAND_COPILOT_STATE_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot/session-state")
    }

    private static let lock = NSLock()
    private static var cache: [String: (name: String?, at: Date)] = [:]
    private static let cacheLifetime: TimeInterval = 5

    /// The session's display name (Copilot titles its terminal "<name> - GitHub Copilot").
    /// Rows found only through process discovery have no hook session ID; for those, use the
    /// session the process holds open most recently. Cached briefly: the poll loop asks often.
    static func name(sessionID: String, copilotPID: Int32) -> String? {
        let key = "\(sessionID)#\(copilotPID)"
        lock.lock()
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < cacheLifetime {
            lock.unlock()
            return hit.name
        }
        lock.unlock()

        let name = directory(sessionID: sessionID, copilotPID: copilotPID).flatMap(name(in:))
        lock.lock()
        cache[key] = (name, Date())
        lock.unlock()
        return name
    }

    static func directory(sessionID: String, copilotPID: Int32) -> URL? {
        if !sessionID.hasPrefix("process-") {
            let direct = root.appendingPathComponent(sessionID)
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
        }
        return newestSessionDirectory(heldBy: copilotPID)
    }

    private static func name(in directory: URL) -> String? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("workspace.yaml"),
                                     encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("name:") {
            var value = line.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func newestSessionDirectory(heldBy pid: Int32) -> URL? {
        guard pid > 0, let directories = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return nil }
        let lockName = "inuse.\(pid).lock"
        func modified(_ url: URL) -> Date {
            let events = url.appendingPathComponent("events.jsonl")
            return (try? events.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        return directories
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(lockName).path) }
            .max { modified($0) < modified($1) }
    }
}

/// Detects a turn that Copilot abandoned after exhausting its retries.
///
/// Every failed model call fires `errorOccurred` with `recoverable: true` — including the last
/// one, after which Copilot gives up ("Execution failed … retried 5 times") without an
/// `agentStop`. Only its event log tells the two apart, via a trailing `session.error`.
enum CopilotTurnFailure {
    private static let lock = NSLock()
    private static var cache: [String: (size: UInt64, failed: Bool)] = [:]
    private static let tailBytes: UInt64 = 64 * 1024

    /// Events that prove the session moved on after an error (a retry, a new turn, a tool).
    private static let progress: Set<String> = [
        "assistant.turn_start", "assistant.message", "model.turn_retry", "model.model_call_started",
        "model.model_call_success", "tool.execution_start", "user.message",
    ]

    static func failed(sessionID: String, copilotPID: Int32) -> Bool {
        guard let directory = CopilotSessionNames.directory(sessionID: sessionID, copilotPID: copilotPID)
        else { return false }
        let url = directory.appendingPathComponent("events.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }

        lock.lock()
        if let hit = cache[url.path], hit.size == size {
            lock.unlock()
            return hit.failed
        }
        lock.unlock()

        let start = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var failed = false
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "session.error" { failed = true; break }
            if progress.contains(type) { break }
        }

        lock.lock()
        cache[url.path] = (size, failed)
        lock.unlock()
        return failed
    }
}
