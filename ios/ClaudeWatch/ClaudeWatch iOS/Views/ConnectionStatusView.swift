import SwiftUI
import UIKit
import AVFoundation
import Speech

struct ConnectionStatusView: View {

    @EnvironmentObject private var relayService: RelayService
    @EnvironmentObject private var sessionManager: WatchSessionManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSettings = false
    @State private var activeSessionIndex = 0
    @State private var showNewSessionDialog = false

    private var waitingApprovalCount: Int {
        let perSessionCount = relayService.sessions.filter {
            $0.activity == .waitingApproval || $0.pendingApproval != nil
        }.count
        let hasUnclaimedGlobalApproval = relayService.pendingApproval != nil
            && !relayService.sessions.contains { session in
                session.pendingApproval?.permissionId == relayService.pendingApproval?.permissionId
            }
        return perSessionCount + (hasUnclaimedGlobalApproval ? 1 : 0)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 8)

                    if relayService.sessions.isEmpty {
                        waitingView
                    } else {
                        sessionStrip
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)

                        sessionPager
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewSessionDialog = true
                    } label: {
                        Image(systemName: "plus.square.on.square")
                            .foregroundStyle(Color.claudeOrange)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Color.subtleText)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(relayService)
            }
            .confirmationDialog("Open New Session", isPresented: $showNewSessionDialog, titleVisibility: .visible) {
                Button("New Codex Window") {
                    let cwd = relayService.sessions.indices.contains(activeSessionIndex)
                        ? relayService.sessions[activeSessionIndex].cwd
                        : nil
                    relayService.spawnDesktopSession(agent: .codex, cwd: cwd)
                }
                Button("New Claude Window") {
                    let cwd = relayService.sessions.indices.contains(activeSessionIndex)
                        ? relayService.sessions[activeSessionIndex].cwd
                        : nil
                    relayService.spawnDesktopSession(agent: .claude, cwd: cwd)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The Mac will open a new desktop terminal window, and the new session will appear here immediately.")
            }
            .onChange(of: relayService.focusedSessionId) { _, newValue in
                guard let sessionId = newValue,
                      let idx = relayService.sessions.firstIndex(where: { $0.id == sessionId }) else { return }
                activeSessionIndex = idx
            }
            .onAppear {
                relayService.updateScenePhase(scenePhase)
            }
            .onChange(of: scenePhase) { _, newValue in
                relayService.updateScenePhase(newValue)
            }
            .onChange(of: relayService.sessions.count) { _, _ in
                if activeSessionIndex >= relayService.sessions.count {
                    activeSessionIndex = max(relayService.sessions.count - 1, 0)
                }
            }
            .onChange(of: activeSessionIndex) { _, newValue in
                guard relayService.sessions.indices.contains(newValue) else { return }
                relayService.focusSession(relayService.sessions[newValue].id)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            AppLogo(size: 28)

            Text("Agent Watcher")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)

            if waitingApprovalCount > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(waitingApprovalCount == 1 ? "1 Approval" : "\(waitingApprovalCount) Approvals")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(Color.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.claudeAmber)
                .clipShape(Capsule())
            }

            Spacer()

            connectionBadge
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(connectionBadgeColor)
                .frame(width: 6, height: 6)
            Text(connectionBadgeTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(connectionBadgeColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.connectedPillBackground)
        .clipShape(Capsule())
    }

    // MARK: - Waiting for sessions

    private var waitingView: some View {
        VStack(spacing: 12) {
            Spacer()
            AppLogo(size: 56)
                .opacity(0.6)
            Text(waitingTitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.subtleText)
            Text(waitingSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(Color.subtleText.opacity(0.6))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Session pager

    private var sessionPager: some View {
        TabView(selection: $activeSessionIndex) {
            ForEach(Array(relayService.sessions.enumerated()), id: \.element.id) { index, _ in
                SessionPageView(sessionIndex: index)
                    .environmentObject(relayService)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var sessionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(relayService.sessions.enumerated()), id: \.element.id) { index, session in
                    let isActive = activeSessionIndex == index
                    let needsApproval = session.activity == .waitingApproval || session.pendingApproval != nil
                    Button {
                        activeSessionIndex = index
                        relayService.focusSession(session.id)
                    } label: {
                        HStack(spacing: 6) {
                            AgentIcon(agent: session.agent, size: 14)
                            Text(session.displayName)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text(session.sharedTerminal ? "Shared" : "RO")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(session.sharedTerminal ? Color.statusGreen.opacity(0.18) : Color.subtleText.opacity(0.18))
                                .clipShape(Capsule())
                            if needsApproval {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 11, weight: .bold))
                            }
                        }
                        .foregroundStyle(isActive ? .black : needsApproval ? Color.claudeAmber : .white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            isActive
                                ? (needsApproval ? Color.claudeAmber : Color.claudeOrange)
                                : (needsApproval ? Color.claudeAmber.opacity(0.16) : Color.cardBackground)
                        )
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(needsApproval && !isActive ? Color.claudeAmber.opacity(0.45) : .clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var connectionBadgeTitle: String {
        switch relayService.connectionState {
        case .connected:
            switch relayService.currentTransportMode {
            case .lan:
                return "LAN"
            case .direct:
                return "DIRECT"
            case .remote:
                return "REMOTE"
            }
        case .connecting: return "SYNC"
        case .disconnected: return "OFF"
        case .iPhoneUnreachable: return "PHONE"
        }
    }

    private var connectionBadgeColor: Color {
        switch relayService.connectionState {
        case .connected: return Color.statusGreen
        case .connecting: return Color.claudeOrange
        case .disconnected: return .red
        case .iPhoneUnreachable: return Color.claudeAmber
        }
    }

    private var waitingTitle: String {
        switch relayService.connectionState {
        case .connected: return "Waiting for session..."
        case .connecting: return "Connecting to bridge..."
        case .disconnected: return "Bridge disconnected"
        case .iPhoneUnreachable: return "iPhone unreachable"
        }
    }

    private var waitingSubtitle: String {
        switch relayService.connectionState {
        case .connected:
            return "Connected to \(relayService.machineName ?? "Mac")"
        case .connecting:
            return "Trying to restore the event stream"
        case .disconnected:
            return "Bridge token may have expired. Open pairing again and enter the new 6-digit code."
        case .iPhoneUnreachable:
            return "Companion connection is unavailable"
        }
    }

}

// MARK: - Session Page View

private struct SessionPageView: View {
    let sessionIndex: Int
    @EnvironmentObject private var relayService: RelayService

    @State private var promptText = ""
    @StateObject private var voiceInput = IOSVoiceInputController()
    @State private var showBusyActions = false
    @State private var pendingBusyPrompt = ""
    @FocusState private var isPromptFocused: Bool

    private var session: AgentSession {
        guard relayService.sessions.indices.contains(sessionIndex) else {
            return AgentSession(id: "", agent: .claude, cwd: "", folderName: "", activity: .idle)
        }
        return relayService.sessions[sessionIndex]
    }

    private var visibleApproval: ApprovalRequest? {
        if let approval = session.pendingApproval {
            return approval
        }

        guard let globalApproval = relayService.pendingApproval else {
            return nil
        }

        let claimedBySession = relayService.sessions.contains {
            $0.pendingApproval?.permissionId == globalApproval.permissionId
        }
        if claimedBySession {
            return nil
        }

        if let targetSessionId = relayService.pendingApprovalSessionId {
            let matchesTarget = session.id == targetSessionId || session.externalSessionId == targetSessionId
            return matchesTarget ? globalApproval : nil
        }

        if let focusedSessionId = relayService.focusedSessionId {
            return focusedSessionId == session.id ? globalApproval : nil
        }

        return relayService.sessions.count == 1 ? globalApproval : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Session header
            sessionHeader
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            // Approval prompt (if pending for this session)
            if let approval = visibleApproval {
                approvalPrompt(approval)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            if !session.writable {
                readOnlyHint
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            // Terminal
            terminalView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 16)

            composer
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 10)
        }
        .onChange(of: voiceInput.transcript) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                promptText = newValue
            }
        }
        .onDisappear {
            voiceInput.stopRecording()
        }
        .confirmationDialog("This Session Is Busy", isPresented: $showBusyActions, titleVisibility: .visible) {
            Button("Interrupt and Replace") {
                relayService.interruptAndReplace(text: pendingBusyPrompt, sessionId: session.id)
                clearComposer()
            }
            Button("Queue Next Prompt") {
                relayService.queueCommand(text: pendingBusyPrompt, sessionId: session.id)
                clearComposer()
            }
            Button("Open in New Session") {
                relayService.spawnDesktopSession(
                    agent: session.agent,
                    cwd: session.cwd,
                    initialCommand: pendingBusyPrompt
                )
                clearComposer()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current agent is still working. Choose whether to interrupt it, wait for the next turn, or open a separate terminal.")
        }
    }

    // MARK: - Session header

    private var sessionHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentIcon(agent: session.agent, size: 18)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(session.displayName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if session.activity == .waitingApproval || visibleApproval != nil {
                        Text("Awaiting approval")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.claudeAmber)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 6) {
                    Text(session.accessLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(session.sharedTerminal ? Color.statusGreen : session.writable ? Color.claudeOrange : Color.claudeAmber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((session.sharedTerminal ? Color.statusGreen : session.writable ? Color.claudeOrange : Color.claudeAmber).opacity(0.14))
                        .clipShape(Capsule())

                    Text(session.backendLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.subtleText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.18))
                        .clipShape(Capsule())

                    Text(session.shortDisplayId)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.subtleText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text(session.cwd)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.subtleText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            Menu {
                Button {
                    relayService.openSessionOnMac(sessionId: session.id)
                } label: {
                    Label("Open on Mac", systemImage: "macwindow")
                }
                .disabled(!session.sharedTerminal)

                Button {
                    relayService.clearTerminal(sessionId: session.id)
                } label: {
                    Label("Clear Output", systemImage: "trash")
                }

                Button(role: .destructive) {
                    relayService.removeSession(sessionId: session.id)
                } label: {
                    Label("Close Session", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.subtleText)
            }
        }
        .padding(12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var readOnlyHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "eye")
                .foregroundStyle(Color.claudeAmber)
                .font(.system(size: 13, weight: .bold))
                .padding(.top, 1)

            Text("This is a detected desktop mirror. It shows context, but iPhone and watch cannot type into it. Use + to create a new shared session.")
                .font(.system(size: 12))
                .foregroundStyle(Color.subtleText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.claudeAmber.opacity(0.25), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch session.activity {
        case .running: return Color.statusGreen
        case .waitingApproval: return Color.claudeAmber
        case .ended: return .red
        case .idle: return Color.subtleText
        }
    }

    // MARK: - Approval prompt

    private func approvalPrompt(_ approval: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: approval.readOnly ? "eye.slash" : "lock.shield.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(approval.readOnly ? Color.orange : Color.claudeAmber)
                Text(approval.readOnly ? "Respond in Mac terminal" : "Approval needed")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(relativeApprovalTime(approval.timestamp))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.subtleText)
            }

            if approval.readOnly {
                Text("This session is read-only (external terminal). Codex is waiting for your response in the terminal on your Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let question = approval.question {
                Text(question)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !approval.actionSummary.isEmpty && approval.actionSummary != approval.toolName {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.claudeAmber)
                        .font(.system(size: 14))
                    Text(approval.actionSummary)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
            }

            Divider().background(Color.subtleText.opacity(0.3))

            ForEach(Array(approval.options.enumerated()), id: \.element.id) { index, option in
                Button {
                    relayService.respondToApprovalWithOption(option.label, index: index, approval: approval)
                    promptText = ""
                } label: {
                    HStack(spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.subtleText)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)

                            if let desc = option.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.subtleText)
                                    .lineLimit(2)
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(colorForOption(index, total: approval.options.count).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(colorForOption(index, total: approval.options.count).opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            // Text input for custom response
            if approval.question != nil {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.3))

                        TextField("Type a response...", text: $promptText)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(.white)
                            .tint(Color.claudeOrange)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .focused($isPromptFocused)
                            .submitLabel(.send)
                            .onSubmit { submitPromptText() }
                    }
                    .frame(minHeight: 42)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture {
                        isPromptFocused = true
                    }

                    Button { submitPromptText() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.subtleText
                                : Color.claudeOrange)
                    }
                    .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
        .background(Color(hex: "1a1a1a"))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.claudeAmber.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Terminal

    private var terminalView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(session.terminalLines) { line in
                        TerminalLineRow(line: line)
                            .id(line.id)
                    }

                    if isThinking {
                        HStack(spacing: 7) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.65)
                                .tint(Color.claudeOrange)
                            Text("Responding…")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.claudeOrange.opacity(0.75))
                        }
                        .padding(.top, 2)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("terminal-bottom")
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                TapGesture().onEnded {
                    dismissKeyboard()
                }
            )
            .onChange(of: session.terminalLines.count) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo("terminal-bottom", anchor: .bottom)
                }
            }
            .onChange(of: isThinking) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo("terminal-bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .textSelection(.enabled)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage = voiceInput.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if voiceInput.isRecording {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                    Text("Listening… tap mic to stop")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.subtleText)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(session.writable ? "Message Agent Watcher" : "Read-only session", text: $promptText, axis: .vertical)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .tint(Color.claudeOrange)
                    .lineLimit(1...3)
                    .padding(.leading, 2)
                    .padding(.vertical, 7)
                    .focused($isPromptFocused)
                    .disabled(!session.writable || session.activity == .ended || session.activity == .waitingApproval)
                    .submitLabel(.send)
                    .onSubmit { sendPrompt() }

                if isPromptFocused {
                    composerButton(
                        icon: "keyboard.chevron.compact.down",
                        foreground: Color.subtleText,
                        background: Color.black.opacity(0.22),
                        border: Color.fieldBorder.opacity(0.65)
                    ) {
                        dismissKeyboard()
                    }
                }

                composerButton(
                    icon: voiceInput.isRecording ? "stop.fill" : "mic.fill",
                    foreground: voiceInput.isRecording ? .white : Color.subtleText,
                    background: voiceInput.isRecording ? Color.red.opacity(0.9) : Color.white.opacity(0.06),
                    border: voiceInput.isRecording ? Color.red.opacity(0.25) : Color.fieldBorder.opacity(0.55)
                ) {
                    toggleRecording()
                }
                .disabled(!session.writable || session.activity == .ended || session.activity == .waitingApproval)

                composerButton(
                    icon: "arrow.up",
                    foreground: canSend ? .black : Color.subtleText,
                    background: canSend ? Color.claudeOrange : Color.black.opacity(0.26),
                    border: canSend ? Color.claudeOrange.opacity(0.15) : Color.fieldBorder.opacity(0.55)
                ) {
                    sendPrompt()
                }
                .disabled(!canSend || !session.writable || session.activity == .ended || session.activity == .waitingApproval)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(hex: "111111"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isPromptFocused ? Color.claudeOrange.opacity(0.55) : Color.fieldBorder.opacity(0.85), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 10, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture {
                guard session.writable, session.activity != .ended, session.activity != .waitingApproval else { return }
                isPromptFocused = true
            }
        }
    }

    private func composerButton(
        icon: String,
        foreground: Color,
        background: Color,
        border: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(background)
                )
                .overlay(
                    Circle()
                        .stroke(border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func submitPromptText() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let approval = visibleApproval else { return }
        relayService.respondToApprovalWithOption(text, index: -1, approval: approval)
        promptText = ""
        isPromptFocused = false
    }

    private var canSend: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSessionBusy: Bool {
        !session.sharedTerminal && session.activity == .running
    }

    private var isThinking: Bool {
        if !session.sharedTerminal {
            return session.activity == .running
        }

        guard session.activity == .running else { return false }
        guard let lastVisualActivityAt = session.lastVisualActivityAt else { return false }
        return Date().timeIntervalSince(lastVisualActivityAt) < 12
    }

    private func sendPrompt() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard session.writable else { return }
        if isSessionBusy {
            pendingBusyPrompt = text
            isPromptFocused = false
            showBusyActions = true
            return
        }
        relayService.sendCommand(text: text, sessionId: session.id)
        clearComposer()
    }

    private func toggleRecording() {
        if voiceInput.isRecording {
            voiceInput.stopRecording()
        } else {
            voiceInput.startRecording()
        }
    }

    private func clearComposer() {
        promptText = ""
        pendingBusyPrompt = ""
        voiceInput.clearTranscript()
        isPromptFocused = false
    }

    private func dismissKeyboard() {
        isPromptFocused = false
    }

    private func colorForOption(_ index: Int, total: Int) -> Color {
        if total <= 1 { return Color.statusGreen }
        if index == 0 { return Color.statusGreen }
        if index == total - 1 { return .red }
        return Color.claudeOrange
    }

    private func relativeApprovalTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 10 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        return "\(minutes)m"
    }
}

