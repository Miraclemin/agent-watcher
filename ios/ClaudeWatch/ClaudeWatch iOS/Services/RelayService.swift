import Foundation
import Combine
import SwiftUI
import UIKit

/// Coordinates communication between the bridge server, SSE event stream,
/// and the Apple Watch via WCSession.
///
/// Acts as the central hub: bridge events are received via SSE/polling,
/// parsed, and forwarded to the watch. Commands from the watch are
/// received via WCSession and forwarded to the bridge via HTTP.
@MainActor
final class RelayService: ObservableObject {

    // MARK: - Singleton

    static let shared = RelayService()

    // MARK: - Published state

    @Published private(set) var isPaired: Bool = false
    @Published private(set) var machineName: String?
    @Published private(set) var modelName: String?
    @Published private(set) var workingDirectory: String?
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var recentTerminalLines: [TerminalLine] = []
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var lastConnected: Date?
    @Published private(set) var isThinking: Bool = false
    @Published private(set) var pairingNotice: String?

    // Multi-session
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var focusedSessionId: String?

    // Permission prompt state (uses shared ApprovalRequest model)
    @Published var pendingApproval: ApprovalRequest? = nil
    @Published private(set) var pendingApprovalSessionId: String?

    // MARK: - Private

    private let bridgeClient = BridgeClient()
    private let sseClient = SSEClient()
    private let discovery = BonjourDiscovery()
    private let notificationService = NotificationService()
    private let sessionManager = WatchSessionManager.shared

    private let terminalBuffer = OutputRingBuffer<TerminalLine>(capacity: 50)
    private var terminalBatchTimer: Timer?
    private var pendingTerminalLines: [TerminalLine] = []

    private var elapsedTimer: Timer?
    private var heartbeatTimer: Timer?
    private var sessionStartDate: Date?
    private var isAppActive = true

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    private init() {
        isPaired = bridgeClient.isPaired
        setupWatchMessageHandler()
        setupSSEEventHandler()
        sessionManager.onRelaySnapshotRequested = { [weak self] in
            Task { @MainActor in
                self?.pushWatchSnapshot()
            }
        }
        sessionManager.onBridgeCredentialsRequested = { [weak self] in
            Task { @MainActor in
                self?.syncWatchBridgeCredentials()
            }
        }

        if isPaired {
            Task { await reconnect() }
        }
    }

    // MARK: - Pairing

    /// Discovers the bridge on LAN and pairs with the given code.
    func pair(code: String) async throws {
        print("[RelayService] Starting pair with code: \(code)")

        // Discover bridge via Bonjour (or localhost fallback)
        let service: BonjourDiscovery.DiscoveredService
        do {
            service = try await discovery.discover()
            print("[RelayService] Discovered bridge at \(service.host):\(service.port)")
        } catch {
            print("[RelayService] Discovery failed: \(error)")
            throw error
        }

        // Configure the HTTP client
        bridgeClient.configure(host: service.host, port: service.port)

        // Attempt pairing
        do {
            try await bridgeClient.pair(code: code)
            print("[RelayService] Pairing successful!")
        } catch {
            print("[RelayService] Pairing failed: \(error)")
            throw error
        }

        // Success
        pairingNotice = nil
        machineName = service.machineName
        lastConnected = Date()
        isPaired = true
        connectionState = .connected

        UserDefaults.standard.set(service.host, forKey: "bridge_host")
        UserDefaults.standard.set(Int(service.port), forKey: "bridge_port")
        UserDefaults.standard.set(service.machineName, forKey: "paired_machine_name")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_connected")

        print("[RelayService] isPaired = true, starting event stream")

        syncWatchBridgeCredentials()

        // Start SSE connection
        startEventStream()
        startElapsedTimer()

        // Notify watch of connection
        updateWatchState()
    }

    /// Pairs using a full URL (for Cloudflare Tunnel: https://watch.example.com).
    func pairWithURL(_ urlString: String, code: String) async throws {
        print("[RelayService] Cloudflare URL pair: \(urlString)")
        bridgeClient.configureURL(urlString)
        try await bridgeClient.pair(code: code)

        pairingNotice = nil
        lastConnected = Date()
        isPaired = true
        connectionState = .connected

        UserDefaults.standard.set(urlString, forKey: "bridge_url")
        UserDefaults.standard.removeObject(forKey: "bridge_host")

        syncWatchBridgeCredentials()

        startEventStream()
        startElapsedTimer()
        updateWatchState()
    }

    /// Pairs using a manual IP address (fallback when Bonjour fails on real devices).
    func pairWithIP(_ ip: String, code: String) async throws {
        print("[RelayService] Manual IP pair: \(ip), code: \(code)")

        let service = try await discovery.discoverAtIP(ip)
        bridgeClient.configure(host: service.host, port: service.port)

        try await bridgeClient.pair(code: code)

        pairingNotice = nil
        machineName = service.machineName
        lastConnected = Date()
        isPaired = true
        connectionState = .connected

        UserDefaults.standard.set(service.host, forKey: "bridge_host")
        UserDefaults.standard.set(Int(service.port), forKey: "bridge_port")
        UserDefaults.standard.set(service.machineName, forKey: "paired_machine_name")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_connected")

        syncWatchBridgeCredentials()

        startEventStream()
        startElapsedTimer()
        updateWatchState()
    }

    /// Removes pairing and disconnects.
    func unpair() {
        sseClient.disconnect()
        bridgeClient.clearCredentials()
        stopElapsedTimer()
        stopHeartbeatTimer()
        terminalBatchTimer?.invalidate()
        terminalBatchTimer = nil

        isPaired = false
        machineName = nil
        modelName = nil
        workingDirectory = nil
        elapsedSeconds = 0
        recentTerminalLines = []
        sessions = []
        focusedSessionId = nil
        pendingApproval = nil
        pendingApprovalSessionId = nil
        connectionState = .disconnected

        UserDefaults.standard.removeObject(forKey: "paired_machine_name")
        UserDefaults.standard.removeObject(forKey: "last_connected")

        sessionManager.clearBridgeCredentials()
        updateWatchState()
    }

    func clearPairingNotice() {
        pairingNotice = nil
    }

    // MARK: - Reconnection

