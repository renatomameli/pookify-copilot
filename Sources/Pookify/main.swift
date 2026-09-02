import AppKit
import IslandCore

// Headless management commands let scripts wire hooks without opening the UI.
let argv = CommandLine.arguments
if argv.contains("--dump-sessions") {
    let decision = SessionAggregator.evaluate()
    let sessions: [[String: Any]] = decision.sessions.map {
        [
            "id": $0.id,
            "pid": Int($0.pid),
            "state": $0.state.rawValue,
            "label": $0.label,
        ]
    }
    do {
        let data = try JSONSerialization.data(withJSONObject: sessions, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
        exit(0)
    } catch {
        fputs("Pookify Copilot: could not encode session diagnostics.\n", stderr)
        exit(1)
    }
}
if argv.contains("--uninstall") {
    do {
        try HookInstaller.uninstall()
        print("Removed Pookify Copilot hooks.")
        exit(0)
    } catch {
        fputs("Pookify Copilot: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
if argv.contains("--install") {
    do {
        let wired = try HookInstaller.installAll()
        print("Wired Pookify Copilot into:\n" + wired.map { "  - \($0)" }.joined(separator: "\n"))
        exit(0)
    } catch {
        fputs("Pookify Copilot: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

// Pookify Copilot is a background agent (no Dock icon or menu bar item). UI lives entirely
// on the notch. We drive the app from an AppDelegate rather than the SwiftUI App lifecycle so it
// behaves correctly when built as a bare SwiftPM executable wrapped in a hand-assembled bundle.
//
// Program start is already on the main thread (the main actor's executor), so assumeIsolated lets
// us construct the main-actor controller and run the app loop without a concurrency error.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
}