// MARK: - Terminal Line Row (collapsible)

private struct TerminalLineRow: View {
    let line: TerminalLine

    private var icon: String? {
        switch line.type {
        case .command: return line.text.hasPrefix("$") ? nil : nil
        case .system:
            if line.text.hasPrefix("Read ")  { return "doc.text" }
            if line.text.hasPrefix("Edit ")  { return "pencil" }
            if line.text.hasPrefix("Write ") { return "doc.badge.plus" }
            return "gearshape"
        default: return nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if let icon, line.type == .system {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.subtleText)
                    .frame(width: 14, alignment: .center)
                    .padding(.top, 2)
            }

            Text(line.text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(colorForType)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var colorForType: Color {
        switch line.type {
        case .output:
            if line.text.hasPrefix("  + ") { return Color.statusGreen }
            return Color.claudeOrange
        case .command:  return .white
        case .system:   return Color.subtleText
        case .thinking: return Color.claudeOrange.opacity(0.5)
        case .error:    return .red
        }
    }
}

private final class IOSVoiceInputController: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?

    func startRecording() {
        Task { @MainActor in
            do {
                try await requestPermissions()
                try beginRecognition()
            } catch {
                errorMessage = error.localizedDescription
                stopRecording()
            }
        }
    }

    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func clearTranscript() {
        transcript = ""
        errorMessage = nil
    }

    private func beginRecognition() throws {
        stopRecording()
        speechRecognizer = preferredSpeechRecognizer()

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw VoiceError.speechUnavailable
        }

        transcript = ""
        errorMessage = nil

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let text = result?.bestTranscription.formattedString {
                    self.transcript = text
                }

                if let error {
                    self.errorMessage = error.localizedDescription
                    self.stopRecording()
                    return
                }

                if result?.isFinal == true {
                    self.stopRecording()
                }
            }
        }
    }

    private func requestPermissions() async throws {
        let speechAuth = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard speechAuth == .authorized else {
            throw VoiceError.speechDenied
        }

        let micGranted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }

        guard micGranted else {
            throw VoiceError.microphoneDenied
        }
    }

    private func preferredSpeechRecognizer() -> SFSpeechRecognizer? {
        for identifier in preferredLocaleIdentifiers() {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)) {
                return recognizer
            }
        }
        return SFSpeechRecognizer()
    }

    private func preferredLocaleIdentifiers() -> [String] {
        var identifiers: [String] = []

        let preferredLanguages = Locale.preferredLanguages
        let chinesePreferred = preferredLanguages.filter { $0.lowercased().hasPrefix("zh") }
        if !chinesePreferred.isEmpty {
            identifiers.append(contentsOf: chinesePreferred)
        }

        identifiers.append(contentsOf: ["zh-CN", "zh-Hans-CN", Locale.current.identifier])
        identifiers.append(contentsOf: preferredLanguages)
        identifiers.append("en-US")

        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }

    private enum VoiceError: LocalizedError {
        case speechDenied
        case microphoneDenied
        case speechUnavailable

        var errorDescription: String? {
            switch self {
            case .speechDenied:
                return "Speech recognition permission is required."
            case .microphoneDenied:
                return "Microphone permission is required."
            case .speechUnavailable:
                return "Speech recognition is currently unavailable."
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ConnectionStatusView()
        .environmentObject(WatchSessionManager.shared)
        .environmentObject(RelayService.shared)
}
