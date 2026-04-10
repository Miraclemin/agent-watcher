import SwiftUI

struct SessionView: View {
    let sessionIndex: Int
    @EnvironmentObject private var session: WatchViewState

    @State private var showVoiceInput = false
    @State private var cursorVisible = true
    private let cursorTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    private var agentSession: AgentSession {
        guard session.sessions.indices.contains(sessionIndex) else {
            return AgentSession(id: "", agent: .claude, cwd: "", folderName: "", activity: .idle)
        }
        return session.sessions[sessionIndex]
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Top bar — agent icon + folder name
                HStack(spacing: 4) {
                    AgentIcon(agent: agentSession.agent, size: 14)
                    Text(agentSession.displayName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.Text.primary)
                        .lineLimit(1)
                    Text(agentSession.sharedTerminal ? "SHR" : "RO")
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(agentSession.sharedTerminal ? Theme.Accent.success : Theme.Accent.approval)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background((agentSession.sharedTerminal ? Theme.Accent.success : Theme.Accent.approval).opacity(0.16))
                        .clipShape(Capsule())
                    if agentSession.activity == .waitingApproval || agentSession.pendingApproval != nil {
                        Text("ASK")
                            .font(.system(size: 8, weight: .black))
                            .foregroundColor(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Theme.Accent.approval)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)

                // Terminal
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(visibleLines) { line in
                                terminalLine(line)
                                    .id(line.id)
                            }

                            if isThinking {
                                Text(cursorVisible ? "\u{2588}" : " ")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Theme.Text.primary)
                                    .onReceive(cursorTimer) { _ in cursorVisible.toggle() }
                                    .id("cursor")
                            }

                            Spacer().frame(height: 40)
                        }
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: agentSession.terminalLines.count) { _ in
                        withAnimation(.easeOut(duration: 0.1)) {
                            if isThinking {
                                proxy.scrollTo("cursor", anchor: .bottom)
                            } else if let last = visibleLines.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .background(Theme.Background.primary)

            // FAB buttons
            HStack {
                // Clear button (left)
                Button { session.clearTerminal(sessionId: agentSession.id) } label: {
                    ZStack {
                        Circle()
                            .fill(Theme.Text.secondary.opacity(0.5))
                            .frame(width: 28, height: 28)
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                    }
                    .shadow(color: .black.opacity(0.6), radius: 6, y: 3)
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)

                Spacer()

                // Mic button (right)
                Button { showVoiceInput = true } label: {
                    ZStack {
                        Circle()
                            .fill(Theme.Text.primary.opacity(0.75))
                            .frame(width: 28, height: 28)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.black)
                    }
                    .shadow(color: .black.opacity(0.6), radius: 6, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(!micEnabled)
                .padding(.trailing, 16)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 16)
        }
        .ignoresSafeArea(edges: .bottom)
        .sheet(item: $session.pendingApproval) { request in
            ApprovalView(request: request)
        }
        .fullScreenCover(isPresented: $showVoiceInput) {
            VoiceInputView(sessionId: agentSession.id)
        }
    }

    private var visibleLines: [TerminalLine] {
        agentSession.terminalLines
            .filter { !$0.text.isEmpty || $0.type == .thinking }
            .suffix(30)
            .map { $0 }
    }

    @ViewBuilder
    private func terminalLine(_ line: TerminalLine) -> some View {
        Text(line.text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(colorForLine(line))
            .lineLimit(4)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func colorForLine(_ line: TerminalLine) -> Color {
        if line.type == .output && line.text.hasPrefix("  + ") {
            return Theme.Accent.success
        }
        return colorFor(line.type)
    }

    private var micEnabled: Bool {
        if agentSession.activity == .ended { return false }
        // Allow mic for Codex inline approvals (user says 'y'/'n')
        if agentSession.agent == .codex
            && agentSession.activity == .waitingApproval
            && agentSession.pendingApproval != nil {
            return true
        }
        return agentSession.writable && agentSession.activity != .waitingApproval
    }

    private var isThinking: Bool {
        agentSession.terminalLines.last?.type == .thinking
    }

    private var statusColor: Color {
        switch agentSession.activity {
        case .running: return Theme.Accent.success
        case .waitingApproval: return Theme.Accent.approval
        case .ended: return Theme.Accent.error
        case .idle: return Theme.Text.secondary
        }
    }

    private func colorFor(_ type: TerminalLine.LineType) -> Color {
        switch type {
        case .output:   return Theme.Text.primary
        case .command:  return .white
        case .system:   return Theme.Text.secondary
        case .thinking: return Theme.Text.primary.opacity(0.5)
        case .error:    return Theme.Accent.error
        }
    }
}

#Preview {
    let session = {
        var s = AgentSession(
            id: "preview-1",
            agent: .claude,
            cwd: "/Users/shobhit/projects/benchyy",
            folderName: "benchyy",
            activity: .running
        )
        s.terminalLines = [
            TerminalLine(text: "⏺ Reading project structure...", type: .system, sessionId: "preview-1"),
            TerminalLine(text: "$ find . -name '*.swift' | head -20", type: .command, sessionId: "preview-1"),
            TerminalLine(text: "./Sources/App/Models/Session.swift", type: .output, sessionId: "preview-1"),
            TerminalLine(text: "./Sources/App/Views/SessionView.swift", type: .output, sessionId: "preview-1"),
            TerminalLine(text: "./Sources/App/Views/DashboardView.swift", type: .output, sessionId: "preview-1"),
            TerminalLine(text: "./Tests/SessionTests.swift", type: .output, sessionId: "preview-1"),
            TerminalLine(text: "⏺ Read Sources/App/Models/Session.swift", type: .system, sessionId: "preview-1"),
            TerminalLine(text: "Found 3 models: Session, Workout, Metric", type: .output, sessionId: "preview-1"),
            TerminalLine(text: "⏺ Edit Sources/App/Views/SessionView.swift", type: .system, sessionId: "preview-1"),
            TerminalLine(text: "Added live heart rate overlay with", type: .output, sessionId: "preview-1"),
            TerminalLine(text: "  animation and haptic feedback", type: .output, sessionId: "preview-1"),
            TerminalLine(text: "> looks good, now add the timer", type: .command, sessionId: "preview-1"),
            TerminalLine(text: "⏺ Edit Sources/App/Views/SessionView.swift", type: .system, sessionId: "preview-1"),
            TerminalLine(text: "Added elapsed timer with .monospacedDigit", type: .output, sessionId: "preview-1"),
            TerminalLine(text: "$ swift build 2>&1 | tail -3", type: .command, sessionId: "preview-1"),
            TerminalLine(text: "Build complete! (4.2s)", type: .output, sessionId: "preview-1"),
            TerminalLine(text: "", type: .thinking, sessionId: "preview-1"),
        ]
        return s
    }()

    SessionView(sessionIndex: 0)
        .environmentObject(WatchViewState.shared)
}

struct PulseModifier: ViewModifier {
    @State private var isPulsing = false
    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}
