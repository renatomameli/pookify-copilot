import Foundation

/// Which coding agent a session belongs to.
public enum Provider: String, Codable, Sendable, CaseIterable {
    case copilot

    public var displayName: String { "GitHub Copilot" }

    /// GitHub's light blue accent, represented as sRGB components.
    public var accentRGB: (r: Double, g: Double, b: Double) { (0.345, 0.651, 1.0) }
}

/// The normalized lifecycle state of a single session, derived from hook events.
/// Ordered loosely by how much it deserves the user's attention.
public enum AgentState: String, Codable, Sendable {
    case idle        // session open, nothing happening
    case thinking    // model is reasoning between tools
    case tool        // running a tool (see `label`/`tool` for which)
    case permission  // blocked, awaiting permission or user input
    case done        // a turn just finished (transient celebratory flash -> becomes .completed)
    case error       // a turn ended on an error (transient)
    case completed   // a finished turn, retained while another session is active

    /// Higher = more important to surface when several sessions are live.
    public var priority: Int {
        switch self {
        case .permission:        return 3
        case .tool, .thinking:   return 2
        case .error, .done:      return 1
        case .completed, .idle:  return 0
        }
    }

    public var isWorking: Bool { self == .thinking || self == .tool }
}

/// One session's state, written by `island-hook` and read by the app. This is the entire
/// on-disk contract: a flat, human-readable JSON file per session.
public struct SessionSnapshot: Codable, Sendable {
    public var schema: Int
    public var provider: Provider
    public var sessionId: String
    public var state: AgentState
    public var label: String
    public var tool: String
    public var project: String
    public var cwd: String
    public var pid: Int32
    public var startedAt: Double
    public var ts: Double
    public var toolEndsAt: Double
    public var detail: String

    public init(schema: Int = Island.stateSchema,
                provider: Provider,
                sessionId: String,
                state: AgentState,
                label: String = "",
                tool: String = "",
                project: String = "",
                cwd: String = "",
                pid: Int32 = 0,
                startedAt: Double = 0,
                ts: Double = 0,
                toolEndsAt: Double = 0,
                detail: String = "") {
        self.schema = schema
        self.provider = provider
        self.sessionId = sessionId
        self.state = state
        self.label = label
        self.tool = tool
        self.project = project
        self.cwd = cwd
        self.pid = pid
        self.startedAt = startedAt
        self.ts = ts
        self.toolEndsAt = toolEndsAt
        self.detail = detail
    }

    /// Tolerate older/newer files: unknown provider/state decode to safe defaults and unknown
    /// fields are ignored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema     = (try? c.decode(Int.self, forKey: .schema)) ?? 1
        provider   = (try? c.decode(Provider.self, forKey: .provider)) ?? .copilot
        sessionId  = (try? c.decode(String.self, forKey: .sessionId)) ?? ""
        state      = (try? c.decode(AgentState.self, forKey: .state)) ?? .idle
        label      = (try? c.decode(String.self, forKey: .label)) ?? ""
        tool       = (try? c.decode(String.self, forKey: .tool)) ?? ""
        project    = (try? c.decode(String.self, forKey: .project)) ?? ""
        cwd        = (try? c.decode(String.self, forKey: .cwd)) ?? ""
        pid        = (try? c.decode(Int32.self, forKey: .pid)) ?? 0
        startedAt  = (try? c.decode(Double.self, forKey: .startedAt)) ?? 0
        ts         = (try? c.decode(Double.self, forKey: .ts)) ?? 0
        toolEndsAt = (try? c.decode(Double.self, forKey: .toolEndsAt)) ?? 0
        detail     = (try? c.decode(String.self, forKey: .detail)) ?? ""
    }
}

/// Maps Copilot CLI tool names to short labels for the pill. Native lowercase names and
/// VS Code-compatible aliases are both accepted.
public func toolLabel(provider _: Provider, tool: String) -> String {
    let normalized = tool.lowercased()
    let labels: [String: String] = [
        "bash": "Running command", "powershell": "Running command",
        "create": "Writing", "write": "Writing",
        "edit": "Editing", "apply_patch": "Editing", "str_replace_editor": "Editing",
        "view": "Reading", "read": "Reading",
        "grep": "Searching", "rg": "Searching", "glob": "Searching",
        "web_fetch": "Browsing web", "webfetch": "Browsing web",
        "web_search": "Searching web", "websearch": "Searching web",
        "task": "Delegating", "agent": "Delegating",
        "update_todo": "Planning", "todowrite": "Planning",
        "ask_user": "Asking a question", "askuserquestion": "Asking a question",
        "skill": "Running skill",
    ]
    if let hit = labels[normalized] { return hit }
    if normalized.hasPrefix("mcp") || normalized.contains("__") { return "Using MCP tool" }
    return "Working..."
}
