import AppKit
import IslandCore

/// Brings the macOS application that owns a Copilot session to the foreground.
///
/// Copilot's recorded PID belongs to its CLI process. Walking that process's ancestors reaches
/// the terminal or IDE application that launched it. This also distinguishes separate Ghostty
/// windows because each window can be hosted by its own application process.
enum TerminalActivator {
    static func activate(sessionPID: Int32) {
        guard sessionPID > 0 else {
            reportFailure("the session has no process identifier")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let ancestry = processAncestry(startingAt: sessionPID)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let application = owningApplication(in: ancestry) else {
                        reportFailure("no owning terminal application was found for PID \(sessionPID)")
                        return
                    }
                    let activated = application.activate(options: [.activateAllWindows])
                    if !activated {
                        reportFailure(
                            "\(application.localizedName ?? "the terminal") could not be activated"
                        )
                    } else {
                        NSLog(
                            "Pookify Copilot: activated \(application.localizedName ?? "terminal") "
                            + "PID \(application.processIdentifier) for session PID \(sessionPID)."
                        )
                    }
                }
            }
        }
    }

    /// Read the process table once, then follow parent links without repeatedly spawning `ps`.
    private static func processAncestry(startingAt pid: Int32) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            NSLog("Pookify Copilot: could not inspect process ancestry: \(error.localizedDescription)")
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            NSLog("Pookify Copilot: ps exited with status \(process.terminationStatus).")
            return []
        }

        var parents: [Int32: Int32] = [:]
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count == 2,
                  let child = Int32(columns[0]),
                  let parent = Int32(columns[1]) else { continue }
            parents[child] = parent
        }

        var ancestry: [Int32] = []
        var seen: Set<Int32> = []
        var current = pid
        while current > 1, seen.insert(current).inserted {
            ancestry.append(current)
            guard let parent = parents[current], parent != current else { break }
            current = parent
        }
        return ancestry
    }

    @MainActor
    private static func owningApplication(in ancestry: [Int32]) -> NSRunningApplication? {
        ancestry.lazy.compactMap { pid in
            guard let application = NSRunningApplication(processIdentifier: pid),
                  application.bundleIdentifier != Island.bundleID,
                  application.activationPolicy != .prohibited,
                  !application.isTerminated else { return nil }
            return application
        }.first
    }

    private static func reportFailure(_ reason: String) {
        NSLog("Pookify Copilot: \(reason).")
        DispatchQueue.main.async {
            NSSound.beep()
        }
    }
}
