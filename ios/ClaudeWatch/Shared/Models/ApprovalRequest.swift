import Foundation

struct ApprovalRequest: Identifiable, Codable {
    let id: UUID
    let permissionId: String?
    let toolName: String
    let actionSummary: String
    let timestamp: Date
    var status: ApprovalStatus
    var question: String?
    var options: [OptionItem]
    /// True when the session is a read-only external terminal.
    /// The approval is shown as a notification only; the user must respond in the Mac terminal.
    var readOnly: Bool = false

    enum ApprovalStatus: String, Codable {
        case pending
        case approved
        case denied
        case expired
    }

    struct OptionItem: Identifiable, Codable {
        let id: UUID
        let label: String
        let description: String?

        init(label: String, description: String? = nil) {
            self.id = UUID()
            self.label = label
            self.description = description
        }
    }

    init(permissionId: String? = nil, toolName: String, actionSummary: String, question: String? = nil, options: [OptionItem] = [], readOnly: Bool = false) {
        self.id = UUID()
        self.permissionId = permissionId
        self.toolName = toolName
        self.actionSummary = actionSummary
        self.timestamp = Date()
        self.status = .pending
        self.question = question
        self.options = options
        self.readOnly = readOnly
    }
}
