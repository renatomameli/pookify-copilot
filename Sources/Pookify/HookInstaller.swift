import Foundation
import IslandCore

/// Installs one owned user-level hook file for GitHub Copilot CLI. Other hook files and settings
/// are never edited. The configuration is idempotent and removable without a merge operation.
enum HookInstaller {
    private struct Event {
        let name: String
        let token: String
        let matcher: String?

        init(_ name: String, _ token: String, matcher: String? = nil) {
            self.name = name
            self.token = token
            self.matcher = matcher
        }
    }

    enum InstallerError: LocalizedError {
        case copilotHomeMissing(URL)
        case bundledHelperMissing(URL)
        case hookFileOwnedBySomeoneElse(URL)

        var errorDescription: String? {
            switch self {
            case .copilotHomeMissing(let url):
                return "GitHub Copilot CLI configuration was not found at \(url.path). Run `copilot` once, then retry."
            case .bundledHelperMissing(let url):
                return "The bundled hook helper is missing at \(url.path). Rebuild the app and retry."
            case .hookFileOwnedBySomeoneElse(let url):
                return "Refusing to overwrite \(url.path) because it is not owned by Pookify Copilot."
            }
        }
    }

    private static let fileManager = FileManager.default
    private static let ownershipMarker = "POOKIFY_COPILOT_HOOK"
    private static let installedVersionKey = "copilotHooksInstalledVersion"
    private static let copilotHomeKey = "copilotHomePath"

    static var copilotHome: URL {
        if let path = ProcessInfo.processInfo.environment["COPILOT_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        if let path = UserDefaults.standard.string(forKey: copilotHomeKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot", isDirectory: true)
    }

    static var hooksDir: URL {
        copilotHome.appendingPathComponent("hooks", isDirectory: true)
    }

    static var hookFile: URL {
        hooksDir.appendingPathComponent("pookify-copilot.json")
    }

    // Native Copilot hook names produce camelCase payload fields. permissionRequest is
    // intentionally absent: it fires before every permission evaluation, even when no prompt is
    // shown. notification only matches states that actually block on user attention.
    private static let events: [Event] = [
        Event("sessionStart", "session-start"),
        Event("sessionEnd", "session-end"),
        Event("userPromptSubmitted", "prompt"),
        Event("preToolUse", "pre"),
        Event("postToolUse", "post"),
        Event("postToolUseFailure", "post-fail"),
        Event("agentStop", "stop"),
        Event("errorOccurred", "error"),
        Event("subagentStart", "subagent-start"),
        Event("subagentStop", "subagent-stop"),
        Event("preCompact", "compact"),
        Event("notification", "notify",
              matcher: "permission_prompt|elicitation_dialog"),
    ]

    /// Locate the helper shipped next to this executable (Contents/MacOS in a bundle, or the
    /// SwiftPM build directory during development).
    private static var bundledHelper: URL {
        let executableDirectory = (
            Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        ).deletingLastPathComponent()
        return executableDirectory.appendingPathComponent(Island.helperName)
    }

    @discardableResult
    static func installAll() throws -> [String] {
        guard fileManager.fileExists(atPath: copilotHome.path) else {
            throw InstallerError.copilotHomeMissing(copilotHome)
        }
        let helperPath = try installHelper()
        try writeHookFile(helperPath: helperPath)
        UserDefaults.standard.set(currentVersion, forKey: installedVersionKey)
        UserDefaults.standard.set(copilotHome.path, forKey: copilotHomeKey)
        return ["GitHub Copilot CLI (\(hookFile.path))"]
    }

    static func uninstall() throws {
        if fileManager.fileExists(atPath: hookFile.path) {
            let contents = try String(contentsOf: hookFile, encoding: .utf8)
            guard contents.contains(ownershipMarker) else {
                throw InstallerError.hookFileOwnedBySomeoneElse(hookFile)
            }
            try fileManager.removeItem(at: hookFile)
        }
        for directory in [Island.stateDir, Island.binDir] {
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
        UserDefaults.standard.removeObject(forKey: installedVersionKey)
        UserDefaults.standard.removeObject(forKey: copilotHomeKey)
    }

    /// Re-run on first launch and whenever the app version changes so upgrades pick up hook
    /// changes. Installation failures are logged and retried on the next launch.
    @discardableResult
    static func ensureInstalledIfNeeded() -> [String]? {
        if UserDefaults.standard.string(forKey: installedVersionKey) == currentVersion,
           fileManager.fileExists(atPath: hookFile.path) {
            return nil
        }
        do {
            return try installAll()
        } catch {
            NSLog("Pookify Copilot: hook installation failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    @discardableResult
    private static func installHelper() throws -> String {
        Island.ensureDirs()
        let source = bundledHelper
        guard fileManager.isExecutableFile(atPath: source.path) else {
            throw InstallerError.bundledHelperMissing(source)
        }

        let destination = Island.installedHelper
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent("\(Island.helperName).\(ProcessInfo.processInfo.processIdentifier).tmp")
        if fileManager.fileExists(atPath: temporary.path) {
            try fileManager.removeItem(at: temporary)
        }
        try fileManager.copyItem(at: source, to: temporary)
        try fileManager.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)
        return destination.path
    }

    private static func writeHookFile(helperPath: String) throws {
        if fileManager.fileExists(atPath: hookFile.path) {
            let contents = try String(contentsOf: hookFile, encoding: .utf8)
            guard contents.contains(ownershipMarker) else {
                try backupForeignFileOnce()
                throw InstallerError.hookFileOwnedBySomeoneElse(hookFile)
            }
        }

        try fileManager.createDirectory(
            at: hooksDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var hooks: [String: Any] = [:]
        for event in events {
            var entry: [String: Any] = [
                "type": "command",
                "bash": command(helperPath: helperPath, token: event.token),
                "timeoutSec": 2,
                "env": [ownershipMarker: "1"],
            ]
            if let matcher = event.matcher {
                entry["matcher"] = matcher
            }
            hooks[event.name] = [entry]
        }

        let root: [String: Any] = ["version": 1, "hooks": hooks]
        var data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        data.append(0x0A)
        try data.write(to: hookFile, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600],
                                      ofItemAtPath: hookFile.path)
    }

    private static func backupForeignFileOnce() throws {
        let backup = hookFile.appendingPathExtension("bak")
        guard !fileManager.fileExists(atPath: backup.path) else { return }
        try fileManager.copyItem(at: hookFile, to: backup)
    }

    /// Wrap the helper path as one shell word. The explicit `|| true` is important because
    /// Copilot treats a failed preToolUse command hook as a denial; a status display must fail open.
    private static func command(helperPath: String, token: String) -> String {
        let quotedPath = "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "COPILOT_SESSION_PID=$PPID \(quotedPath) copilot \(token) || true"
    }
}
