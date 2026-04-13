import SwiftUI
import AVFoundation
import Speech

/// iPad session detail: header, approval banner, terminal stream, composer.
/// All writes go through `RelayService.sendCommand` / `respondToApprovalWithOption`,
/// identical to iPhone — so approval routing and session ownership are
/// guaranteed to match the iPhone build byte-for-byte.
struct PadSessionDetailView: View {

    let session: AgentSession

    @EnvironmentObject private var relayService: RelayService

    @State private var promptText = ""
    @StateObject private var voiceInput = PadVoiceInputController()
    @State private var showBusyActions = false
    @State private var pendingBusyPrompt = ""
    @FocusState private var isPromptFocused: Bool

    // Always read the freshest session from the service, keyed by our seeded id.
    private var liveSession: AgentSession {
        relayService.sessions.first(where: { $0.id == session.id }) ?? session
    }

    private var visibleApproval: ApprovalRequest? {
        let s = liveSession
        if let approval = s.pendingApproval { return approval }

        guard let globalApproval = relayService.pendingApproval else { return nil }

        let claimedBySession = relayService.sessions.contains {
            $0.pendingApproval?.permissionId == globalApproval.permissionId
        }
        if claimedBySession { return nil }

        if let targetSessionId = relayService.pendingApprovalSessionId {
            let matches = s.id == targetSessionId || s.externalSessionId == targetSessionId
            return matches ? globalApproval : nil
        }

        if let focusedSessionId = relayService.focusedSessionId {
            return focusedSessionId == s.id ? globalApproval : nil
        }

        return relayService.sessions.count == 1 ? globalApproval : nil
    }

    var body: some View {
        let s = liveSession

        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header(for: s)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                if let approval = visibleApproval {
                    approvalBanner(approval)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                if !s.writable {
                    readOnlyHint
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                terminalView(for: s)
                    .padding(.horizontal, 20)
                    .frame(maxHeight: .infinity)

                composer(for: s)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
            }
        }
        .onChange(of: voiceInput.transcript) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { promptText = newValue }
        }
        .onDisappear { voiceInput.stopRecording() }
        .confirmationDialog("This Session Is Busy", isPresented: $showBusyActions, titleVisibility: .visible) {
            Button("Interrupt and Replace") {
                relayService.interruptAndReplace(text: pendingBusyPrompt, sessionId: s.id)
                clearComposer()
            }
            Button("Queue Next Prompt") {
                relayService.queueCommand(text: pendingBusyPrompt, sessionId: s.id)
                clearComposer()
            }
            Button("Open in New Session") {
                relayService.spawnDesktopSession(agent: s.agent, cwd: s.cwd, initialCommand: pendingBusyPrompt)
                clearComposer()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current agent is still working. Choose whether to interrupt it, wait for the next turn, or open a separate terminal.")
        }
    }

    // MARK: - Header

    private func header(for s: AgentSession) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AgentIcon(agent: s.agent, size: 22)
                .padding(8)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(s.displayName)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if s.activity == .waitingApproval || visibleApproval != nil {
                        Text("Awaiting approval")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.claudeAmber)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Text(s.accessLabel)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((s.sharedTerminal ? Color.statusGreen : s.writable ? Color.claudeOrange : Color.claudeAmber).opacity(0.18))
                        .foregroundStyle(s.sharedTerminal ? Color.statusGreen : s.writable ? Color.claudeOrange : Color.claudeAmber)
                        .clipShape(Capsule())

