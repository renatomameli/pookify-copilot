import AppKit
import Foundation

/// Focuses the exact Ghostty tab or split that runs a Copilot session.
///
/// Several Copilot sessions can live as tabs or windows of one Ghostty process. Activating that
/// process only shows its last-used window, so instead this asks Ghostty (1.3+, via its scripting
/// dictionary) for its terminals and focuses the one whose title carries the session's name.
/// Copilot titles a terminal "<session name> - GitHub Copilot".
enum GhosttyFocus {
    static let bundleID = "com.mitchellh.ghostty"
    private static let replyTimeout: TimeInterval = 2

    /// Blocks on Apple Events, so call it off the main thread. Returns false when Ghostty has no
    /// scripting support, macOS denies automation, or no terminal title matches.
    static func focus(sessionID: String, copilotPID: Int32, appPID: pid_t) -> Bool {
        guard let name = CopilotSessionNames.name(sessionID: sessionID, copilotPID: copilotPID) else {
            Log.info("Pookify Copilot: no Copilot session name found for session \(sessionID).")
            return false
        }
        // The first use shows macOS's automation prompt. Wait for the answer here: a reply
        // timeout would otherwise expire while the prompt is still on screen.
        let permission = AEDeterminePermissionToAutomateTarget(
            NSAppleEventDescriptor(processIdentifier: appPID).aeDesc, typeWildCard, typeWildCard, true
        )
        guard permission == noErr else {
            Log.info("Pookify Copilot: automation of Ghostty not permitted (OSStatus \(permission)).")
            return false
        }
        let terminals: [(id: String, title: String)]
        do {
            terminals = try terminalTitles(appPID: appPID)
        } catch {
            Log.info("Pookify Copilot: Ghostty terminals unavailable: \(error.localizedDescription)")
            return false
        }
        let exact = "\(name) - GitHub Copilot"
        guard let match = terminals.first(where: { $0.title == exact })
            ?? terminals.first(where: { $0.title.hasPrefix(name) }) else {
            Log.info("Pookify Copilot: no Ghostty terminal titled \"\(name)\" in PID \(appPID).")
            return false
        }
        do {
            _ = try send(event: "Fcus", to: appPID, directObject: terminalSpecifier(id: match.id))
            return true
        } catch {
            Log.info("Pookify Copilot: Ghostty focus failed: \(error.localizedDescription)")
            return false
        }
    }

    /// `get {id, name} of every terminal` in one round trip.
    private static func terminalTitles(appPID: pid_t) throws -> [(id: String, title: String)] {
        let every = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeObjectSpecifier)!
        every.setDescriptor(NSAppleEventDescriptor(typeCode: code("Gtrm")), forKeyword: AEKeyword(keyAEDesiredClass))
        every.setDescriptor(NSAppleEventDescriptor(enumCode: FourCharCode(formAbsolutePosition)),
                            forKeyword: AEKeyword(keyAEKeyForm))
        var all = FourCharCode(kAEAll)
        let allOrdinal = NSAppleEventDescriptor(descriptorType: DescType(typeAbsoluteOrdinal),
                                                bytes: &all, length: MemoryLayout<FourCharCode>.size)!
        every.setDescriptor(allOrdinal, forKeyword: AEKeyword(keyAEKeyData))
        every.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))

        func property(_ name: String) -> NSAppleEventDescriptor {
            let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeObjectSpecifier)!
            spec.setDescriptor(NSAppleEventDescriptor(typeCode: FourCharCode(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
            spec.setDescriptor(NSAppleEventDescriptor(enumCode: FourCharCode(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
            spec.setDescriptor(NSAppleEventDescriptor(typeCode: code(name)), forKeyword: AEKeyword(keyAEKeyData))
            spec.setDescriptor(every, forKeyword: AEKeyword(keyAEContainer))
            return spec
        }

        let ids = try strings(send(event: "getd", eventClass: "core", to: appPID, directObject: property("ID  ")))
        let titles = try strings(send(event: "getd", eventClass: "core", to: appPID, directObject: property("pnam")))
        return zip(ids, titles).map { (id: $0, title: $1) }
    }

    private static func terminalSpecifier(id: String) -> NSAppleEventDescriptor {
        let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeObjectSpecifier)!
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: code("Gtrm")), forKeyword: AEKeyword(keyAEDesiredClass))
        spec.setDescriptor(NSAppleEventDescriptor(enumCode: FourCharCode(formUniqueID)), forKeyword: AEKeyword(keyAEKeyForm))
        spec.setDescriptor(NSAppleEventDescriptor(string: id), forKeyword: AEKeyword(keyAEKeyData))
        spec.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        return spec
    }

    private static func send(event: String, eventClass: String = "Ghst", to pid: pid_t,
                             directObject: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let appleEvent = NSAppleEventDescriptor(
            eventClass: code(eventClass),
            eventID: code(event),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        appleEvent.setParam(directObject, forKeyword: AEKeyword(keyDirectObject))
        let reply = try appleEvent.sendEvent(options: [.waitForReply], timeout: replyTimeout)
        if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value))
        }
        return reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) ?? reply
    }

    private static func strings(_ list: NSAppleEventDescriptor) -> [String] {
        guard list.numberOfItems > 0 else { return list.stringValue.map { [$0] } ?? [] }
        return (1...list.numberOfItems).map { list.atIndex($0)?.stringValue ?? "" }
    }

    private static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}

/// Reads Copilot's own session metadata from `~/.copilot/session-state`.
enum CopilotSessionNames {
    private static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot/session-state")
    }

    /// The session's display name. Rows found only through process discovery have no hook
    /// session ID; for those, use the session the process holds open most recently.
    static func name(sessionID: String, copilotPID: Int32) -> String? {
        if !sessionID.hasPrefix("process-"), let name = name(in: root.appendingPathComponent(sessionID)) {
            return name
        }
        return newestSessionDirectory(heldBy: copilotPID).flatMap(name(in:))
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
        let lock = "inuse.\(pid).lock"
        func modified(_ url: URL) -> Date {
            let events = url.appendingPathComponent("events.jsonl")
            return (try? events.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        return directories
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(lock).path) }
            .max { modified($0) < modified($1) }
    }
}
