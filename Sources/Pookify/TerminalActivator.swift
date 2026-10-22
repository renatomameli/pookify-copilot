import AppKit
import IslandCore

/// Brings the macOS application that owns a Copilot session to the foreground.
///
/// Copilot's recorded PID belongs to its CLI process. Walking that process's ancestors reaches
/// the terminal or IDE application that launched it. Separate Ghostty processes are told apart
/// by that ancestry; tabs and windows inside one Ghostty process are focused by session name.
enum TerminalActivator {
    static func activate(sessionPID: Int32, sessionID: String) {
        guard sessionPID > 0 else {
            reportFailure("the session has no process identifier")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let ancestry = processAncestry(startingAt: sessionPID)
            let ghosttyPID = ancestry.first { pid in
                NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == GhosttyFocus.bundleID
            }
            // Select the session's own tab first, so bringing the app forward shows that window.
            let tabFocused = ghosttyPID.map {
                GhosttyFocus.focus(sessionID: sessionID, copilotPID: sessionPID, appPID: $0)
            } ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let application = owningApplication(in: ancestry) else {
                        reportFailure("no owning terminal application was found for PID \(sessionPID)")
                        return
                    }
                    let activated = application.activate(options: [.activateAllWindows])
                    // macOS may silently ignore activation requests from a background agent app
                    // (it reports success, but another app stays frontmost), so also ask the
                    // window server directly. This also switches to the window's Space.
                    let forced = WindowServerFocus.bringToFront(pid: application.processIdentifier)
                    if !activated && !forced {
                        reportFailure(
                            "\(application.localizedName ?? "the terminal") could not be activated"
                        )
                    } else {
                        Log.info(
                            "Pookify Copilot: activated \(application.localizedName ?? "terminal") "
                            + "PID \(application.processIdentifier) for session PID \(sessionPID) "
                            + "(public=\(activated), windowServer=\(forced), tab=\(tabFocused))."
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
            Log.info("Pookify Copilot: could not inspect process ancestry: \(error.localizedDescription)")
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            Log.info("Pookify Copilot: ps exited with status \(process.terminationStatus).")
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
        Log.info("Pookify Copilot: \(reason).")
        DispatchQueue.main.async {
            NSSound.beep()
        }
    }
}

/// Brings a process to the front through the window server, the way window switchers such as
/// AltTab do. These are private SkyLight/HIServices symbols, resolved at runtime so the app keeps
/// working (falling back to the public API alone) if a future macOS removes them.
enum WindowServerFocus {
    private typealias GetProcessForPID = @convention(c) (
        pid_t, UnsafeMutablePointer<ProcessSerialNumber>
    ) -> OSStatus
    private typealias SetFrontProcess = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32
    ) -> Int32

    /// `kCPSUserGenerated`: treat the request like a user-initiated switch.
    private static let userGenerated: UInt32 = 0x200

    private static let symbols: (GetProcessForPID, SetFrontProcess)? = {
        guard
            let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
            let services = dlopen(
                "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY
            ),
            let getPSN = dlsym(services, "GetProcessForPID"),
            let setFront = dlsym(skyLight, "_SLPSSetFrontProcessWithOptions")
        else { return nil }
        return (unsafeBitCast(getPSN, to: GetProcessForPID.self),
                unsafeBitCast(setFront, to: SetFrontProcess.self))
    }()

    static func bringToFront(pid: pid_t) -> Bool {
        guard let (getPSN, setFront) = symbols else { return false }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return false }
        return setFront(&psn, 0, userGenerated) == 0
    }
}
