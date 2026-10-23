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

extension GhosttyFocus {
    /// Title of Ghostty's front window (its selected tab), or nil when unavailable. Never shows the
    /// automation prompt: this runs on a timer, so it only works once the user allowed it.
    static func frontWindowTitle(appPID: pid_t) -> String? {
        let target = NSAppleEventDescriptor(processIdentifier: appPID)
        guard AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr
        else { return nil }

        func property(_ name: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
            let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeObjectSpecifier)!
            spec.setDescriptor(NSAppleEventDescriptor(typeCode: FourCharCode(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
            spec.setDescriptor(NSAppleEventDescriptor(enumCode: FourCharCode(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
            spec.setDescriptor(NSAppleEventDescriptor(typeCode: code(name)), forKeyword: AEKeyword(keyAEKeyData))
            spec.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
            return spec
        }
        let title = property("pnam", of: property("GFWn", of: NSAppleEventDescriptor.null()))
        return (try? send(event: "getd", eventClass: "core", to: appPID, directObject: title))?.stringValue
    }
}

/// Works out which session's terminal the user is looking at right now.
enum FocusedSession {
    private static var ancestryCache: [Int32: [Int32]] = [:]
    private static let lock = NSLock()

    /// Blocks on an Apple Event when Ghostty is frontmost; call it off the main thread.
    static func identify(frontPID: pid_t, frontBundleID: String?, sessions: [SessionInfo]) -> String? {
        let candidates = sessions.filter { ancestors(of: $0.pid).contains(frontPID) }
        guard !candidates.isEmpty else { return nil }
        if frontBundleID == GhosttyFocus.bundleID,
           let title = GhosttyFocus.frontWindowTitle(appPID: frontPID) {
            if let named = candidates.first(where: { !$0.sessionName.isEmpty && title.hasPrefix($0.sessionName) }) {
                return named.id
            }
            // A session Copilot has not named yet is titled just "GitHub Copilot"; any other title
            // means a different tab (a plain shell, say) is in front.
            let unnamed = candidates.filter { $0.sessionName.isEmpty }
            return unnamed.count == 1 && title.contains("GitHub Copilot") ? unnamed[0].id : nil
        }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    /// Parent chain of a process, cached: a live process never changes its ancestry.
    private static func ancestors(of pid: Int32) -> [Int32] {
        lock.lock()
        if let cached = ancestryCache[pid] { lock.unlock(); return cached }
        lock.unlock()
        var chain: [Int32] = []
        var current = pid
        while current > 1, !chain.contains(current) {
            chain.append(current)
            // sysctl, not proc_pidinfo: the chain passes through root-owned /usr/bin/login, which
            // proc_pidinfo refuses to describe to an unprivileged caller.
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
            current = info.kp_eproc.e_ppid
        }
        lock.lock()
        if ancestryCache.count > 256 { ancestryCache.removeAll() }
        ancestryCache[pid] = chain
        lock.unlock()
        return chain
    }
}
