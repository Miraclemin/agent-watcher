import SwiftUI

/// Sidebar session list. One row per session with agent icon, folder,
/// activity state, and an approval indicator pill that matches the
/// iPhone build's visual language.
struct PadSessionSidebar: View {

    @EnvironmentObject private var relayService: RelayService
    @Binding var selectedSessionId: String?
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                brandHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                List(selection: $selectedSessionId) {
                Section {
                    if relayService.sessions.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(Color.claudeOrange)
                            Text("Waiting for agents…")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.subtleText)
                        }
                        .padding(.vertical, 10)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(relayService.sessions) { session in
                            PadSessionRow(
                                session: session,
                                isSelected: selectedSessionId == session.id
                            )
                                .tag(session.id)
                                .listRowBackground(Color.clear)
                                .listRowSeparatorTint(Color.fieldBorder.opacity(0.4))
                        }
                    }
                } header: {
                    sidebarHeader
                }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.black)
            }
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            AppLogo(size: 24)
            Text("Agent Watcher")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.subtleText)
                    .padding(8)
                    .background(Color.cardBackground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            connectionDot
            Text(connectionLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.subtleText)
                .textCase(nil)

            Spacer()

            Text(transportLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.subtleText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.cardBackground)
                .clipShape(Capsule())
        }
        .padding(.vertical, 6)
    }

    private var connectionDot: some View {
        Circle()
            .fill(connectionColor)
            .frame(width: 8, height: 8)
    }

    private var connectionColor: Color {
        switch relayService.connectionState {
        case .connected: return Color.statusGreen
        case .connecting: return Color.claudeOrange
        case .disconnected: return Color.subtleText
        case .iPhoneUnreachable: return Color.claudeAmber
        }
    }

    private var connectionLabel: String {
        switch relayService.connectionState {
        case .connected: return relayService.machineName ?? "CONNECTED"
        case .connecting: return "CONNECTING…"
        case .disconnected: return "OFFLINE"
        case .iPhoneUnreachable: return "RELAY UNREACHABLE"
        }
    }

    private var transportLabel: String {
        switch relayService.currentTransportMode {
        case .lan: return "LAN"
        case .direct: return "DIRECT"
        case .remote: return "RELAY"
        }
    }
}

private struct PadSessionRow: View {
    let session: AgentSession
    let isSelected: Bool

    private var needsApproval: Bool {
        session.activity == .waitingApproval || session.pendingApproval != nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AgentIcon(agent: session.agent, size: 20)
                .padding(6)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.folderName.isEmpty ? "session" : session.folderName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if session.sharedTerminal {
                        Text("Shared")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.statusGreen.opacity(0.2))
                            .foregroundStyle(Color.statusGreen)
                            .clipShape(Capsule())
                    } else if !session.writable {
                        Text("RO")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.subtleText.opacity(0.2))
                            .foregroundStyle(Color.subtleText)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(activityColor)
                        .frame(width: 6, height: 6)
                    Text(activityLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.subtleText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if needsApproval {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.claudeAmber)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.claudeOrange.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.claudeOrange.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(Color.claudeOrange)
                    .frame(width: 3, height: 28)
                    .padding(.leading, 2)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    private var activityColor: Color {
        switch session.activity {
        case .running: return Color.statusGreen
        case .waitingApproval: return Color.claudeAmber
        case .ended: return Color.red.opacity(0.8)
        case .idle: return Color.subtleText
        }
    }

    private var activityLabel: String {
        switch session.activity {
        case .running: return "Running"
        case .waitingApproval: return "Approval needed"
        case .ended: return "Ended"
        case .idle: return "Idle"
        }
    }
}
