import SwiftUI

// MARK: - VoiceInputView

/// Full-screen voice capture mode. Uses watchOS system dictation (TextField with dictation)
/// since the Speech framework is not available on watchOS.
struct VoiceInputView: View {
    var sessionId: String? = nil
    @EnvironmentObject private var session: WatchViewState
    @Environment(\.dismiss) private var dismiss

    @State private var commandText = ""
    @State private var animationPhase: CGFloat = 0
    @FocusState private var isTextFieldFocused: Bool

    private let waveTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Theme.Background.capture.ignoresSafeArea()

            VStack(spacing: 12) {
                Text("Say your command")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.Text.primary)

                // Waveform animation (decorative)
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.Text.primary)
                            .frame(width: 6, height: barHeight(for: index))
                    }
                }
                .frame(height: 40)
                .onReceive(waveTimer) { _ in
                    animationPhase += 1
                }

                TextFieldLink(prompt: Text("Say your command")) {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                        Text("Dictate")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Theme.Text.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } onSubmit: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    commandText = trimmed
                    sendCommand()
                }

                TextField("Or type here", text: $commandText)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(Theme.Text.primary)
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        sendCommand()
                    }

                if !commandText.isEmpty {
                    // Send button
                    Button {
                        sendCommand()
                    } label: {
                        Text("Send")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Theme.Text.primary)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.Text.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: CGFloat = 12
        let variation: CGFloat = 20
        let phase = animationPhase + CGFloat(index) * 2
        return base + abs(sin(phase * 0.3)) * variation
    }

    private func sendCommand() {
        let text = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        HapticManager.commandSent()
        session.sendVoiceCommand(text, sessionId: sessionId)
        dismiss()
    }

}

// MARK: - Preview

#Preview {
    VoiceInputView()
        .environmentObject(WatchViewState.shared)
}
