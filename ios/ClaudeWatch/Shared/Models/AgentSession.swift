import Foundation

enum AgentType: String, Codable {
    case claude
    case codex
}

struct AgentSession: Identifiable, Codable, Equatable {
    let id: String
    let agent: AgentType
    let cwd: String
    let folderName: String
    var activity: SessionActivity
    let backend: String
    let writable: Bool
    let sharedTerminal: Bool
    let externalSessionId: String?
    let tmuxSessionName: String?
    let lastActivityAt: TimeInterval?

    // Client-side only — not decoded from bridge JSON
    var terminalLines: [TerminalLine] = []
    var pendingApproval: ApprovalRequest?
    var lastVisualActivityAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, agent, cwd, folderName, activity
        case backend, writable, sharedTerminal, externalSessionId, tmuxSessionName, lastActivityAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(agent, forKey: .agent)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(folderName, forKey: .folderName)
        try c.encode(activity, forKey: .activity)
        try c.encode(backend, forKey: .backend)
        try c.encode(writable, forKey: .writable)
        try c.encode(sharedTerminal, forKey: .sharedTerminal)
        try c.encodeIfPresent(externalSessionId, forKey: .externalSessionId)
        try c.encodeIfPresent(tmuxSessionName, forKey: .tmuxSessionName)
        try c.encodeIfPresent(lastActivityAt, forKey: .lastActivityAt)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agent = try c.decodeIfPresent(AgentType.self, forKey: .agent) ?? .claude
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName) ?? ""
        activity = try c.decodeIfPresent(SessionActivity.self, forKey: .activity) ?? .idle
        backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? "external"
        writable = try c.decodeIfPresent(Bool.self, forKey: .writable) ?? false
        sharedTerminal = try c.decodeIfPresent(Bool.self, forKey: .sharedTerminal) ?? (backend == "tmux")
        externalSessionId = try c.decodeIfPresent(String.self, forKey: .externalSessionId)
        tmuxSessionName = try c.decodeIfPresent(String.self, forKey: .tmuxSessionName)
        lastActivityAt = try c.decodeIfPresent(TimeInterval.self, forKey: .lastActivityAt)
        terminalLines = []
        pendingApproval = nil
        lastVisualActivityAt = nil
    }

    init(
        id: String,
        agent: AgentType,
        cwd: String,
        folderName: String,
        activity: SessionActivity,
        backend: String = "external",
        writable: Bool = false,
        sharedTerminal: Bool = false,
        externalSessionId: String? = nil,
        tmuxSessionName: String? = nil,
        lastActivityAt: TimeInterval? = nil
    ) {
        self.id = id
        self.agent = agent
        self.cwd = cwd
        self.folderName = folderName
        self.activity = activity
        self.backend = backend
        self.writable = writable
        self.sharedTerminal = sharedTerminal
        self.externalSessionId = externalSessionId
        self.tmuxSessionName = tmuxSessionName
        self.lastActivityAt = lastActivityAt
        self.terminalLines = []
        self.pendingApproval = nil
        self.lastVisualActivityAt = nil
    }

    var accessLabel: String {
        if sharedTerminal { return "Shared" }
        return writable ? "Live" : "Read-only"
    }

    var displayName: String {
        "\(agent.rawValue)-watch"
    }

    var backendLabel: String {
        switch backend {
        case "tmux":
            return "tmux"
        case "pty":
            return "pty"
        case "external":
            return "mirror"
        default:
            return backend
        }
    }

    var shortDisplayId: String {
        if let tmuxSessionName, !tmuxSessionName.isEmpty {
            let compact = tmuxSessionName.replacingOccurrences(of: "agent-watch-", with: "")
            let parts = compact.split(separator: "-")
            if parts.count >= 2 {
                return "\(parts[0])-\(parts[1].prefix(8))"
            }
            return compact
        }
        return String(id.prefix(8))
    }

    static func == (lhs: AgentSession, rhs: AgentSession) -> Bool {
        lhs.id == rhs.id
            && lhs.agent == rhs.agent
            && lhs.activity == rhs.activity
            && lhs.backend == rhs.backend
            && lhs.writable == rhs.writable
            && lhs.sharedTerminal == rhs.sharedTerminal
            && lhs.terminalLines.count == rhs.terminalLines.count
    }
}
