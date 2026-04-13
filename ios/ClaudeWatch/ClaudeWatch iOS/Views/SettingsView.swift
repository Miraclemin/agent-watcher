import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var relayService: RelayService
    @Environment(\.dismiss) private var dismiss

    @AppStorage("connectionMode") private var connectionMode: ConnectionMode = .auto

    @State private var showForgetConfirmation = false

    // Cloudflare Access credentials
    @State private var cfClientId: String = UserDefaults.standard.string(forKey: "cf_client_id") ?? ""
    @State private var cfClientSecret: String = UserDefaults.standard.string(forKey: "cf_client_secret") ?? ""
    @State private var cfSaved: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                cloudflareSection
                pairedMacSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(Color.claudeOrange)
                }
            }
            .alert("Forget Mac?", isPresented: $showForgetConfirmation) {
                Button("Forget", role: .destructive) {
                    relayService.clearPairingNotice()
                    relayService.unpair()
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You will need to re-pair with a new code from Claude Code.")
            }
        }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section {
            Picker("Connection Mode", selection: $connectionMode) {
                Text("Auto").tag(ConnectionMode.auto)
                Text("LAN Only").tag(ConnectionMode.lanOnly)
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("Auto discovers the bridge via Bonjour on your local network.")
        }
    }

    private var cloudflareSection: some View {
        Section {
            TextField("CF-Access-Client-Id", text: $cfClientId)
                .font(.system(size: 14, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("CF-Access-Client-Secret", text: $cfClientSecret)
                .font(.system(size: 14, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                let id = cfClientId.trimmingCharacters(in: .whitespacesAndNewlines)
                let secret = cfClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                UserDefaults.standard.set(id, forKey: "cf_client_id")
                UserDefaults.standard.set(secret, forKey: "cf_client_secret")
                WatchSessionManager.shared.syncCloudflareCredentials(clientId: id, clientSecret: secret)
                cfSaved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { cfSaved = false }
            } label: {
                HStack {
                    Text(cfSaved ? "Saved & Synced to Watch" : "Save & Sync to Watch")
                    Spacer()
                    if cfSaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
        } header: {
            Text("Cloudflare Access")
        } footer: {
            Text("For remote access via Cloudflare Tunnel. Leave blank for local network use. Get credentials from Zero Trust → Access → Service Auth.")
        }
    }

    private var pairedMacSection: some View {
        Section("Paired Mac") {
            if relayService.isPaired {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(relayService.machineName ?? "Unknown Mac")
                            .foregroundStyle(.white)
                        if let lastConnected = relayService.lastConnected {
                            Text("Last connected \(lastConnected, style: .relative) ago")
                                .font(.caption)
                                .foregroundStyle(Color.subtleText)
                        }
                    }
                    Spacer()
                }

                Button("Forget This Mac", role: .destructive) {
                    showForgetConfirmation = true
                }
            } else {
                Text("No Mac paired")
                    .foregroundStyle(Color.subtleText)
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                    .foregroundStyle(Color.subtleText)
            }

            Link(destination: URL(string: "https://github.com/anthropics/claude-code")!) {
                HStack {
                    Text("Claude Code")
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(Color.subtleText)
                }
            }
        }
    }
}

// MARK: - Connection Mode

enum ConnectionMode: String {
    case auto
    case lanOnly
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(RelayService.shared)
}
