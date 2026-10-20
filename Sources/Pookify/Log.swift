import os

/// Diagnostics in the unified log. Messages are public so `log show` can explain click and
/// activation failures; they only contain session IDs, process IDs, and app names.
enum Log {
    private static let logger = Logger(subsystem: "com.pookify.copilot", category: "app")

    static func info(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }
}
