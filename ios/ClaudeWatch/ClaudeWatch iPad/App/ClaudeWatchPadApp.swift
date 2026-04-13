import SwiftUI

@main
struct ClaudeWatchPadApp: App {

    @StateObject private var relayService = RelayService.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if relayService.isPaired {
                    PadRootView()
                } else {
                    PairingView()
                }
            }
            .environmentObject(relayService)
            .preferredColorScheme(.dark)
        }
    }
}
