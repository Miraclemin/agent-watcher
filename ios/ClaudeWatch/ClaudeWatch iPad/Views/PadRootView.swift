import SwiftUI

/// iPad root view. Two-column split: session sidebar + session detail.
/// Reuses `RelayService` verbatim — approval and session-ownership logic
/// are identical to the iPhone build (no overrides, no duplication).
struct PadRootView: View {

    @EnvironmentObject private var relayService: RelayService
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedSessionId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showSettings = false
    @State private var showNewSessionDialog = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PadSessionSidebar(
                selectedSessionId: $selectedSessionId,
                onOpenSettings: { showSettings = true }
            )
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
        } detail: {
            Group {
                if let id = selectedSessionId,
                   let session = relayService.sessions.first(where: { $0.id == id }) {
                    PadSessionDetailView(session: session)
                        .id(session.id)
                } else {
                    PadEmptyDetailView(showNewSessionDialog: $showNewSessionDialog)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewSessionDialog = true
                    } label: {
                        Image(systemName: "plus.square.on.square")
                            .foregroundStyle(Color.claudeOrange)
                    }
                }
            }
        }
        .tint(Color.claudeOrange)
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(relayService)
        }
        .confirmationDialog("Open New Session", isPresented: $showNewSessionDialog, titleVisibility: .visible) {
            Button("New Codex Window") {
                let cwd = currentSession()?.cwd
                relayService.spawnDesktopSession(agent: .codex, cwd: cwd)
            }
            Button("New Claude Window") {
                let cwd = currentSession()?.cwd
                relayService.spawnDesktopSession(agent: .claude, cwd: cwd)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Mac will open a new desktop terminal window, and the new session will appear here immediately.")
        }
        .onAppear {
            relayService.updateScenePhase(scenePhase)
            syncInitialSelection()
        }
        .onChange(of: scenePhase) { _, newValue in
            relayService.updateScenePhase(newValue)
        }
        .onChange(of: relayService.sessions.map(\.id)) { _, _ in
            syncInitialSelection()
        }
        .onChange(of: relayService.focusedSessionId) { _, newValue in
            guard let newValue,
                  relayService.sessions.contains(where: { $0.id == newValue }) else { return }
            selectedSessionId = newValue
        }
        .onChange(of: relayService.pendingApprovalSessionId) { _, newValue in
            if let newValue,
               relayService.sessions.contains(where: { $0.id == newValue }) {
                selectedSessionId = newValue
            }
        }
        .onChange(of: selectedSessionId) { _, newValue in
            guard let newValue else { return }
            relayService.focusSession(newValue)
        }
    }

    private func currentSession() -> AgentSession? {
        if let id = selectedSessionId,
           let s = relayService.sessions.first(where: { $0.id == id }) {
            return s
        }
        return relayService.sessions.first
    }

    private func syncInitialSelection() {
        if let id = selectedSessionId,
           relayService.sessions.contains(where: { $0.id == id }) {
            return
        }
        if let focused = relayService.focusedSessionId,
           relayService.sessions.contains(where: { $0.id == focused }) {
            selectedSessionId = focused
        } else {
            selectedSessionId = relayService.sessions.first?.id
        }
    }
}

// MARK: - Empty detail

private struct PadEmptyDetailView: View {
    @EnvironmentObject private var relayService: RelayService
    @Binding var showNewSessionDialog: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 18) {
                AppLogo(size: 72)

                if relayService.sessions.isEmpty {
                    Text("Waiting for a session")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Start `claude` or `codex` on your Mac, or open a new window from the toolbar.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.subtleText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 48)
                    Button {
                        showNewSessionDialog = true
                    } label: {
                        Label("Open New Session", systemImage: "plus.square.on.square")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color.claudeOrange)
                            .foregroundStyle(.black)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Select a session")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Pick an agent in the sidebar to see its terminal and send input.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.subtleText)
                }
            }
        }
    }
}
