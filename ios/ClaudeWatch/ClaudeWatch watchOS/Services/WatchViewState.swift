import SwiftUI

final class WatchViewState: ObservableObject {
    static let shared = WatchViewState()

    @Published var isPaired: Bool = false
    @Published var sessionState: SessionState = .disconnected
    @Published var terminalLines: [TerminalLine] = []
    @Published var pendingApproval: ApprovalRequest? = nil
    @Published var isStreaming: Bool = false
    @Published var taskCompleteSummary: String? = nil
    @Published var isReachable: Bool = false

    @Published var sessions: [AgentSession] = []
    @Published var activeSessionIndex: Int = 0

    var activeSession: AgentSession? {
        guard sessions.indices.contains(activeSessionIndex) else { return nil }
        return sessions[activeSessionIndex]
    }

    private let sessionManager = WatchSessionManager.shared
    private let maxLines = 600

    private init() {
        isReachable = sessionManager.isReachable
        if let initialState = sessionManager.lastReceivedState {
            applySessionState(initialState)
        }

        sessionManager.onMessageReceived = { [weak self] message in
            DispatchQueue.main.async {
                self?.handleCompanionMessage(message)
            }
        }

        sessionManager.onApplicationContextReceived = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isReachable = WatchSessionManager.shared.isReachable
            }
        }

        sessionManager.onBridgeCredentialsReceived = { [weak self] credentials in
            DispatchQueue.main.async {
                self?.applyBridgeCredentials(credentials)
            }
        }

        requestCompanionSync()
    }

    func requestCompanionSync() {
        isReachable = sessionManager.isReachable
        sessionManager.requestBridgeCredentialsSync()
        sessionManager.requestRelaySnapshot()
        if WatchBridgeClient.shared.isPaired {
            Task {
                await self.refreshBridgeSnapshotFromWatch()
            }
        }
    }

    private func applyBridgeCredentials(_ credentials: WatchSessionManager.BridgeCredentialsSync) {
        if credentials.cleared {
            WatchBridgeClient.shared.unpair()
            sessionState.machineName = nil
            sessions = []
            refreshDerivedState()
            return
        }

        guard let baseURL = credentials.baseURL, let token = credentials.token else { return }
        WatchBridgeClient.shared.applyPairedCredentials(baseURL: baseURL, token: token)
        if let machineName = credentials.machineName {
            sessionState.machineName = machineName
        }
        refreshDerivedState()
        sessionManager.requestRelaySnapshot()
        Task {
            await self.refreshBridgeSnapshotFromWatch()
        }
    }

    @MainActor
    private func refreshBridgeSnapshotFromWatch() async {
        guard WatchBridgeClient.shared.isPaired else { return }
        do {
            let status = try await WatchBridgeClient.shared.fetchStatus()
            sessionState.connection = (status.state == "connected" || status.state == "idle")
                ? .connected
                : .disconnected
            if let snapshot = status.sessions, !snapshot.isEmpty {
                applySessionSnapshot(snapshot)
            } else {
                refreshDerivedState()
            }
        } catch {
            print("[WatchViewState] Failed to refresh bridge snapshot directly: \(error)")
            refreshDerivedState()
        }
    }

    func appendLine(_ line: TerminalLine, sessionId: String? = nil) {
        terminalLines.append(line)
        if terminalLines.count > maxLines {
            terminalLines.removeFirst(terminalLines.count - maxLines)
        }

        if let sid = sessionId ?? line.sessionId, let idx = sessionIndex(for: sid) {
            sessions[idx].terminalLines.append(line)
            if sessions[idx].terminalLines.count > maxLines {
                sessions[idx].terminalLines.removeFirst(sessions[idx].terminalLines.count - maxLines)
            }
        }
    }

    @discardableResult
    private func appendLineIfNotDuplicate(_ line: TerminalLine, sessionId: String? = nil) -> Bool {
        if let sid = sessionId ?? line.sessionId, let idx = sessionIndex(for: sid) {
            if sessions[idx].terminalLines.suffix(6).contains(where: { $0.type == line.type && $0.text == line.text }) {
                return false
            }
        } else if terminalLines.suffix(6).contains(where: { $0.type == line.type && $0.text == line.text }) {
            return false
        }

        appendLine(line, sessionId: sessionId ?? line.sessionId)
        return true
    }

    private func sessionIndex(for id: String) -> Int? {
        sessions.firstIndex(where: { $0.id == id || $0.externalSessionId == id })
    }

    private func session(for id: String) -> AgentSession? {
        guard let index = sessionIndex(for: id) else { return nil }
        return sessions[index]
    }

    func applySessionSnapshot(_ snapshot: [AgentSession]) {
        let existingById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let currentSessionId = activeSession?.id

        sessions = snapshot.map { incoming in
            guard let existing = existingById[incoming.id] else { return incoming }
            var merged = incoming
            if merged.terminalLines.isEmpty {
                merged.terminalLines = existing.terminalLines
            }
            if merged.pendingApproval == nil {
                merged.pendingApproval = existing.pendingApproval
            }
            if merged.lastVisualActivityAt == nil {
                merged.lastVisualActivityAt = existing.lastVisualActivityAt
            }
            return merged
        }

        if let currentSessionId,
           let restoredIndex = sessions.firstIndex(where: { $0.id == currentSessionId }) {
            activeSessionIndex = restoredIndex
        } else if let approvalIndex = sessions.firstIndex(where: { $0.pendingApproval != nil }) {
            activeSessionIndex = approvalIndex
        } else if activeSessionIndex >= sessions.count {
            activeSessionIndex = max(sessions.count - 1, 0)
        }

        pendingApproval = sessions.first(where: { $0.pendingApproval != nil })?.pendingApproval
        rebuildFlatTerminalLines()
        refreshDerivedState()
    }

    private func handleCompanionMessage(_ message: WatchMessage) {
        switch message {
        case .terminalUpdate(let update):
            applyTerminalUpdate(update)
        case .approvalRequestMessage(let request):
            applyApprovalRequest(request)
        case .sessionStateUpdate(let state):
            applySessionState(state)
        case .sessionsUpdate(let update):
            applySessionSnapshot(update.sessions)
        case .connectionStatus(let status):
            sessionState.connection = status.state
            if let machineName = status.machineName {
                sessionState.machineName = machineName
            }
            refreshDerivedState()
        default:
            break
        }
    }

    private func applyTerminalUpdate(_ update: WatchMessage.TerminalUpdate) {
        for line in update.lines {
            _ = appendLineIfNotDuplicate(line, sessionId: line.sessionId)
            if let sid = line.sessionId, let idx = sessionIndex(for: sid), line.type != .thinking {
                sessions[idx].lastVisualActivityAt = line.timestamp
            }
        }
        refreshDerivedState()
    }

    private func applyApprovalRequest(_ request: ApprovalRequest) {
        pendingApproval = request
        if let permissionId = request.permissionId {
            UserDefaults.standard.set(permissionId, forKey: "watch_pending_permission")
        }

        if let sid = request.sessionId, let idx = sessionIndex(for: sid) {
            sessions[idx].pendingApproval = request
            sessions[idx].activity = .waitingApproval
            activeSessionIndex = idx
        }

        HapticManager.approvalNeeded()
        refreshDerivedState()
    }

    private func applySessionState(_ state: SessionState) {
        sessionState = state
        refreshDerivedState()
    }

    private func refreshDerivedState() {
        isReachable = sessionManager.isReachable

        if let approvalSession = sessions.first(where: { $0.pendingApproval != nil }) {
            pendingApproval = approvalSession.pendingApproval
            if let approvalIndex = sessionIndex(for: approvalSession.id) {
                activeSessionIndex = approvalIndex
            }
        }

        if activeSessionIndex >= sessions.count {
            activeSessionIndex = max(sessions.count - 1, 0)
        }

        isStreaming = sessions.contains(where: {
            $0.activity == .running || $0.activity == .waitingApproval || !$0.terminalLines.isEmpty
        })

        isPaired = WatchBridgeClient.shared.isPaired
            || sessionState.machineName != nil
            || sessionState.connection != .disconnected
            || !sessions.isEmpty
    }

    private func rebuildFlatTerminalLines() {
        terminalLines = Array(
            sessions
                .flatMap(\.terminalLines)
                .sorted { $0.timestamp < $1.timestamp }
                .suffix(maxLines)
        )
    }

    private func clearApprovalLocally(permissionId: String, sessionId: String?) {
        if pendingApproval?.permissionId == permissionId {
            pendingApproval = nil
        }

        if let sid = sessionId, let idx = sessionIndex(for: sid) {
            sessions[idx].pendingApproval = nil
            if sessions[idx].activity == .waitingApproval {
                sessions[idx].activity = .running
            }
        } else {
            for idx in sessions.indices where sessions[idx].pendingApproval?.permissionId == permissionId {
                sessions[idx].pendingApproval = nil
                if sessions[idx].activity == .waitingApproval {
                    sessions[idx].activity = .running
                }
            }
        }

        UserDefaults.standard.removeObject(forKey: "watch_pending_permission")
        refreshDerivedState()
    }

    func respondToPermissionWithOption(_ optionLabel: String, index: Int) {
        let approval = pendingApproval ?? activeSession?.pendingApproval
        guard let permissionId = approval?.permissionId else { return }

        let sessionId = approval?.sessionId
            ?? sessions.first(where: { $0.pendingApproval?.permissionId == permissionId })?.id

        clearApprovalLocally(permissionId: permissionId, sessionId: sessionId)

        let response = WatchMessage.ApprovalResponse(
            permissionId: permissionId,
            optionLabel: optionLabel,
            optionIndex: index,
            sessionId: sessionId
        )
        sessionManager.send(.approvalResponse(response))

        appendLine(TerminalLine(text: "→ \(optionLabel)", type: .command, sessionId: sessionId), sessionId: sessionId)
    }

    func respondToPermission(approved: Bool) {
        let approval = pendingApproval ?? activeSession?.pendingApproval
        guard let request = approval, !request.options.isEmpty else { return }

        let optionIndex = approved ? 0 : (request.options.count - 1)
        let optionLabel = request.options[optionIndex].label
        respondToPermissionWithOption(optionLabel, index: optionIndex)
    }

    func clearTerminal(sessionId: String? = nil) {
        let sid = sessionId ?? activeSession?.id
        if let sid, let idx = sessionIndex(for: sid) {
            sessions[idx].terminalLines.removeAll()
            terminalLines.removeAll { $0.sessionId == sid }
        } else {
            for idx in sessions.indices {
                sessions[idx].terminalLines.removeAll()
            }
            terminalLines.removeAll()
        }
        refreshDerivedState()
    }

    func sendVoiceCommand(_ text: String, sessionId: String? = nil) {
        let sid = sessionId ?? activeSession?.id
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let targetSid = sid,
           let idx = sessionIndex(for: targetSid),
           sessions[idx].agent == .codex,
           sessions[idx].activity == .waitingApproval,
           let approval = sessions[idx].pendingApproval {
            let lowered = trimmed.lowercased()
            if ["y", "yes", "1", "approve", "proceed"].contains(lowered),
               let option = approval.options.first {
                respondToPermissionWithOption(option.label, index: 0)
                return
            }
            if ["n", "no", "2", "deny", "reject"].contains(lowered),
               let option = approval.options.last {
                respondToPermissionWithOption(option.label, index: max(approval.options.count - 1, 0))
                return
            }
        }

        appendLine(TerminalLine(text: "> \(trimmed)", type: .command, sessionId: sid), sessionId: sid)
        appendLine(TerminalLine(text: "", type: .thinking, sessionId: sid), sessionId: sid)

        if let sid, let idx = sessionIndex(for: sid) {
            sessions[idx].activity = .running
            sessions[idx].lastVisualActivityAt = Date()
        }

        sessionManager.send(.voiceCommand(.init(transcribedText: trimmed, sessionId: sid)))
        refreshDerivedState()
    }
}
