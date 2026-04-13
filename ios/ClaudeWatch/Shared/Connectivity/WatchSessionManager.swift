import Foundation
import WatchConnectivity
import Combine

/// Shared WCSession delegate used by both the iOS and watchOS targets.
/// Manages session activation, reachability, message sending with automatic
/// fallback to `transferUserInfo`, and application context updates.
///
/// Conforms to `ObservableObject` so SwiftUI views can observe connectivity changes.
final class WatchSessionManager: NSObject, ObservableObject {

    struct BridgeCredentialsSync: Equatable {
        let baseURL: URL?
        let token: String?
        let machineName: String?
        let cleared: Bool
    }

    // MARK: - Singleton

    static let shared = WatchSessionManager()

    // MARK: - Published properties

    @Published private(set) var isReachable: Bool = false
    @Published private(set) var isActivated: Bool = false
    @Published private(set) var lastReceivedState: SessionState?

    // MARK: - Callbacks

    /// Called when a `WatchMessage` is received from the counterpart.
    var onMessageReceived: ((WatchMessage) -> Void)?

    /// Called when the application context is updated by the counterpart.
    var onApplicationContextReceived: (([String: Any]) -> Void)?

    /// Called when bridge credentials are synced from the companion iPhone.
    var onBridgeCredentialsReceived: ((BridgeCredentialsSync) -> Void)?

    /// Called on iPhone when the watch explicitly requests current bridge credentials.
    var onBridgeCredentialsRequested: (() -> Void)?

    /// Called on iPhone when the watch requests the latest relay snapshot.
    var onRelaySnapshotRequested: (() -> Void)?

    // MARK: - Private