    private func reconnect() async {
        guard bridgeClient.isPaired else { return }

        machineName = UserDefaults.standard.string(forKey: "paired_machine_name")
        if let ts = UserDefaults.standard.object(forKey: "last_connected") as? TimeInterval {
            lastConnected = Date(timeIntervalSince1970: ts)
        }

        connectionState = .connecting
        syncWatchBridgeCredentials()
        startEventStream()
        Task { await refreshSessionsFromBridgeStatus() }
        startElapsedTimer()
        restartHeartbeatTimerIfNeeded()
    }

    // MARK: - SSE

    private func startEventStream() {
        guard let baseURL = bridgeClient.baseURL, let token = bridgeClient.token else { return }
        sseClient.connect(baseURL: baseURL, token: token)
        restartHeartbeatTimerIfNeeded()
    }

    private func setupSSEEventHandler() {
        sseClient.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleBridgeEvent(event)
            }
        }

        sseClient.onAuthRejected = { [weak self] in
            Task { @MainActor in
                self?.handleBridgeAuthRejected()
            }
        }

        sseClient.onStateChange = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .connected:
                    self?.connectionState = .connected
                    self?.lastConnected = Date()
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_connected")
                    Task { await self?.refreshSessionsFromBridgeStatus() }
                    self?.restartHeartbeatTimerIfNeeded()
                    self?.updateWatchState()
                case .connecting:
                    self?.connectionState = .connecting
                case .disconnected:
                    self?.connectionState = .disconnected
                    self?.stopHeartbeatTimer()
                    self?.updateWatchState()
                case .polling:
                    // Still considered connected, just degraded
                    break
                }
            }
        }
    }

    private func handleBridgeEvent(_ event: SSEClient.SSEEvent) {
        guard let eventType = event.event else { return }
        let data = event.data

        switch eventType {
        case "session-heartbeat":
            handleSessionHeartbeat(data)

        case "pty-output":
            handlePtyOutput(data)

        case "permission-request":
            handlePermissionRequest(data)

        case "permission-cleared":
            handlePermissionCleared(data)

        case "session":
            handleSessionEvent(data)

        case "session-removed":
            handleSessionRemoved(data)

        case "conversation-message":
            handleConversationMessage(data)

        case "tool-output":
            handleToolOutput(data)

        case "task-complete":
            handleTaskComplete(data)

        case "error":
            handleError(data)

        case "stop":
            handleStop(data)

        case "poll-status":
            handlePollStatus(data)

        default:
            break
        }
    }

    func updateScenePhase(_ phase: ScenePhase) {
        isAppActive = phase == .active
        if isAppActive {
            restartHeartbeatTimerIfNeeded()
        } else {
            stopHeartbeatTimer()
        }
    }

    private func restartHeartbeatTimerIfNeeded() {
        stopHeartbeatTimer()
        guard isPaired, isAppActive else { return }

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.sendSessionHeartbeat()
        }
        heartbeatTimer?.tolerance = 2
        sendSessionHeartbeat()
    }

    private func stopHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func sendSessionHeartbeat() {
        guard connectionState != .disconnected else { return }
        let runningSessionId = focusedSessionId ?? sessions.first(where: { $0.activity == .running })?.id

        Task {
            do {
                try await bridgeClient.sendHeartbeat(sessionId: runningSessionId)
            } catch BridgeClient.BridgeError.unauthorized {
                await MainActor.run { self.handleBridgeAuthRejected() }
            } catch {
                // Keep SSE/polling as the source of truth for connectivity.
            }
        }
    }

    // MARK: - Event handlers

    private func handlePtyOutput(_ data: String) {
        guard let json = parseJSON(data),
              let text = json["text"] as? String else { return }
        let sessionId = json["sessionId"] as? String
        let isBootstrap = json["bootstrap"] as? Bool ?? false

        let cleaned = sanitizeTerminalText(text)
        guard shouldDisplayPtyOutput(cleaned, sessionId: sessionId, isBootstrap: isBootstrap) else { return }

        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let line = TerminalLine(text: cleaned, type: .output, sessionId: sessionId)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
        appendToSessionIfNotDuplicate(line, sessionId: sessionId)
        if !isBootstrap {
            markSessionVisualActivity(sessionId)
        }

        // Batch terminal updates to the watch (1-second window)
        pendingTerminalLines.append(line)
        scheduleBatchSend()
    }

    private func handlePermissionRequest(_ data: String) {
        guard let json = parseJSON(data) else { return }

        let permissionId = json["permissionId"] as? String ?? UUID().uuidString
        let toolName = json["tool_name"] as? String ?? "Unknown"
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        let sessionId = json["sessionId"] as? String

        var question: String? = nil
        var desc = toolName
        var options: [ApprovalRequest.OptionItem] = []

        // Parse questions/options (Codex format with questions array)
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
            let filename = (path as NSString).lastPathComponent
            desc = "\(toolName) \(filename)"
            options = [
                ApprovalRequest.OptionItem(label: "Yes"),
                ApprovalRequest.OptionItem(label: "Yes, allow all"),
                ApprovalRequest.OptionItem(label: "No"),
            ]
        } else if let cmd = toolInput["command"] as? String {
            desc = "Run: \(String(cmd.prefix(100)))"
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

        print("[RelayService] Permission requested: \(toolName) — \(desc)")

        // Determine the target session and whether it is writable.
        // Only attach the approval to a session if the server explicitly said which session it belongs to.
        // Never fall back to an unrelated session — that would show the approval in the wrong place.
        let targetSessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let targetSession = targetSessionId.flatMap { sid in
            indexForSession(id: sid, externalSessionId: sid).flatMap { idx in
                sessions.indices.contains(idx) ? sessions[idx] : nil
            }
        }
        let sessionIsWritable = targetSession?.writable ?? true
        let requiresMacTerminalResponse = {
            guard let targetSession else { return false }
            return targetSession.agent == .codex && !targetSession.writable
        }()

        // Only read-only external Codex mirrors need Mac-terminal-only dismissal.
        // Claude approvals still work remotely through the bridge hook even when the
        // mirrored desktop session itself is not writable.
        let finalOptions: [ApprovalRequest.OptionItem]
        if requiresMacTerminalResponse && !options.isEmpty {
            finalOptions = [ApprovalRequest.OptionItem(label: "Dismiss", description: "Respond in your Mac terminal")]
        } else {
            finalOptions = options
        }

        let approval = ApprovalRequest(
            permissionId: permissionId,
            sessionId: targetSessionId,
            toolName: toolName,
            actionSummary: desc,
            question: question,
            options: finalOptions,
            readOnly: requiresMacTerminalResponse
        )

        pendingApproval = approval
        pendingApprovalSessionId = targetSessionId
        claimPendingApprovalIfNeeded(preferredSessionId: targetSessionId)
        if targetSessionId != nil && targetSession == nil {
            Task { await refreshSessionsFromBridgeStatus(preferredSessionId: targetSessionId) }
        }

        // Haptic feedback
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()

        // Add to terminal
        let termMsg = sessionIsWritable ? "⚠ Permission: \(desc)" : "⚠ Codex waiting (read-only): \(desc)"
        let line = TerminalLine(text: termMsg, type: .system, sessionId: sessionId)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
        appendToSession(line, sessionId: sessionId)

        // Forward to watch
        let watchRequest = ApprovalRequest(
            permissionId: permissionId,
            sessionId: targetSessionId,
            toolName: toolName,
            actionSummary: desc,
            question: question,
            options: finalOptions,
            readOnly: !sessionIsWritable
        )
        let message = WatchMessage.approvalRequestMessage(watchRequest)
        sessionManager.send(message)

        // Notification if backgrounded
        notificationService.postApprovalNeeded(toolName: toolName, summary: desc)
    }

    // MARK: - Permission response

    /// Respond to approval with a selected option (dynamic options from server).
    func respondToApprovalWithOption(
        _ optionLabel: String,
        index: Int,
        approval explicitApproval: ApprovalRequest? = nil
    ) {
        guard let approval = explicitApproval ?? pendingApproval else { return }
        let permissionId = approval.permissionId ?? ""

        let isLast = index == approval.options.count - 1
        UIImpactFeedbackGenerator(style: isLast ? .heavy : .medium).impactOccurred()

        if approval.question != nil {
            // AskUserQuestion: send the option label
            Task {
                try? await bridgeClient.respondToApprovalWithOption(
                    requestId: permissionId, optionLabel: optionLabel, index: index
                )
            }
        } else {
            // Standard permission: first = allow, last = deny, middle = allow all
            if optionLabel.lowercased().contains("allow all") || optionLabel.lowercased().contains("don't ask") {
                Task { try? await bridgeClient.respondToApprovalAllowAll(requestId: permissionId) }
            } else {
                let approved = !isLast
                Task { try? await bridgeClient.respondToApproval(requestId: permissionId, allow: approved) }
            }
        }

        let line = TerminalLine(text: "→ \(optionLabel)", type: isLast ? .error : .output)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)

        clearPendingApproval(for: approval)
    }

    // MARK: - Send command

    /// Sends a text command to the bridge (iOS equivalent of watchOS voice input).
    func sendCommand(text: String, sessionId: String? = nil) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let requestedSession = sessionId.flatMap { session(for: $0) }
        let fallbackSession = requestedSession.flatMap { preferredWritableSession(for: $0) }
        let sid = requestedSession?.writable == true
            ? requestedSession?.id
            : fallbackSession?.id ?? sessionId ?? preferredSessionId()

        focusedSessionId = sid
        if let sid {
            setActivity(.running, for: sid)
            markSessionVisualActivity(sid)
        }

        let cmdLine = TerminalLine(text: "> \(trimmedText)", type: .command, sessionId: sid)
        terminalBuffer.append(cmdLine)
        _ = appendToSessionIfNotDuplicate(cmdLine, sessionId: sid)
        recentTerminalLines = terminalBuffer.getLast(15)

        isThinking = true

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        Task {
            do {
                if let requestedSession, !requestedSession.writable, fallbackSession == nil {
                    let spawnedSessionId = try await bridgeClient.spawnSession(
                        agent: requestedSession.agent.rawValue,
                        cwd: requestedSession.cwd,
                        initialCommand: trimmedText
                    )

                    await MainActor.run {
                        if let spawnedSessionId {
                            self.focusedSessionId = spawnedSessionId
                            let line = TerminalLine(
                                text: "Opened a writable \(requestedSession.agent.rawValue) session for voice input.",
                                type: .system,
                                sessionId: spawnedSessionId
                            )
                            self.terminalBuffer.append(line)
                            self.appendToSession(line, sessionId: spawnedSessionId)
                            self.recentTerminalLines = self.terminalBuffer.getLast(15)
                            self.updateWatchState()
                        }
                    }
                    return
                }

                try await bridgeClient.sendCommand(text: trimmedText + "\n", sessionId: sid)
            } catch BridgeClient.BridgeError.unauthorized {
                await MainActor.run { self.handleBridgeAuthRejected() }
            } catch let BridgeClient.BridgeError.serverError(message) {
                await MainActor.run {
                    let line = TerminalLine(text: message, type: .error, sessionId: sid)
                    self.terminalBuffer.append(line)
                    self.appendToSession(line, sessionId: sid)
                    self.recentTerminalLines = self.terminalBuffer.getLast(15)
                    self.isThinking = false
                }
            } catch {
                await MainActor.run {
                    let line = TerminalLine(text: error.localizedDescription, type: .error, sessionId: sid)
                    self.terminalBuffer.append(line)
                    self.appendToSession(line, sessionId: sid)
                    self.recentTerminalLines = self.terminalBuffer.getLast(15)
                    self.isThinking = false
                }
            }
        }
    }

    func queueCommand(text: String, sessionId: String) {
        focusedSessionId = sessionId

        let line = TerminalLine(text: "Queued: \(text)", type: .system, sessionId: sessionId)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
        appendToSession(line, sessionId: sessionId)

        Task {
            do {
                try await bridgeClient.queueCommand(text: text, sessionId: sessionId)
            } catch BridgeClient.BridgeError.unauthorized {
                await MainActor.run { self.handleBridgeAuthRejected() }
            } catch {
                // ignore
            }
        }
    }

    func interruptAndReplace(text: String, sessionId: String) {
        focusedSessionId = sessionId

        let line = TerminalLine(text: "Interrupting current task…", type: .system, sessionId: sessionId)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
        appendToSession(line, sessionId: sessionId)

        Task {
            do {
                try await bridgeClient.interruptSession(sessionId: sessionId, replacementCommand: text)
            } catch BridgeClient.BridgeError.unauthorized {
                await MainActor.run { self.handleBridgeAuthRejected() }
            } catch {
                // ignore
            }
        }
    }

    func spawnDesktopSession(agent: AgentType, cwd: String?, initialCommand: String? = nil) {
        let line = TerminalLine(
            text: "Opening new \(agent.rawValue) session on Mac…",
            type: .system
        )
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)

        Task {
            do {
                let sessionId = try await bridgeClient.spawnSession(
                    agent: agent.rawValue,
                    cwd: cwd,
                    openDesktopWindow: true,
                    initialCommand: initialCommand
                )
                await MainActor.run {
                    if let sessionId {
                        self.focusedSessionId = sessionId
                    }
                }
            } catch BridgeClient.BridgeError.unauthorized {
                await MainActor.run { self.handleBridgeAuthRejected() }
            } catch {
                // ignore
            }
        }
    }

    func openSessionOnMac(sessionId: String) {
        if let session = sessions.first(where: { $0.id == sessionId }) {
            let line = TerminalLine(
                text: "Opening \(session.agent.rawValue) terminal on Mac…",
                type: .system,
                sessionId: sessionId
            )
            terminalBuffer.append(line)
            appendToSession(line, sessionId: sessionId)
            recentTerminalLines = terminalBuffer.getLast(15)
        }

        Task {
            do {
                try await bridgeClient.openDesktopWindow(sessionId: sessionId)
            } catch BridgeClient.BridgeError.unauthorized {
                await MainActor.run { self.handleBridgeAuthRejected() }
            } catch let BridgeClient.BridgeError.serverError(message) {
                await MainActor.run {
                    let line = TerminalLine(text: message, type: .error, sessionId: sessionId)
                    self.terminalBuffer.append(line)
                    self.appendToSession(line, sessionId: sessionId)
                    self.recentTerminalLines = self.terminalBuffer.getLast(15)
                }
            } catch {
                await MainActor.run {
                    let line = TerminalLine(text: error.localizedDescription, type: .error, sessionId: sessionId)
                    self.terminalBuffer.append(line)
                    self.appendToSession(line, sessionId: sessionId)
                    self.recentTerminalLines = self.terminalBuffer.getLast(15)
                }
            }
        }
    }

    func removeSession(sessionId: String) {
        Task {
            do {
                try await bridgeClient.removeSession(sessionId: sessionId)
            } catch BridgeClient.BridgeError.unauthorized {
                await MainActor.run { self.handleBridgeAuthRejected() }
            } catch {
                // ignore
            }
        }
    }

    func focusSession(_ sessionId: String?) {
        focusedSessionId = sessionId
    }

    // MARK: - Clear terminal

    func clearTerminal(sessionId: String? = nil) {
        if let sid = sessionId {
            if let idx = sessions.firstIndex(where: { $0.id == sid }) {
                sessions[idx].terminalLines.removeAll()
            }
            pendingTerminalLines.removeAll { $0.sessionId == sid }
            recentTerminalLines.removeAll { $0.sessionId == sid }
            return
        }

        for idx in sessions.indices {
            sessions[idx].terminalLines.removeAll()
        }
        terminalBuffer.clear()
        pendingTerminalLines.removeAll()
        recentTerminalLines = []
        isThinking = false
    }

    // MARK: - Helpers (approval)

    private func clearPendingApproval(for approval: ApprovalRequest) {
        pendingApproval = nil
        pendingApprovalSessionId = nil
        for idx in sessions.indices {
            if sessions[idx].pendingApproval?.permissionId == approval.permissionId {
                sessions[idx].pendingApproval = nil
                if sessions[idx].activity == .waitingApproval {
                    sessions[idx].activity = .running
                }
            }
        }
        publishSessions()
    }

    private func appendToSession(_ line: TerminalLine, sessionId: String?) {
        guard let sid = sessionId,
              let idx = indexForSession(id: sid) else { return }
        sessions[idx].terminalLines.append(line)
        if sessions[idx].terminalLines.count > 600 {
            sessions[idx].terminalLines.removeFirst(sessions[idx].terminalLines.count - 600)
        }
    }

    private func appendToSessionIfNotDuplicate(_ line: TerminalLine, sessionId: String?) -> Bool {
        guard let sid = sessionId,
              let idx = indexForSession(id: sid) else { return false }

        if sessions[idx].terminalLines.suffix(6).contains(where: {
            $0.type == line.type && $0.text == line.text
        }) {
            return false
        }

        appendToSession(line, sessionId: sid)
        return true
    }

    private func setActivity(_ activity: SessionActivity, for sessionId: String) {
        guard let idx = indexForSession(id: sessionId) else { return }
        sessions[idx].activity = activity
    }

    private func markSessionVisualActivity(_ sessionId: String?) {
        guard let sessionId, let idx = indexForSession(id: sessionId) else { return }
        sessions[idx].lastVisualActivityAt = Date()
    }

    private func session(for sessionId: String) -> AgentSession? {
        guard let idx = indexForSession(id: sessionId) else { return nil }
        return sessions[idx]
    }

    private func indexForSession(
        id: String? = nil,
        externalSessionId: String? = nil,
        tmuxSessionName: String? = nil
    ) -> Int? {
        if let id, let exact = sessions.firstIndex(where: { $0.id == id }) {
            return exact
        }

        if let id, let alias = sessions.firstIndex(where: { $0.externalSessionId == id }) {
            return alias
        }

        if let externalSessionId,
           let exactExternal = sessions.firstIndex(where: { $0.externalSessionId == externalSessionId }) {
            return exactExternal
        }

        return nil
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

    private func shouldDisplayPtyOutput(_ text: String, sessionId: String?, isBootstrap: Bool = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard let sessionId, let session = session(for: sessionId), session.sharedTerminal else {
            return true
        }

        return isBootstrap
            || trimmed.hasPrefix("[queued prompt]")
            || trimmed.hasPrefix("[launching]")
            || trimmed == "^C"
    }

    private func handlePermissionCleared(_ data: String) {
        guard let json = parseJSON(data) else { return }

        let permissionId = json["permissionId"] as? String
        if let current = pendingApproval,
           (permissionId == nil || current.permissionId == permissionId) {
            clearPendingApproval(for: current)
            return
        }

        for idx in sessions.indices {
            if permissionId == nil || sessions[idx].pendingApproval?.permissionId == permissionId {
                sessions[idx].pendingApproval = nil
                if sessions[idx].activity == .waitingApproval {
                    sessions[idx].activity = .running
                }
            }
        }
        pendingApprovalSessionId = nil
        publishSessions()
    }

    private func handleSessionEvent(_ data: String) {
        guard let json = parseJSON(data),
              let state = json["state"] as? String else { return }

        let sessionId = json["sessionId"] as? String
        let agent = json["agent"] as? String
        let cwd = json["cwd"] as? String ?? ""
        let folderName = json["folderName"] as? String ?? ""
        let backend = json["backend"] as? String ?? "external"
        let writable = json["writable"] as? Bool ?? false
        let sharedTerminal = json["sharedTerminal"] as? Bool ?? (backend == "tmux")
        let externalSessionId = json["externalSessionId"] as? String
        let tmuxSessionName = json["tmuxSessionName"] as? String
        let lastActivityAt = json["lastActivityAt"] as? TimeInterval

        switch state {
        case "running":
            sessionStartDate = Date()
            if let sid = sessionId {
                if let idx = indexForSession(id: sid, externalSessionId: externalSessionId, tmuxSessionName: tmuxSessionName) {
                    let existingLines = sessions[idx].terminalLines
                    let existingApproval = sessions[idx].pendingApproval
                    let existingActivity = sessions[idx].activity
                    let previousId = sessions[idx].id
                    let agentType = AgentType(rawValue: agent ?? sessions[idx].agent.rawValue) ?? sessions[idx].agent
                    var updated = AgentSession(
                        id: sid,
                        agent: agentType,
                        cwd: cwd.isEmpty ? sessions[idx].cwd : cwd,
                        folderName: folderName.isEmpty ? sessions[idx].folderName : folderName,
                        activity: existingActivity == .waitingApproval ? .waitingApproval : .idle,
                        backend: backend,
                        writable: writable,
                        sharedTerminal: sharedTerminal,
                        externalSessionId: externalSessionId ?? sessions[idx].externalSessionId,
                        tmuxSessionName: tmuxSessionName ?? sessions[idx].tmuxSessionName,
                        lastActivityAt: lastActivityAt ?? sessions[idx].lastActivityAt
                    )
                    updated.terminalLines = existingLines
                    updated.pendingApproval = existingApproval
                    updated.lastVisualActivityAt = sessions[idx].lastVisualActivityAt
                    sessions[idx] = updated
                    if focusedSessionId == previousId {
                        focusedSessionId = sid
                    }
                } else {
                    let agentType = AgentType(rawValue: agent ?? "claude") ?? .claude
                    sessions.append(AgentSession(
                        id: sid, agent: agentType, cwd: cwd,
                        folderName: folderName, activity: .idle,
                        backend: backend,
                        writable: writable,
                        sharedTerminal: sharedTerminal,
                        externalSessionId: externalSessionId,
                        tmuxSessionName: tmuxSessionName,
                        lastActivityAt: lastActivityAt
                    ))
                    focusedSessionId = sid
                }
            }
            claimPendingApprovalIfNeeded(preferredSessionId: sessionId ?? externalSessionId)
        case "ended":
            isThinking = false
            stopElapsedTimer()
            notificationService.postTaskComplete()
            if let sid = sessionId, let idx = sessions.firstIndex(where: { $0.id == sid }) {
                sessions[idx].activity = .ended
            }
        case "connected":
            connectionState = .connected
        default:
            break
        }

        updateWatchState()
    }

    private func handleSessionRemoved(_ data: String) {
        guard let json = parseJSON(data),
              let sessionId = json["sessionId"] as? String else { return }

        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions.remove(at: idx)
        }

        pendingTerminalLines.removeAll { $0.sessionId == sessionId }
        recentTerminalLines.removeAll { $0.sessionId == sessionId }

        if focusedSessionId == sessionId {
            focusedSessionId = preferredSessionId()
            isThinking = false
        }

        if sessions.isEmpty {
            isThinking = false
        }

        if pendingApproval?.permissionId != nil,
           !sessions.contains(where: { $0.pendingApproval?.permissionId == pendingApproval?.permissionId }) {
            pendingApproval = nil
            pendingApprovalSessionId = nil
        }

        updateWatchState()
    }

    private func handleSessionHeartbeat(_ data: String) {
        guard parseJSON(data)?["sessionId"] as? String != nil else { return }
    }

    private func handlePollStatus(_ data: String) {
        guard let json = parseJSON(data) else { return }

        connectionState = .connected
        if let bridgeState = json["state"] as? String,
           bridgeState == "connected" || bridgeState == "idle" {
            lastConnected = Date()
        }

        guard let rawSessions = json["sessions"] as? [[String: Any]] else {
            return
        }
        let snapshot = rawSessions.compactMap { raw -> AgentSession? in
            guard let sessionId = raw["id"] as? String else { return nil }
            let agent = AgentType(rawValue: raw["agent"] as? String ?? "claude") ?? .claude
            let cwd = raw["cwd"] as? String ?? ""
            let folderName = raw["folderName"] as? String ?? ""
            let state = raw["state"] as? String ?? "idle"
            let backend = raw["backend"] as? String ?? "external"
            let writable = raw["writable"] as? Bool ?? false
            let sharedTerminal = raw["sharedTerminal"] as? Bool ?? (backend == "tmux")
            let externalSessionId = raw["externalSessionId"] as? String
            let tmuxSessionName = raw["tmuxSessionName"] as? String
            let lastActivityAt = raw["lastActivityAt"] as? TimeInterval

            var session = AgentSession(
                id: sessionId,
                agent: agent,
                cwd: cwd,
                folderName: folderName,
                activity: sessionActivity(for: state),
                backend: backend,
                writable: writable,
                sharedTerminal: sharedTerminal,
                externalSessionId: externalSessionId,
                tmuxSessionName: tmuxSessionName,
                lastActivityAt: lastActivityAt
            )
            session.terminalLines = parseRecentLines(raw["recentLines"], sessionId: sessionId)
            return session
        }

        mergeSessionsSnapshot(snapshot)
    }

    private func handleConversationMessage(_ data: String) {
        guard let json = parseJSON(data),
              let role = json["role"] as? String,
              let text = json["text"] as? String else { return }

        let sessionId = json["sessionId"] as? String
        let phase = json["phase"] as? String
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let line: TerminalLine
        switch role {
        case "user":
            line = TerminalLine(text: "> \(trimmed)", type: .command, sessionId: sessionId)
        case "assistant":
            line = TerminalLine(text: trimmed, type: .output, sessionId: sessionId)
        default:
            return
        }

        let appended = appendToSessionIfNotDuplicate(line, sessionId: sessionId)
        let shouldSkipSessionAppend = appended
        if !appended,
           let sid = sessionId,
           let session = session(for: sid),
           session.sharedTerminal {
            return
        }

        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
        if !shouldSkipSessionAppend {
            appendToSession(line, sessionId: sessionId)
        }

        if let sid = sessionId {
            if role == "user" {
                setActivity(.running, for: sid)
                markSessionVisualActivity(sid)
                if focusedSessionId == nil || focusedSessionId == sid {
                    isThinking = true
                }
            } else if role == "assistant" {
                setActivity(.running, for: sid)
                markSessionVisualActivity(sid)
                if focusedSessionId == nil || focusedSessionId == sid {
                    isThinking = phase != "final_answer"
                }
            }
        }

        pendingTerminalLines.append(line)
        scheduleBatchSend()
    }

    private func handleToolOutput(_ data: String) {
        guard let json = parseJSON(data) else { return }
        let toolName = json["tool_name"] as? String ?? "tool"
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        let toolOutput = json["tool_output"] as? String
        let sessionId = json["sessionId"] as? String
        let source = json["source"] as? String ?? "claude"
        let prefix = source == "codex" ? "[codex] " : ""
        let sharedSession = sessionId.flatMap { session(for: $0) }?.sharedTerminal == true

        if sharedSession {
            return
        }

        if let sid = sessionId {
            setActivity(.running, for: sid)
            markSessionVisualActivity(sid)
        }

        // Format like a real terminal: show what Claude did and the result
        var lines: [TerminalLine] = []

        switch toolName {
        case "Bash":
            let cmd = toolInput["command"] as? String ?? ""
            lines.append(TerminalLine(text: "\(prefix)$ \(cmd)", type: .command, sessionId: sessionId))
            if let output = toolOutput, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let outputLines = output.components(separatedBy: "\n")
                for line in outputLines.prefix(10) {
                    let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        lines.append(TerminalLine(text: cleaned, type: .output, sessionId: sessionId))
                    }
                }
                if outputLines.count > 10 {
                    lines.append(TerminalLine(text: "  ... (\(outputLines.count - 10) more lines)", type: .system, sessionId: sessionId))
                }
            }

        case "Read":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            lines.append(TerminalLine(text: "\(prefix)Read \(filename)", type: .system, sessionId: sessionId))

        case "Write":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            lines.append(TerminalLine(text: "\(prefix)Write \(filename)", type: .system, sessionId: sessionId))

        case "Edit":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            let oldStr = toolInput["old_string"] as? String ?? ""
            let newStr = toolInput["new_string"] as? String ?? ""
            lines.append(TerminalLine(text: "\(prefix)Edit \(filename)", type: .system, sessionId: sessionId))
            if !oldStr.isEmpty {
                let preview = oldStr.components(separatedBy: "\n").first ?? ""
                lines.append(TerminalLine(text: "  - \(String(preview.prefix(60)))", type: .error, sessionId: sessionId))
            }
            if !newStr.isEmpty {
                let preview = newStr.components(separatedBy: "\n").first ?? ""
                lines.append(TerminalLine(text: "  + \(String(preview.prefix(60)))", type: .output, sessionId: sessionId))
            }

        case "Grep":
            let pattern = toolInput["pattern"] as? String ?? ""
            lines.append(TerminalLine(text: "\(prefix)grep \"\(pattern)\"", type: .command, sessionId: sessionId))
            if let output = toolOutput, !output.isEmpty {
                let resultLines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
                lines.append(TerminalLine(text: "  \(resultLines.count) matches", type: .system, sessionId: sessionId))
            }

        case "Glob":
            let pattern = toolInput["pattern"] as? String ?? ""
            lines.append(TerminalLine(text: "\(prefix)find \"\(pattern)\"", type: .command, sessionId: sessionId))

        case "CodexMessage":
            if let output = toolOutput {
                lines.append(TerminalLine(text: "\(prefix)\(output)", type: .output, sessionId: sessionId))
            }

        default:
            lines.append(TerminalLine(text: "\(prefix)[\(toolName)]", type: .system, sessionId: sessionId))
            if let output = toolOutput {
                let preview = String(output.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty {
                    lines.append(TerminalLine(text: preview, type: .output, sessionId: sessionId))
                }
            }
        }

        for line in lines {
            terminalBuffer.append(line)
            pendingTerminalLines.append(line)
            appendToSession(line, sessionId: sessionId)
        }

        // Mark as thinking (cursor will be shown in the view)
        isThinking = true

        recentTerminalLines = terminalBuffer.getLast(10)
        scheduleBatchSend()
    }

    private func handleTaskComplete(_ data: String) {
        let sessionId = parseJSON(data)?["sessionId"] as? String
        isThinking = false
        let line = TerminalLine(text: "Task completed", type: .system, sessionId: sessionId)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
        appendToSession(line, sessionId: sessionId)
        if let sid = sessionId {
            setActivity(.idle, for: sid)
        }
        notificationService.postTaskComplete()
        updateWatchState()
    }

    private func handleError(_ data: String) {
        guard let json = parseJSON(data) else { return }
        let errorMsg = json["error"] as? String ?? "Unknown error"
        let line = TerminalLine(text: errorMsg, type: .error)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
    }

    private func handleStop(_ data: String) {
        let sessionId = parseJSON(data)?["sessionId"] as? String
        isThinking = false
        let line = TerminalLine(text: "Session stopped", type: .system, sessionId: sessionId)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
        appendToSession(line, sessionId: sessionId)
        if let sid = sessionId {
            setActivity(.idle, for: sid)
        }
        updateWatchState()
    }

    // MARK: - Watch communication

    private func setupWatchMessageHandler() {
        sessionManager.onMessageReceived = { [weak self] message in
            Task { @MainActor in
                self?.handleWatchMessage(message)
            }
        }
    }

    private func handleWatchMessage(_ message: WatchMessage) {
        switch message {
        case .voiceCommand(let cmd):
            sendCommand(text: cmd.transcribedText, sessionId: cmd.sessionId)

        case .approvalResponse(let response):
            guard let approval = approvalForWatchResponse(
                permissionId: response.permissionId,
                sessionId: response.sessionId
            ) else { break }

            respondToApprovalWithOption(
                response.optionLabel,
                index: response.optionIndex,
                approval: approval
            )

        default:
            break
        }
    }

    private func updateWatchState() {
        let state = SessionState(
            connection: connectionState,
            activity: currentActivity,
            machineName: machineName,
            modelName: modelName,
            workingDirectory: workingDirectory,
            elapsedSeconds: elapsedSeconds,
            filesChanged: 0,
            linesAdded: 0,
            transportMode: bridgeClient.usesRemoteTunnel ? .remote : .lan
        )

        sessionManager.updateApplicationContext(with: state)
        sendWatchSessionsSnapshot()
    }

    private func approvalForWatchResponse(permissionId: String, sessionId: String?) -> ApprovalRequest? {
        if pendingApproval?.permissionId == permissionId {
            return pendingApproval
        }

        if let sessionId,
           let session = sessions.first(where: { $0.id == sessionId || $0.externalSessionId == sessionId }),
           session.pendingApproval?.permissionId == permissionId {
            return session.pendingApproval
        }

        return sessions.first(where: { $0.pendingApproval?.permissionId == permissionId })?.pendingApproval
    }

    private func syncWatchBridgeCredentials() {
        guard let baseURL = bridgeClient.baseURL, let token = bridgeClient.token else { return }
        sessionManager.syncBridgeCredentials(
            baseURL: baseURL,
            token: token,
            machineName: machineName
        )
    }

    private var currentActivity: SessionActivity {
        switch connectionState {
        case .connected: return .running
        case .connecting: return .idle
        case .disconnected: return .ended
        case .iPhoneUnreachable: return .idle
        }
    }

    var currentTransportMode: SessionState.TransportMode {
        bridgeClient.usesRemoteTunnel ? .remote : .lan
    }

    // MARK: - Terminal batching

    private func scheduleBatchSend() {
        guard terminalBatchTimer == nil else { return }

        terminalBatchTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.flushTerminalBatch()
            }
        }
    }

    private func flushTerminalBatch() {
        terminalBatchTimer = nil

        guard !pendingTerminalLines.isEmpty else { return }

        let lines = pendingTerminalLines
        pendingTerminalLines = []

        let update = WatchMessage.TerminalUpdate(lines: lines)
        let message = WatchMessage.terminalUpdate(update)
        sessionManager.send(message)
    }

    // MARK: - Elapsed time

    private func startElapsedTimer() {
        sessionStartDate = sessionStartDate ?? Date()
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.sessionStartDate else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func claimPendingApprovalIfNeeded(preferredSessionId: String? = nil) {
        guard let approval = pendingApproval else { return }

        let requestedSessionId = preferredSessionId ?? pendingApprovalSessionId
        var targetIndex: Int? = nil

        if let requestedSessionId {
            targetIndex = indexForSession(id: requestedSessionId, externalSessionId: requestedSessionId)
        }

        if targetIndex == nil,
           let permissionId = approval.permissionId {
            targetIndex = sessions.firstIndex(where: { $0.pendingApproval?.permissionId == permissionId })
        }

        guard let idx = targetIndex else { return }

        let resolvedSessionId = sessions[idx].id
        var didChange = false

        if sessions[idx].pendingApproval?.permissionId != approval.permissionId {
            sessions[idx].pendingApproval = approval
            didChange = true
        }

        if sessions[idx].activity != .waitingApproval {
            sessions[idx].activity = .waitingApproval
            didChange = true
        }

        if focusedSessionId != resolvedSessionId {
            focusedSessionId = resolvedSessionId
        }

        pendingApprovalSessionId = resolvedSessionId
        isThinking = false

        if didChange {
            publishSessions()
        }
    }

    private func publishSessions() {
        sessions = sessions
        sendWatchSessionsSnapshot()
    }

    private func sessionActivity(for state: String) -> SessionActivity {
        switch state {
        case "running": return .running
        case "ended": return .ended
        default: return .idle
        }
    }

    private func mergeSessionsSnapshot(_ snapshot: [AgentSession], requestedSessionId: String? = nil) {
        let previousFocused = focusedSessionId
        var syncedSessions: [AgentSession] = []

        for incoming in snapshot {
            let existingIndex = indexForSession(
                id: incoming.id,
                externalSessionId: incoming.externalSessionId,
                tmuxSessionName: incoming.tmuxSessionName
            )
            let existing = existingIndex.flatMap { sessions.indices.contains($0) ? sessions[$0] : nil }

            let activity: SessionActivity = {
                if existing?.pendingApproval != nil || existing?.activity == .waitingApproval {
                    return .waitingApproval
                }
                return incoming.activity
            }()

            var merged = AgentSession(
                id: incoming.id,
                agent: incoming.agent,
                cwd: incoming.cwd,
                folderName: incoming.folderName,
                activity: activity,
                backend: incoming.backend,
                writable: incoming.writable,
                sharedTerminal: incoming.sharedTerminal,
                externalSessionId: incoming.externalSessionId,
                tmuxSessionName: incoming.tmuxSessionName,
                lastActivityAt: incoming.lastActivityAt
            )
            merged.terminalLines = mergeTerminalLines(
                existing: existing?.terminalLines ?? [],
                incoming: incoming.terminalLines
            )
            merged.pendingApproval = existing?.pendingApproval
            merged.lastVisualActivityAt = existing?.lastVisualActivityAt
            syncedSessions.append(merged)
        }

        sessions = syncedSessions
        claimPendingApprovalIfNeeded(preferredSessionId: requestedSessionId)

        if let previousFocused,
           sessions.contains(where: { $0.id == previousFocused }) {
            focusedSessionId = previousFocused
        } else if focusedSessionId == nil || !sessions.contains(where: { $0.id == focusedSessionId }) {
            focusedSessionId = preferredSessionId()
        }

        if pendingApproval?.permissionId != nil,
           !sessions.contains(where: { $0.pendingApproval?.permissionId == pendingApproval?.permissionId }) {
            pendingApproval = nil
            pendingApprovalSessionId = nil
        }

        if sessions.isEmpty {
            isThinking = false
        }

        rebuildTerminalCacheFromSessions()
        updateWatchState()
    }

    private func refreshSessionsFromBridgeStatus(preferredSessionId requestedSessionId: String? = nil) async {
        do {
            let status = try await bridgeClient.fetchStatus()
            let snapshot = (status.sessions ?? []).map { session in
                var snapshotSession = AgentSession(
                    id: session.id,
                    agent: AgentType(rawValue: session.agent) ?? .claude,
                    cwd: session.cwd,
                    folderName: session.folderName,
                    activity: sessionActivity(for: session.state),
                    backend: session.backend ?? "external",
                    writable: session.writable ?? false,
                    sharedTerminal: session.sharedTerminal ?? ((session.backend ?? "external") == "tmux"),
                    externalSessionId: session.externalSessionId,
                    tmuxSessionName: session.tmuxSessionName,
                    lastActivityAt: session.lastActivityAt
                )
                snapshotSession.terminalLines = parseRecentLines(session.recentLines, sessionId: session.id)
                return snapshotSession
            }

            mergeSessionsSnapshot(snapshot, requestedSessionId: requestedSessionId)
        } catch {
            // Best-effort sync only; SSE remains the primary source of truth.
        }
    }

    private func pushWatchSnapshot() {
        updateWatchState()
    }

    private func sendWatchSessionsSnapshot() {
        let message = WatchMessage.sessionsUpdate(.init(sessions: sessions))
        sessionManager.send(message)
    }

    private func preferredSessionId() -> String? {
        if let approvalSessionId = pendingApprovalSessionId,
           let idx = indexForSession(id: approvalSessionId, externalSessionId: approvalSessionId) {
            return sessions.indices.contains(idx) ? sessions[idx].id : nil
        }

        if let managed = mostRecentSession(where: {
            $0.writable && ($0.tmuxSessionName?.hasPrefix("agent-watch-") == true)
        }) {
            return managed.id
        }

        if let shared = mostRecentSession(where: { $0.sharedTerminal }) {
            return shared.id
        }

        if let writable = mostRecentSession(where: { $0.writable }) {
            return writable.id
        }

        return mostRecentSession(where: { _ in true })?.id
    }

    private func preferredWritableSession(for requestedSession: AgentSession) -> AgentSession? {
        if requestedSession.writable {
            return requestedSession
        }

        if let exact = mostRecentSession(where: {
            $0.id == requestedSession.id && $0.writable
        }) {
            return exact
        }

        if let externalSessionId = requestedSession.externalSessionId,
           let mirrored = mostRecentSession(where: {
               $0.writable && ($0.id == externalSessionId || $0.externalSessionId == externalSessionId)
           }) {
            return mirrored
        }

        if let sameProject = mostRecentSession(where: {
            $0.writable
                && $0.agent == requestedSession.agent
                && $0.cwd == requestedSession.cwd
        }) {
            return sameProject
        }

        if let sameAgent = mostRecentSession(where: {
            $0.writable && $0.agent == requestedSession.agent
        }) {
            return sameAgent
        }

        return mostRecentSession(where: { $0.writable })
    }

    private func parseRecentLines(_ rawValue: Any?, sessionId: String) -> [TerminalLine] {
        guard let rawLines = rawValue as? [[String: Any]] else { return [] }
        return rawLines.compactMap { line in
            guard let text = line["text"] as? String,
                  let typeRaw = line["type"] as? String,
                  let type = TerminalLine.LineType(rawValue: typeRaw) else { return nil }
            let timestamp = (line["timestamp"] as? TimeInterval).map(Date.init(timeIntervalSince1970:)) ?? Date()
            return TerminalLine(text: text, timestamp: timestamp, type: type, sessionId: sessionId)
        }
    }

    private func parseRecentLines(_ lines: [BridgeClient.BridgeRecentLineInfo]?, sessionId: String) -> [TerminalLine] {
        guard let lines else { return [] }
        return lines.compactMap { line in
            guard let type = TerminalLine.LineType(rawValue: line.type) else { return nil }
            let timestamp = line.timestamp.map(Date.init(timeIntervalSince1970:)) ?? Date()
            return TerminalLine(text: line.text, timestamp: timestamp, type: type, sessionId: sessionId)
        }
    }

    private func mergeTerminalLines(existing: [TerminalLine], incoming: [TerminalLine]) -> [TerminalLine] {
        guard !incoming.isEmpty else { return existing }

        var merged: [TerminalLine] = []
        var seen = Set<String>()

        for line in (existing + incoming).sorted(by: { $0.timestamp < $1.timestamp }) {
            let key = "\(line.type.rawValue)|\(line.text)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(line)
        }

        if merged.count > 600 {
            merged.removeFirst(merged.count - 600)
        }
        return merged
    }

    private func rebuildTerminalCacheFromSessions() {
        terminalBuffer.clear()
        let flattened = sessions
            .flatMap(\.terminalLines)
            .sorted { $0.timestamp < $1.timestamp }

        for line in flattened.suffix(50) {
            terminalBuffer.append(line)
        }
        recentTerminalLines = terminalBuffer.getLast(15)
    }

    private func mostRecentSession(where predicate: (AgentSession) -> Bool) -> AgentSession? {
        sessions
            .filter(predicate)
            .max { lhs, rhs in
                (lhs.lastActivityAt ?? 0) < (rhs.lastActivityAt ?? 0)
            }
    }

    // MARK: - JSON helpers

    private func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func handleBridgeAuthRejected() {
        pairingNotice = "Saved pairing expired because the bridge restarted. Re-pair with the new 6-digit code from your Mac."
        connectionState = .disconnected
        unpair()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
