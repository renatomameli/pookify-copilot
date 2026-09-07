import Darwin
import Foundation
import IslandCore

/// Finds interactive local Copilot CLI processes that currently have no hook snapshot.
///
/// Hooks remain the source of truth for activity. Process discovery is only a liveness fallback:
/// a session whose snapshot was removed by `sessionEnd` still remains selectable as Idle while
/// its Copilot process and terminal are open.
enum CopilotProcessDiscovery {
    private static let lock = NSLock()
    private static var cachedAt: Double = 0
    private static var cachedSnapshots: [SessionSnapshot] = []
    private static let cacheLifetime: TimeInterval = 2
    private static let pathBufferSize = 4096

    static func snapshots(now: Double) -> [SessionSnapshot] {
        lock.lock()
        if now - cachedAt < cacheLifetime {
            let snapshots = cachedSnapshots
            lock.unlock()
            return snapshots
        }
        lock.unlock()

        let snapshots = scan(now: now)
        lock.lock()
        cachedAt = now
        cachedSnapshots = snapshots
        lock.unlock()
        return snapshots
    }

    private static func scan(now: Double) -> [SessionSnapshot] {
        let countEstimate = proc_listallpids(nil, 0)
        guard countEstimate > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(countEstimate) + 32)
        let count = proc_listallpids(
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.stride)
        )
        guard count > 0 else { return [] }

        let discoveryRoot = ProcessInfo.processInfo.environment["ISLAND_PROCESS_DISCOVERY_ROOT"]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }

        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 1 else { return nil }

            var name = [CChar](repeating: 0, count: 64)
            guard proc_name(pid, &name, UInt32(name.count)) > 0,
                  String(cString: name) == "copilot" else { return nil }

            var path = [CChar](repeating: 0, count: pathBufferSize)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            let executable = URL(fileURLWithPath: String(cString: path)).standardizedFileURL.path
            if let discoveryRoot {
                guard executable == discoveryRoot
                    || executable.hasPrefix(discoveryRoot + "/") else { return nil }
            } else {
                let normalizedPath = executable.lowercased()
                let officialInstall = normalizedPath.contains("/@github/copilot")
                    || normalizedPath.contains("/copilot-cli/")
                    || normalizedPath.contains("/github/copilot-cli/")
                guard officialInstall else { return nil }
            }

            var info = proc_bsdinfo()
            let infoSize = proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                &info,
                Int32(MemoryLayout<proc_bsdinfo>.stride)
            )
            guard infoSize == MemoryLayout<proc_bsdinfo>.stride,
                  info.pbi_uid == getuid(),
                  discoveryRoot != nil || info.e_tpgid > 0 else { return nil }

            let cwd = workingDirectory(for: pid)
            let project = cwd.isEmpty || cwd == FileManager.default.homeDirectoryForCurrentUser.path
                ? "Copilot \(pid)"
                : (cwd as NSString).lastPathComponent
            return SessionSnapshot(
                provider: .copilot,
                sessionId: "process-\(pid)",
                state: .idle,
                label: "Idle",
                project: project,
                cwd: cwd,
                pid: pid,
                startedAt: 0,
                ts: now
            )
        }
    }

    private static func workingDirectory(for pid: pid_t) -> String {
        var info = proc_vnodepathinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        )
        guard size == MemoryLayout<proc_vnodepathinfo>.stride else { return "" }

        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { rawBuffer in
            let characters = rawBuffer.bindMemory(to: CChar.self)
            guard let baseAddress = characters.baseAddress else { return "" }
            return String(cString: baseAddress)
        }
    }
}
