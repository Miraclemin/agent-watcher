import SwiftUI
import WatchConnectivity

class WatchViewState: ObservableObject {
    static let shared = WatchViewState()

    @Published var isPaired: Bool = false
    @Published var sessionState: SessionState = .disconnected
    @Published var terminalLines: [TerminalLine] = [] // Legacy: flat view of all output
    @Published var pendingApproval: ApprovalRequest? = nil
    @Published var isStreaming: Bool = false
    @Published var taskCompleteSummary: String? = nil
    @Published var isReachable: Bool = false

    // Multi-session
    @Published var sessions: [AgentSession] = []
    @Published var activeSessionIndex: Int = 0

    var activeSession: AgentSession? {
        guard sessions.indices.contains(activeSessionIndex) else { return nil }
        return sessions[activeSessionIndex]
    }

    private let bridge = WatchBridgeClient.shared
    private let maxLines = 200
    private var pollTimer: Timer?
    private var lastEventId: Int = 0
    private var sseTask: URLSessionDataTask?

    private init() {
        if bridge.isPaired {
            Task {
                let reachable = await verifyBridge()
                await MainActor.run {
                    if reachable {
                        isPaired = true
                        startEventStream()
                    } else {
                        bridge.unpair()
                        isPaired = false
                    }
                }
            }
        }
    }

    private func verifyBridge() async -> Bool {
        guard let baseURL = bridge.baseURL, let token = bridge.token else { return false }
        let url = baseURL.appendingPathComponent("status")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3
        request.addCloudflareAccessHeaders()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Terminal (legacy flat + per-session)

    func appendLine(_ line: TerminalLine, sessionId: String? = nil) {
        DispatchQueue.main.async {
            // Append to legacy flat list
            self.terminalLines.append(line)
            if self.terminalLines.count > self.maxLines {
                self.terminalLines.removeFirst(self.terminalLines.count - self.maxLines)
            }

            // Append to the specific session
            if let sid = sessionId, let idx = self.sessionIndex(for: sid) {
                self.sessions[idx].terminalLines.append(line)
                if self.sessions[idx].terminalLines.count > self.maxLines {
                    self.sessions[idx].terminalLines.removeFirst(
                        self.sessions[idx].terminalLines.count - self.maxLines
                    )
                }
            }
        }
    }

    @discardableResult
    private func appendLineIfNotDuplicate(_ line: TerminalLine, sessionId: String? = nil) -> Bool {
        if let sid = sessionId, let idx = sessionIndex(for: sid) {
            if sessions[idx].terminalLines.suffix(6).contains(where: { $0.type == line.type && $0.text == line.text }) {
                return false
            }
        } else if terminalLines.suffix(6).contains(where: { $0.type == line.type && $0.text == line.text }) {
            return false
        }

        appendLine(line, sessionId: sessionId)
        return true
    }

    // MARK: - Session lookup

    private func sessionIndex(for id: String) -> Int? {
        sessions.firstIndex(where: { $0.id == id })
    }

    private func session(for id: String) -> AgentSession? {
        guard let index = sessionIndex(for: id) else { return nil }
        return sessions[index]
    }

    private func sanitizeTerminalText(_ text: String) -> String {
        let withoutOsc = text.replacingOccurrences(
            of: "\\u{001B}\\][^\\u{0007}\\u{001B}]*(\\u{0007}|\\u{001B}\\\\)",
            with: "",
            options: .regularExpression
        )
        let withoutCsi = withoutOsc.replacingOccurrences(
            of: "\\u{001B}\\[[0-9;?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        let withoutEscapes = withoutCsi.replacingOccurrences(
            of: "\\u{001B}[()][A-Za-z0-9]",
            with: "",
            options: .regularExpression
        )
        return withoutEscapes
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .controlCharacters) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func shouldDisplayPtyOutput(_ text: String, sessionId: String?, bootstrap: Bool = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Bootstrap (initial terminal snapshot): always show for context
        if bootstrap { return true }

        guard let sessionId, let session = session(for: sessionId), session.sharedTerminal else {
            return true
        }

        return trimmed.hasPrefix("[queued prompt]")
            || trimmed.hasPrefix("[launching]")
            || trimmed == "^C"
    }

    private func removeThinkingLine(sessionId: String?) {
        // Remove from legacy flat list
        if terminalLines.last?.type == .thinking {
            terminalLines.removeLast()
        }
        // Remove from specific session
        if let sid = sessionId, let idx = sessionIndex(for: sid),
           sessions[idx].terminalLines.last?.type == .thinking {
            sessions[idx].terminalLines.removeLast()
        }
    }

    // MARK: - Event stream (SSE from bridge)

    func startEventStream() {
        guard let baseURL = bridge.baseURL, let token = bridge.token else { return }

        let url = baseURL.appendingPathComponent("events")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if lastEventId > 0 {
            request.setValue("\(lastEventId)", forHTTPHeaderField: "Last-Event-ID")
        }
        request.addCloudflareAccessHeaders()
        request.timeoutInterval = 300

        let session = URLSession(configuration: .default, delegate: SSEDelegate(owner: self), delegateQueue: nil)
        sseTask = session.dataTask(with: request)
        sseTask?.resume()

        DispatchQueue.main.async {
            self.sessionState.connection = .connected
            self.isReachable = true
        }

        print("[WatchViewState] SSE stream started")
    }

    func stopEventStream() {
        sseTask?.cancel()
        sseTask = nil
    }

    // MARK: - SSE parsing

    func handleSSEData(_ text: String) {
        let blocks = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }

        for block in blocks {
            var eventType: String?
            var eventData: String?
            var eventId: Int?

            for line in block.components(separatedBy: "\n") {
                if line.hasPrefix("id: ") {
                    eventId = Int(line.dropFirst(4))
                } else if line.hasPrefix("event: ") {
                    eventType = String(line.dropFirst(7))
                } else if line.hasPrefix("data: ") {
                    let dataLine = String(line.dropFirst(6))
                    if eventData == nil {
                        eventData = dataLine
                    } else {
                        eventData! += "\n" + dataLine
                    }
                } else if line.hasPrefix(":") {
                    continue
                }
            }

            if let id = eventId { lastEventId = id }
            guard let type = eventType, let data = eventData else { continue }

            DispatchQueue.main.async {
                self.processEvent(type: type, data: data)
            }
        }
    }