    private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }

    private override init() {
        super.init()
    }

    // MARK: - Activation

    /// Activates the WCSession. Call this early in the app lifecycle
    /// (e.g., in `App.init()` or `application(_:didFinishLaunchingWithOptions:)`).
    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    // MARK: - Sending

    /// Sends a `WatchMessage` to the counterpart.
    ///
    /// If the counterpart is reachable, uses `sendMessage` for real-time delivery.
    /// Otherwise falls back to `transferUserInfo` which queues for delivery when
    /// the counterpart is next reachable.
    ///
    /// - Parameters:
    ///   - message: The `WatchMessage` to send.
    ///   - replyHandler: Optional closure invoked with the reply dictionary.
    ///   - errorHandler: Optional closure invoked on failure.
    func send(
        _ message: WatchMessage,
        replyHandler: (([String: Any]) -> Void)? = nil,
        errorHandler: ((Error) -> Void)? = nil
    ) {
        guard let session else {
            errorHandler?(WatchSessionError.sessionNotSupported)
            return
        }

        let dictionary = message.toDictionary()

        if session.isReachable {
            session.sendMessage(dictionary, replyHandler: replyHandler) { error in
                // sendMessage failed; fall back to transferUserInfo
                session.transferUserInfo(dictionary)
                errorHandler?(error)
            }
        } else {
            session.transferUserInfo(dictionary)
        }
    }

    /// Updates the application context with the current connection state.
    /// Application context is delivered lazily -- only the most recent value
    /// is kept, which makes it ideal for connection/session state.
    func updateApplicationContext(with state: SessionState) {
        guard let session else { return }

        let message = WatchMessage.sessionStateUpdate(state)
        let dictionary = message.toDictionary()

        do {
            try session.updateApplicationContext(dictionary)
        } catch {
            // Application context update failed; log and continue.
            print("[WatchSessionManager] Failed to update application context: \(error)")
        }
    }

    /// Syncs Cloudflare Access credentials to the Apple Watch.
    /// Called from iPhone when the user saves credentials in Settings or PairingView.
    func syncCloudflareCredentials(clientId: String, clientSecret: String) {
        guard let session, session.isReachable || WCSession.isSupported() else { return }
        let payload: [String: Any] = [
            "_cfConfig": true,
            "cf_client_id": clientId,
            "cf_client_secret": clientSecret
        ]
        session.transferUserInfo(payload)
    }

    /// Syncs bridge URL + token to the Apple Watch so the watch can reuse the
    /// phone pairing without asking for a second 6-digit code.
    func syncBridgeCredentials(baseURL: URL, token: String, machineName: String?) {
        guard let session else { return }

        var payload: [String: Any] = [
            "_bridgeConfig": true,
            "bridge_url": baseURL.absoluteString,
            "bridge_token": token
        ]
        if let machineName, !machineName.isEmpty {
            payload["machine_name"] = machineName
        }

        do {
            try session.updateApplicationContext(payload)
        } catch {
            print("[WatchSessionManager] Failed to update bridge credentials context: \(error)")
        }
        session.transferUserInfo(payload)
    }

    func clearBridgeCredentials() {
        guard let session else { return }

        let payload: [String: Any] = [
            "_bridgeConfig": true,
            "bridge_cleared": true
        ]

        do {
            try session.updateApplicationContext(payload)
        } catch {
            print("[WatchSessionManager] Failed to clear bridge credentials context: \(error)")
        }
        session.transferUserInfo(payload)
    }

    /// Watch-side pull path for cases where the companion was already paired
    /// before the watch app launched or was reinstalled.
    func requestBridgeCredentialsSync() {
        guard let session else { return }

        let payload: [String: Any] = [
            "_bridgeConfigRequest": true
        ]

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { error in
                print("[WatchSessionManager] Failed to request bridge credentials: \(error)")
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    func requestRelaySnapshot() {
        guard let session else { return }

        let payload: [String: Any] = [
            "_relaySnapshotRequest": true
        ]

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { error in
                print("[WatchSessionManager] Failed to request relay snapshot: \(error)")
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    #if os(iOS)
    /// Transfers complication user info to the watch.
    /// Only available on iOS; the watch reads this via `didReceiveUserInfo`.
    func transferComplicationUserInfo(_ state: SessionState) {
        guard let session else { return }

        let message = WatchMessage.sessionStateUpdate(state)
        let dictionary = message.toDictionary()

        session.transferCurrentComplicationUserInfo(dictionary)
    }
    #endif

    // MARK: - Errors

    enum WatchSessionError: LocalizedError {
        case sessionNotSupported

        var errorDescription: String? {
            switch self {
            case .sessionNotSupported:
                return "WCSession is not supported on this device."
            }
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {

    // MARK: Activation

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.isActivated = activationState == .activated
            self.isReachable = session.isReachable
        }

        if let error {
            print("[WatchSessionManager] Activation failed: \(error)")
        }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in
            self.isActivated = false
        }
    }

    func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            self.isActivated = false
            self.isReachable = false
        }
        // Re-activate for multi-watch switching support
        session.activate()
    }
    #endif

    // MARK: Reachability

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
        }
    }

    // MARK: Receiving messages

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        handleIncoming(dictionary: message)
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        handleIncoming(dictionary: message)
        replyHandler(["status": "received"])
    }

    // MARK: Receiving user info (transferUserInfo fallback)

    func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        handleIncoming(dictionary: userInfo)
    }

    // MARK: Application context

    func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        handleIncoming(dictionary: applicationContext)
        onApplicationContextReceived?(applicationContext)
    }

    // MARK: - Private helpers

    private func handleIncoming(dictionary: [String: Any]) {
        // Handle Cloudflare credentials sync (not a WatchMessage, uses a raw dictionary)
        if dictionary["_cfConfig"] as? Bool == true {
            if let id = dictionary["cf_client_id"] as? String,
               let secret = dictionary["cf_client_secret"] as? String {
                UserDefaults.standard.set(id, forKey: "cf_client_id")
                UserDefaults.standard.set(secret, forKey: "cf_client_secret")
                print("[WatchSessionManager] Cloudflare credentials synced from companion")
            }
            return
        }

        if dictionary["_bridgeConfig"] as? Bool == true {
            let cleared = dictionary["bridge_cleared"] as? Bool == true
            let credentials = BridgeCredentialsSync(
                baseURL: URL(string: dictionary["bridge_url"] as? String ?? ""),
                token: dictionary["bridge_token"] as? String,
                machineName: (dictionary["machine_name"] as? String)?.isEmpty == false
                    ? dictionary["machine_name"] as? String
                    : nil,
                cleared: cleared
            )

            onBridgeCredentialsReceived?(credentials)
            return
        }

        if dictionary["_bridgeConfigRequest"] as? Bool == true {
            onBridgeCredentialsRequested?()
            return
        }

        if dictionary["_relaySnapshotRequest"] as? Bool == true {
            onRelaySnapshotRequested?()
            return
        }

        do {
            let message = try WatchMessage(from: dictionary)

            // If it's a session state update, publish it
            if case .sessionStateUpdate(let state) = message {
                Task { @MainActor in
                    self.lastReceivedState = state
                }
            }

            onMessageReceived?(message)
        } catch {
            print("[WatchSessionManager] Failed to decode incoming message: \(error)")
        }
    }
}
