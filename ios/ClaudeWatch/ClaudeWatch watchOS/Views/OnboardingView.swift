import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var session: WatchViewState
    @StateObject private var connectivity = WatchSessionManager.shared

    var body: some View {
        VStack(spacing: 8) {
            Spacer()

            AppLogo(size: 24)

            Text("Open iPhone App")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Theme.Text.primary)

            Text(statusText)
                .font(.system(size: 11))
                .foregroundColor(Theme.Text.secondary)
                .multilineTextAlignment(.center)

            Button {
                session.requestCompanionSync()
            } label: {
                Text("Retry Sync")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(Theme.Text.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Background.primary)
        .onAppear {
            session.requestCompanionSync()
        }
    }

    private var statusText: String {
        if !connectivity.isActivated {
            return "Waiting for Apple Watch connectivity"
        }
        if connectivity.isReachable {
            return "Bring the iPhone app to foreground to sync sessions"
        }
        return "Keep iPhone nearby, then open the iPhone app"
    }
}

#Preview {
    OnboardingView().environmentObject(WatchViewState.shared)
}