    private func processEvent(type: String, data: String) {
        guard let json = parseJSON(data) else { return }
        let sessionId = json["sessionId"] as? String

        switch type {
        case "tool-output":
            handleToolOutput(json, sessionId: sessionId)

        case "permission-request":
            handlePermissionRequest(json, sessionId: sessionId)

        case "permission-cleared":
            handlePermissionCleared(json, sessionId: sessionId)

        case "stop":
            removeThinkingLine(sessionId: sessionId)
            appendLine(TerminalLine(text: "— stopped —", type: .system), sessionId: sessionId)
            isStreaming = false
            if let sid = sessionId, let idx = sessionIndex(for: sid) {
                sessions[idx].activity = .idle
            }

        case "session":
            handleSessionEvent(json, sessionId: sessionId)

        case "session-removed":
            handleSessionRemoved(json, sessionId: sessionId)

        case "conversation-message":
            handleConversationMessage(json, sessionId: sessionId)

        case "pty-output":
            let isBootstrap = json["bootstrap"] as? Bool ?? false
            if let text = json["text"] as? String {
                let cleaned = sanitizeTerminalText(text)
                guard shouldDisplayPtyOutput(cleaned, sessionId: sessionId, bootstrap: isBootstrap) else { return }
                if !cleaned.isEmpty {
                    // Bootstrap: split into individual lines for better display
                    if isBootstrap {
                        let lines = cleaned.components(separatedBy: "\n").suffix(20)
                        for line in lines {
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                appendLine(TerminalLine(text: String(trimmed.prefix(80)), type: .output), sessionId: sessionId)
                            }
                        }
                    } else {
                        appendLine(TerminalLine(text: String(cleaned.prefix(80)), type: .output), sessionId: sessionId)
                    }
                }
            }

        case "task-complete":
            let summary = json["summary"] as? String
            taskCompleteSummary = summary
            if let sid = sessionId, let idx = sessionIndex(for: sid) {
                sessions[idx].activity = .idle
            }
            HapticManager.taskComplete()

        default:
            break
        }
    }

    // MARK: - Event handlers

    private func handleToolOutput(_ json: [String: Any], sessionId: String?) {
        // Remove previous thinking indicator before adding new content
        removeThinkingLine(sessionId: sessionId)
        if let sid = sessionId, let idx = sessionIndex(for: sid) {
            sessions[idx].activity = .running
        }

        let toolName = json["tool_name"] as? String ?? "tool"
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        let source = json["source"] as? String ?? "claude"
        let toolOutput = json["tool_output"] as? String
        let prefix = source == "codex" ? "[codex] " : ""
        switch toolName {
        case "Bash":
            let cmd = toolInput["command"] as? String ?? ""
            appendLine(TerminalLine(text: "\(prefix)$ \(cmd)", type: .command), sessionId: sessionId)
            if let output = toolOutput, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                for line in output.components(separatedBy: "\n").prefix(5) {
                    let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        appendLine(TerminalLine(text: cleaned, type: .output), sessionId: sessionId)
                    }
                }
            }
        case "Read":
            let path = toolInput["file_path"] as? String ?? ""
            appendLine(TerminalLine(text: "\(prefix)Read \((path as NSString).lastPathComponent)", type: .system), sessionId: sessionId)
        case "Edit":
            let path = toolInput["file_path"] as? String ?? ""
            appendLine(TerminalLine(text: "\(prefix)Edit \((path as NSString).lastPathComponent)", type: .system), sessionId: sessionId)
        case "Write":
            let path = toolInput["file_path"] as? String ?? ""
            appendLine(TerminalLine(text: "\(prefix)Write \((path as NSString).lastPathComponent)", type: .system), sessionId: sessionId)
        case "Grep":
            let pattern = toolInput["pattern"] as? String ?? ""
            appendLine(TerminalLine(text: "\(prefix)grep \"\(pattern)\"", type: .command), sessionId: sessionId)
        case "CodexMessage":
            if let output = toolOutput {
                appendLine(TerminalLine(text: "\(prefix)\(String(output.prefix(160)))", type: .output), sessionId: sessionId)
            }
        default:
            appendLine(TerminalLine(text: "\(prefix)[\(toolName)]", type: .system), sessionId: sessionId)
        }
        isStreaming = true

        // Add thinking indicator — will be removed when next event arrives
        appendLine(TerminalLine(text: "", type: .thinking), sessionId: sessionId)
    }

    private func handlePermissionRequest(_ json: [String: Any], sessionId: String?) {
        let permissionId = json["permissionId"] as? String ?? UUID().uuidString
        let toolName = json["tool_name"] as? String ?? "Unknown"
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        let source = json["source"] as? String

        var question: String? = nil
        var desc = toolName
        var options: [ApprovalRequest.OptionItem] = []

        if let questions = toolInput["questions"] as? [[String: Any]],
           let firstQ = questions.first {
            question = firstQ["question"] as? String
            desc = toolInput["command"] as? String
                ?? firstQ["header"] as? String
                ?? toolName
            if let opts = firstQ["options"] as? [[String: Any]] {
                options = opts.map { opt in
                    ApprovalRequest.OptionItem(
                        label: opt["label"] as? String ?? "",
                        description: opt["description"] as? String
                    )
                }
            }
        } else if let path = toolInput["file_path"] as? String {
            desc = "\(toolName) \((path as NSString).lastPathComponent)"
            options = [
                ApprovalRequest.OptionItem(label: "Yes"),
                ApprovalRequest.OptionItem(label: "Yes, allow all"),
                ApprovalRequest.OptionItem(label: "No"),
            ]
        } else if let cmd = toolInput["command"] as? String {
            desc = "Run: \(String(cmd.prefix(50)))"
            options = [
                ApprovalRequest.OptionItem(label: "Yes"),
                ApprovalRequest.OptionItem(label: "Yes, allow all"),
                ApprovalRequest.OptionItem(label: "No"),
            ]
        } else {
            options = [
                ApprovalRequest.OptionItem(label: "Yes"),
                ApprovalRequest.OptionItem(label: "No"),
            ]
        }

        // Codex: show inline text in terminal instead of approval card
        if source == "codex" {
            removeThinkingLine(sessionId: sessionId)

            appendLine(TerminalLine(text: "── Codex Approval ──", type: .system), sessionId: sessionId)
            appendLine(TerminalLine(text: desc, type: .command), sessionId: sessionId)
            if let q = question, q != desc {
                appendLine(TerminalLine(text: q, type: .output), sessionId: sessionId)
            }
            appendLine(TerminalLine(text: "Say 'y' to approve, 'n' to deny", type: .system), sessionId: sessionId)

            let approval = ApprovalRequest(
                permissionId: permissionId,
                toolName: toolName, actionSummary: desc,
                question: question, options: options
            )
            UserDefaults.standard.set(permissionId, forKey: "watch_pending_permission")

            if let sid = sessionId, let idx = sessionIndex(for: sid) {
                sessions[idx].pendingApproval = approval
                sessions[idx].activity = .waitingApproval
                activeSessionIndex = idx
            }

            HapticManager.approvalNeeded()
            return
        }

        // Read-only flag: session is an external non-tmux terminal
        let readOnly = json["readOnly"] as? Bool ?? false

        let approval = ApprovalRequest(
            permissionId: permissionId,
            toolName: toolName, actionSummary: desc,
            question: question, options: options,
            readOnly: readOnly
        )

        pendingApproval = approval
        UserDefaults.standard.set(permissionId, forKey: "watch_pending_permission")

        // Only attach the approval to the session the server explicitly identified.
        // Do NOT fall back to active/first session — that would show it in the wrong place.
        if let sid = sessionId, let idx = sessionIndex(for: sid) {
            sessions[idx].pendingApproval = approval
            sessions[idx].activity = .waitingApproval
            // Auto-switch to the session that needs approval
            activeSessionIndex = idx
        }

        HapticManager.approvalNeeded()
    }

    private func handlePermissionCleared(_ json: [String: Any], sessionId: String?) {
        let permissionId = json["permissionId"] as? String

        if pendingApproval?.permissionId == permissionId || permissionId == nil {
            pendingApproval = nil
        }

        if let sid = sessionId, let idx = sessionIndex(for: sid) {
            if sessions[idx].pendingApproval?.permissionId == permissionId || permissionId == nil {
                sessions[idx].pendingApproval = nil
                if sessions[idx].activity == .waitingApproval {
                    sessions[idx].activity = .running
                }
            }
        } else {
            for idx in sessions.indices {
                if sessions[idx].pendingApproval?.permissionId == permissionId || permissionId == nil {
                    sessions[idx].pendingApproval = nil
                    if sessions[idx].activity == .waitingApproval {
                        sessions[idx].activity = .running
                    }
                }
            }
        }

        if UserDefaults.standard.string(forKey: "watch_pending_permission") == permissionId || permissionId == nil {
            UserDefaults.standard.removeObject(forKey: "watch_pending_permission")
        }
    }

    private func handleSessionEvent(_ json: [String: Any], sessionId: String?) {
        let state = json["state"] as? String ?? ""
        let agent = json["agent"] as? String
        let cwd = json["cwd"] as? String ?? ""
        let folderName = json["folderName"] as? String ?? ""
        let backend = json["backend"] as? String ?? "external"
        let writable = json["writable"] as? Bool ?? false
        let sharedTerminal = json["sharedTerminal"] as? Bool ?? (backend == "tmux")
        let externalSessionId = json["externalSessionId"] as? String
        let tmuxSessionName = json["tmuxSessionName"] as? String

        switch state {
        case "running":
            isStreaming = true
            if let sid = sessionId {
                if let idx = sessionIndex(for: sid) {
                    let existingLines = sessions[idx].terminalLines
                    let existingApproval = sessions[idx].pendingApproval
                    let nextActivity: SessionActivity = sessions[idx].activity != .waitingApproval ? .idle : .waitingApproval
                    var updated = AgentSession(
                        id: sid,
                        agent: AgentType(rawValue: agent ?? sessions[idx].agent.rawValue) ?? sessions[idx].agent,
                        cwd: cwd.isEmpty ? sessions[idx].cwd : cwd,
                        folderName: folderName.isEmpty ? sessions[idx].folderName : folderName,
                        activity: nextActivity,
                        backend: backend,
                        writable: writable,
                        sharedTerminal: sharedTerminal,
                        externalSessionId: externalSessionId ?? sessions[idx].externalSessionId,
                        tmuxSessionName: tmuxSessionName ?? sessions[idx].tmuxSessionName
                    )
                    updated.terminalLines = existingLines
                    updated.pendingApproval = existingApproval
                    sessions[idx] = updated
                } else {
                    // New session appeared
                    let agentType = AgentType(rawValue: agent ?? "claude") ?? .claude
                    let newSession = AgentSession(
                        id: sid, agent: agentType, cwd: cwd,
                        folderName: folderName, activity: .idle,
                        backend: backend,
                        writable: writable,
                        sharedTerminal: sharedTerminal,
                        externalSessionId: externalSessionId,
                        tmuxSessionName: tmuxSessionName
                    )
                    sessions.append(newSession)
                    // Auto-switch to the new session
                    activeSessionIndex = sessions.count - 1
                }
            }

        case "ended":
            isStreaming = false
            if let sid = sessionId, let idx = sessionIndex(for: sid) {
                sessions[idx].activity = .ended
                appendLine(TerminalLine(text: "Session ended", type: .system), sessionId: sid)
            } else {
                appendLine(TerminalLine(text: "Session ended", type: .system))
            }

        case "connected":
            // Bridge-level: watch paired
            break

        default:
            break
        }
    }

    private func handleSessionRemoved(_ json: [String: Any], sessionId: String?) {
        let removedId = sessionId ?? json["sessionId"] as? String
        guard let removedId, let idx = sessionIndex(for: removedId) else { return }

        sessions.remove(at: idx)
        terminalLines.removeAll { $0.sessionId == removedId }

        if activeSessionIndex >= sessions.count {
            activeSessionIndex = max(sessions.count - 1, 0)
        }

        if sessions.isEmpty {
            isStreaming = false
        }

        if pendingApproval?.permissionId != nil,
           !sessions.contains(where: { $0.pendingApproval?.permissionId == pendingApproval?.permissionId }) {
            pendingApproval = nil
        }
    }

    private func handleConversationMessage(_ json: [String: Any], sessionId: String?) {
        guard let role = json["role"] as? String,
              let text = json["text"] as? String else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch role {
        case "user":
            let line = TerminalLine(text: "> \(trimmed)", type: .command)
            let appended = appendLineIfNotDuplicate(line, sessionId: sessionId)
            if !appended,
               let sid = sessionId,
               let session = session(for: sid),
               session.sharedTerminal {
                return
            }
        case "assistant":
            let line = TerminalLine(text: trimmed, type: .output)
            let appended = appendLineIfNotDuplicate(line, sessionId: sessionId)
            if !appended,
               let sid = sessionId,
               let session = session(for: sid),
               session.sharedTerminal {
                return
            }
            if let sid = sessionId, let idx = sessionIndex(for: sid) {
                sessions[idx].activity = .running
            }
            isStreaming = true
        default:
            break
        }
    }

    // MARK: - Permission response

    func respondToPermissionWithOption(_ optionLabel: String, index: Int) {
        let approval = pendingApproval ?? activeSession?.pendingApproval
        guard let permissionId = approval?.permissionId ?? UserDefaults.standard.string(forKey: "watch_pending_permission"),
              let baseURL = bridge.baseURL, let token = bridge.token else { return }

        // Find the session that actually owns this approval (not just the active one).
        let sessionId: String? = sessions.first(where: { $0.pendingApproval?.permissionId == permissionId })?.id
        pendingApproval = nil
        if let sid = sessionId, let idx = sessionIndex(for: sid) {
            sessions[idx].pendingApproval = nil
            sessions[idx].activity = .running
        }

        let url = baseURL.appendingPathComponent("command")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.addCloudflareAccessHeaders()

        let body: [String: Any] = [
            "permissionId": permissionId,
            "decision": ["behavior": "allow"],
            "selectedOption": optionLabel,
            "optionIndex": index
        ]
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: urlRequest) { [weak self] _, response, error in
            if let error {
                print("[WatchViewState] Permission response failed: \(error)")
                return
            }
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401 {
                print("[WatchViewState] Permission response 401 — bridge token changed, re-pairing")
                DispatchQueue.main.async { self?.handleTokenRejected() }
            } else if http.statusCode == 404 {
                print("[WatchViewState] Permission response 404 — permissionId not found (bridge restarted?)")
            } else if http.statusCode != 200 {
                print("[WatchViewState] Permission response unexpected status: \(http.statusCode)")
            }
        }.resume()

        appendLine(TerminalLine(text: "→ \(optionLabel)", type: .command), sessionId: sessionId)
        UserDefaults.standard.removeObject(forKey: "watch_pending_permission")
    }

    func respondToPermission(approved: Bool) {
        let approval = pendingApproval ?? activeSession?.pendingApproval
        guard let permissionId = approval?.permissionId ?? UserDefaults.standard.string(forKey: "watch_pending_permission"),
              let baseURL = bridge.baseURL, let token = bridge.token else { return }

        // Find the session that actually owns this approval.
        let sessionId: String? = sessions.first(where: { $0.pendingApproval?.permissionId == permissionId })?.id
        pendingApproval = nil
        if let sid = sessionId, let idx = sessionIndex(for: sid) {
            sessions[idx].pendingApproval = nil
            sessions[idx].activity = .running
        }

        let url = baseURL.appendingPathComponent("command")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.addCloudflareAccessHeaders()

        let body: [String: Any] = [
            "permissionId": permissionId,
            "decision": ["behavior": approved ? "allow" : "deny"]
        ]
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: urlRequest) { [weak self] _, response, error in
            if let error {
                print("[WatchViewState] Permission response failed: \(error)")
                return
            }
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401 {
                print("[WatchViewState] Permission response 401 — bridge token changed, re-pairing")
                DispatchQueue.main.async { self?.handleTokenRejected() }
            } else if http.statusCode == 404 {
                print("[WatchViewState] Permission response 404 — permissionId not found (bridge restarted?)")
            } else if http.statusCode != 200 {
                print("[WatchViewState] Permission response unexpected status: \(http.statusCode)")
            }
        }.resume()

        appendLine(
            TerminalLine(text: approved ? "✓ Approved" : "✗ Denied", type: approved ? .output : .error),
            sessionId: sessionId
        )
        UserDefaults.standard.removeObject(forKey: "watch_pending_permission")
    }

    // MARK: - Clear terminal

    func clearTerminal(sessionId: String? = nil) {
        let sid = sessionId ?? activeSession?.id
        if let sid, let idx = sessionIndex(for: sid) {
            sessions[idx].terminalLines.removeAll()
            terminalLines.removeAll { $0.sessionId == sid }
            return
        }

        for idx in sessions.indices {
            sessions[idx].terminalLines.removeAll()
        }
        terminalLines.removeAll()
    }

    // MARK: - Voice command (direct to bridge)

    func respondToCodexApproval(approved: Bool, sessionId: String) {
        guard let idx = sessionIndex(for: sessionId),
              let approval = sessions[idx].pendingApproval,
              let permissionId = approval.permissionId,
              let baseURL = bridge.baseURL,
              let token = bridge.token else { return }

        sessions[idx].pendingApproval = nil
        sessions[idx].activity = .running

        let optionIndex = approved ? 0 : (approval.options.count - 1)
        let optionLabel = approved
            ? (approval.options.first?.label ?? "Yes, proceed")
            : (approval.options.last?.label ?? "No")

        let url = baseURL.appendingPathComponent("command")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.addCloudflareAccessHeaders()

        let body: [String: Any] = [
            "permissionId": permissionId,
            "decision": ["behavior": approved ? "allow" : "deny"],
            "selectedOption": optionLabel,
            "optionIndex": optionIndex
        ]
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: urlRequest) { _, _, error in
            if let error { print("[WatchViewState] Codex approval response failed: \(error)") }
        }.resume()

        appendLine(
            TerminalLine(text: approved ? "✓ Approved" : "✗ Denied", type: approved ? .output : .error),
            sessionId: sessionId
        )
        // Add thinking indicator after approval
        if approved {
            appendLine(TerminalLine(text: "", type: .thinking), sessionId: sessionId)
        }
        UserDefaults.standard.removeObject(forKey: "watch_pending_permission")
    }

    func sendVoiceCommand(_ text: String, sessionId: String? = nil) {
        let sid = sessionId ?? activeSession?.id

        // Intercept y/n for Codex inline approvals
        if let targetSid = sid, let idx = sessionIndex(for: targetSid),
           sessions[idx].agent == .codex,
           sessions[idx].activity == .waitingApproval,
           sessions[idx].pendingApproval != nil {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["y", "yes", "1", "approve", "proceed"].contains(trimmed) {
                appendLine(TerminalLine(text: "> \(text)", type: .command), sessionId: targetSid)
                respondToCodexApproval(approved: true, sessionId: targetSid)
                return
            } else if ["n", "no", "2", "deny", "reject"].contains(trimmed) {
                appendLine(TerminalLine(text: "> \(text)", type: .command), sessionId: targetSid)
                respondToCodexApproval(approved: false, sessionId: targetSid)
                return
            }
        }

        let shouldEchoLocally = {
            if let sid, let session = session(for: sid) {
                return !session.sharedTerminal
            }
            return activeSession?.agent != .claude
        }()
        if shouldEchoLocally {
            appendLine(TerminalLine(text: "> \(text)", type: .command), sessionId: sid)
        }
        appendLine(TerminalLine(text: "", type: .thinking), sessionId: sid)

        guard let baseURL = bridge.baseURL, let token = bridge.token else { return }

        let url = baseURL.appendingPathComponent("command")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addCloudflareAccessHeaders()

        var body: [String: Any]
        if let sid,
           let idx = sessionIndex(for: sid),
           sessions[idx].activity == .running,
           !sessions[idx].sharedTerminal {
            appendLine(TerminalLine(text: "Interrupting current task…", type: .system), sessionId: sid)
            body = [
                "interrupt": true,
                "sessionId": sid,
                "command": text + "\n"
            ]
        } else {
            body = ["command": text + "\n"]
            if let sid { body["sessionId"] = sid }
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error { print("[WatchViewState] Command send failed: \(error)") }
        }.resume()
    }

    // MARK: - Token rejected (bridge restarted)

    func handleTokenRejected() {
        print("[WatchViewState] Token rejected — resetting to pairing screen")
        stopEventStream()
        bridge.unpair()
        isPaired = false
        terminalLines = []
        sessions = []
        activeSessionIndex = 0
        pendingApproval = nil
        isStreaming = false
        sessionState = .disconnected
    }

    // MARK: - Helpers

    private func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - SSE URLSession Delegate

private class SSEDelegate: NSObject, URLSessionDataDelegate {
    weak var owner: WatchViewState?

    init(owner: WatchViewState) {
        self.owner = owner
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        owner?.handleSSEData(text)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            print("[SSE] Token rejected (401) — bridge restarted, need to re-pair")
            DispatchQueue.main.async { [weak self] in
                self?.owner?.handleTokenRejected()
            }
            return .cancel
        }
        return .allow
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            print("[SSE] Connection lost: \(error.localizedDescription)")
        }

        if let http = task.response as? HTTPURLResponse, http.statusCode == 401 {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let owner = self?.owner, owner.isPaired else { return }
            owner.startEventStream()
        }
    }
}