                    if !s.cwd.isEmpty {
                        Text(s.cwd)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.subtleText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer()
        }
    }

    // MARK: - Read-only hint

    private var readOnlyHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .foregroundStyle(Color.claudeAmber)
            Text("Read-only session — respond in the Mac terminal.")
                .font(.system(size: 12))
                .foregroundStyle(Color.claudeAmber)
            Spacer()
        }
        .padding(10)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.claudeAmber.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Approval banner

    private func approvalBanner(_ approval: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: approval.readOnly ? "eye.slash" : "lock.shield.fill")
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
                            .onSubmit { submitApprovalText(approval) }
                    }
                    .frame(minHeight: 42)

                    Button { submitApprovalText(approval) } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(canSend ? Color.claudeOrange : Color.subtleText)
                    }
                    .disabled(!canSend)
                }
            }
        }
        .padding(14)
        .background(Color(hex: "1a1a1a"))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.claudeAmber.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Terminal

    private func terminalView(for s: AgentSession) -> some View {
        let blocks = Self.groupTranscript(s.terminalLines)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(blocks) { block in
                        blockView(block, agent: s.agent)
                            .id(block.id)
                    }

                    if isThinking(for: s) {
                        thinkingIndicator(agent: s.agent)
                    }

                    Color.clear.frame(height: 1).id("pad-terminal-bottom")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: s.terminalLines.count) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo("pad-terminal-bottom", anchor: .bottom)
                }
            }
            .onChange(of: isThinking(for: s)) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo("pad-terminal-bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .textSelection(.enabled)
        .background(Color.cardBackground.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Transcript blocks

    fileprivate struct TranscriptBlock: Identifiable {
        enum Kind { case user, agent, tool, error }
        let id: UUID
        let kind: Kind
        var lines: [TerminalLine]
    }

    fileprivate static func groupTranscript(_ lines: [TerminalLine]) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        for line in lines {
            let kind: TranscriptBlock.Kind
            switch line.type {
            case .command: kind = .user
            case .output:  kind = .agent
            case .system:  kind = .tool
            case .error:   kind = .error
            case .thinking: continue
            }
            if !blocks.isEmpty, blocks[blocks.count - 1].kind == kind {
                blocks[blocks.count - 1].lines.append(line)
            } else {
                blocks.append(TranscriptBlock(id: line.id, kind: kind, lines: [line]))
            }
        }
        return blocks
    }

    @ViewBuilder
    private func blockView(_ block: TranscriptBlock, agent: AgentType) -> some View {
        switch block.kind {
        case .user:  userBubble(block)
        case .agent: agentBubble(block, agent: agent)
        case .tool:  toolCallout(block)
        case .error: errorCallout(block)
        }
    }

    private func userBubble(_ block: TranscriptBlock) -> some View {
        let text = block.lines
            .map { Self.stripPromptPrefix($0.text) }
            .joined(separator: "\n")
        return HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 60)
            Text(text)
                .font(.system(size: 14.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [Color.claudeOrange, Color.claudeOrange.opacity(0.82)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func agentBubble(_ block: TranscriptBlock, agent: AgentType) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AgentIcon(agent: agent, size: 18)
                .padding(7)
                .background(Circle().fill(Color.cardBackground))
                .overlay(Circle().stroke(Color.fieldBorder.opacity(0.45), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                ForEach(block.lines) { line in
                    agentLine(line)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.cardBackground.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.fieldBorder.opacity(0.3), lineWidth: 1)
            )

            Spacer(minLength: 40)
        }
    }

    @ViewBuilder
    private func agentLine(_ line: TerminalLine) -> some View {
        let text = line.text
        if text.hasPrefix("  + ") {
            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Color.statusGreen)
                .fixedSize(horizontal: false, vertical: true)
        } else if text.hasPrefix("  - ") {
            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Color.red.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        } else if text.hasPrefix("  ") || text.isEmpty {
            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Color.subtleText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toolCallout(_ block: TranscriptBlock) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(block.lines) { line in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: Self.toolIcon(for: line.text))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.subtleText)
                        .frame(width: 16)
                        .padding(.top, 2)
                    Text(line.text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.cardBackground.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.fieldBorder.opacity(0.25), lineWidth: 1)
        )
    }

    private func errorCallout(_ block: TranscriptBlock) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(block.lines) { line in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .frame(width: 16)
                        .padding(.top, 2)
                    Text(line.text)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
    }

    private func thinkingIndicator(agent: AgentType) -> some View {
        HStack(alignment: .center, spacing: 10) {
            AgentIcon(agent: agent, size: 18)
                .padding(7)
                .background(Circle().fill(Color.cardBackground))
                .overlay(Circle().stroke(Color.fieldBorder.opacity(0.45), lineWidth: 1))

            HStack(spacing: 6) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.7)
                    .tint(Color.claudeOrange)
                Text("Responding…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.claudeOrange.opacity(0.78))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.cardBackground.opacity(0.6))
            )

            Spacer(minLength: 40)
        }
    }

    private static func stripPromptPrefix(_ s: String) -> String {
        if s.hasPrefix("> ") { return String(s.dropFirst(2)) }
        if s.hasPrefix("$ ") { return String(s.dropFirst(2)) }
        return s
    }

    private static func toolIcon(for text: String) -> String {
        if text.hasPrefix("Read ")   { return "doc.text" }
        if text.hasPrefix("Edit ")   { return "pencil" }
        if text.hasPrefix("Write ")  { return "doc.badge.plus" }
        if text.hasPrefix("Bash")    { return "terminal" }
        if text.hasPrefix("Grep") || text.hasPrefix("Search") { return "magnifyingglass" }
        if text.hasPrefix("Glob")    { return "square.grid.2x2" }
        return "gearshape"
    }

    // MARK: - Composer

    private func composer(for s: AgentSession) -> some View {
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

            HStack(alignment: .bottom, spacing: 10) {
                TextField(s.writable ? "Message Agent Watcher" : "Read-only session", text: $promptText, axis: .vertical)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .tint(Color.claudeOrange)
                    .lineLimit(1...6)
                    .padding(.leading, 4)
                    .padding(.vertical, 10)
                    .focused($isPromptFocused)
                    .disabled(!s.writable || s.activity == .ended || s.activity == .waitingApproval)
                    .submitLabel(.send)
                    .onKeyPress(.return) {
                        sendPrompt(for: s)
                        return .handled
                    }

                composerButton(
                    icon: voiceInput.isRecording ? "stop.fill" : "mic.fill",
                    foreground: voiceInput.isRecording ? .white : Color.subtleText,
                    background: voiceInput.isRecording ? Color.red.opacity(0.9) : Color.white.opacity(0.06),
                    border: voiceInput.isRecording ? Color.red.opacity(0.25) : Color.fieldBorder.opacity(0.55)
                ) {
                    toggleRecording()
                }
                .disabled(!s.writable || s.activity == .ended || s.activity == .waitingApproval)

                composerButton(
                    icon: "arrow.up",
                    foreground: canSend ? .black : Color.subtleText,
                    background: canSend ? Color.claudeOrange : Color.black.opacity(0.26),
                    border: canSend ? Color.claudeOrange.opacity(0.15) : Color.fieldBorder.opacity(0.55)
                ) {
                    sendPrompt(for: s)
                }
                .disabled(!canSend || !s.writable || s.activity == .ended || s.activity == .waitingApproval)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(hex: "111111"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isPromptFocused ? Color.claudeOrange.opacity(0.55) : Color.fieldBorder.opacity(0.85), lineWidth: 1)
            )
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
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 40, height: 40)
                .background(Circle().fill(background))
                .overlay(Circle().stroke(border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var canSend: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isSessionBusy(_ s: AgentSession) -> Bool {
        !s.sharedTerminal && s.activity == .running
    }

    private func isThinking(for s: AgentSession) -> Bool {
        if !s.sharedTerminal { return s.activity == .running }
        guard s.activity == .running, let last = s.lastVisualActivityAt else { return false }
        return Date().timeIntervalSince(last) < 12
    }

    private func sendPrompt(for s: AgentSession) {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, s.writable else { return }
        if isSessionBusy(s) {
            pendingBusyPrompt = text
            isPromptFocused = false
            showBusyActions = true
            return
        }
        relayService.sendCommand(text: text, sessionId: s.id)
        clearComposer()
    }

    private func submitApprovalText(_ approval: ApprovalRequest) {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        relayService.respondToApprovalWithOption(text, index: -1, approval: approval)
        promptText = ""
        isPromptFocused = false
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

// MARK: - Voice input (iPad-local copy, behaves identical to iPhone)

final class PadVoiceInputController: NSObject, ObservableObject {
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
        guard speechAuth == .authorized else { throw VoiceError.speechDenied }

        let micGranted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard micGranted else { throw VoiceError.microphoneDenied }
    }

    private func preferredSpeechRecognizer() -> SFSpeechRecognizer? {
        for id in preferredLocaleIdentifiers() {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)) {
                return recognizer
            }
        }
        return SFSpeechRecognizer()
    }

    private func preferredLocaleIdentifiers() -> [String] {
        var ids: [String] = []
        let prefs = Locale.preferredLanguages
        let zh = prefs.filter { $0.lowercased().hasPrefix("zh") }
        if !zh.isEmpty { ids.append(contentsOf: zh) }
        ids.append(contentsOf: ["zh-CN", "zh-Hans-CN", Locale.current.identifier])
        ids.append(contentsOf: prefs)
        ids.append("en-US")
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private enum VoiceError: LocalizedError {
        case speechDenied
        case microphoneDenied
        case speechUnavailable

        var errorDescription: String? {
            switch self {
            case .speechDenied: return "Speech recognition permission is required."
            case .microphoneDenied: return "Microphone permission is required."
            case .speechUnavailable: return "Speech recognition is currently unavailable."
            }
        }
    }
}
