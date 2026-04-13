import Foundation

/// Server-Sent Events client that connects to the bridge `/events` endpoint.
/// Supports automatic reconnection with `Last-Event-ID`, heartbeat timeout
/// detection, and fallback to polling when SSE fails repeatedly.
final class SSEClient {

    // MARK: - Types

    struct SSEEvent {
        let id: String?
        let event: String?
        let data: String
    }

    enum SSEState {
        case disconnected
        case connecting
        case connected
        case polling
    }

    // MARK: - Configuration

    private let heartbeatTimeout: TimeInterval = 45.0
    private let maxSSEFailures = 6
    private let sseFailureWindow: TimeInterval = 90.0
    private let pollingInterval: TimeInterval = 2.0

    // MARK: - Callbacks

    var onEvent: ((SSEEvent) -> Void)?
    var onStateChange: ((SSEState) -> Void)?
    var onAuthRejected: (() -> Void)?

    // MARK: - Properties

    private(set) var state: SSEState = .disconnected {
        didSet {
            if oldValue != state {
                onStateChange?(state)
            }
        }
    }

    private var baseURL: URL?
    private var token: String?
    private var lastEventId: String?

    private var urlSession: URLSession?
    private var dataTask: URLSessionDataTask?
    private var heartbeatTimer: Timer?
    private var pollingTimer: Timer?

    // Failure tracking for SSE -> polling fallback
    private var sseFailures: [Date] = []

    // Buffer for parsing SSE lines
    private var lineBuffer = ""
    private var currentEventType: String?
    private var currentEventData: [String] = []
    private var currentEventId: String?

    // Delegate for streaming
    private var sessionDelegate: SSESessionDelegate?

    // MARK: - Lifecycle

    func connect(baseURL: URL, token: String, preferPolling: Bool = false) {
        self.baseURL = baseURL
        self.token = token
        debug("connect url=\(baseURL.absoluteString) preferPolling=\(preferPolling)")
        if preferPolling {
            stopSSE()
            startPolling()
        } else {
            startSSE()
        }
    }

    func disconnect() {
        debug("disconnect")
        stopSSE()
        stopPolling()
        state = .disconnected
    }

    // MARK: - SSE Connection

    private func startSSE() {
        stopSSE()
        state = .connecting

        guard let baseURL, let token else { return }

        let eventsURL = baseURL.appendingPathComponent("events")
        var request = URLRequest(url: eventsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 0 // No timeout for SSE
        request.addCloudflareAccessHeaders()

        if let lastEventId {
            request.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID")
        }

        debug("startSSE url=\(eventsURL.absoluteString) lastEventId=\(lastEventId ?? "none")")

        let delegate = SSESessionDelegate(client: self)
        self.sessionDelegate = delegate

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 0
        config.timeoutIntervalForResource = 0
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.urlSession = session

        let task = session.dataTask(with: request)
        self.dataTask = task
        task.resume()

        resetHeartbeatTimer()
    }

    private func stopSSE() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        dataTask?.cancel()
        dataTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionDelegate = nil
        lineBuffer = ""
        currentEventType = nil
        currentEventData = []
        currentEventId = nil
    }

    // MARK: - Heartbeat

    private func resetHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: heartbeatTimeout,
            repeats: false
        ) { [weak self] _ in
            self?.handleHeartbeatTimeout()
        }
    }

    private func handleHeartbeatTimeout() {
        // No data received within the heartbeat window -- reconnect
        debug("heartbeat-timeout")
        recordSSEFailure()
        reconnectOrFallback()
    }

    // MARK: - Failure tracking & fallback

    private func recordSSEFailure() {
        let now = Date()
        sseFailures.append(now)
        // Prune old failures outside the window
        sseFailures = sseFailures.filter { now.timeIntervalSince($0) < sseFailureWindow }
    }

    private func shouldFallbackToPolling() -> Bool {
        let now = Date()
        let recentFailures = sseFailures.filter { now.timeIntervalSince($0) < sseFailureWindow }
        return recentFailures.count >= maxSSEFailures
    }

    private func reconnectOrFallback() {
        stopSSE()

        if shouldFallbackToPolling() {
            debug("fallback-to-polling failures=\(sseFailures.count)")
            startPolling()
        } else {
            // Reconnect SSE after a brief delay
            debug("reconnect-sse failures=\(sseFailures.count)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.startSSE()
            }
        }
    }

    // MARK: - Polling fallback

    private func startPolling() {
        stopPolling()
        state = .polling
        debug("startPolling interval=\(pollingInterval)s")

        pollingTimer = Timer.scheduledTimer(
            withTimeInterval: pollingInterval,
            repeats: true
        ) { [weak self] _ in
            self?.poll()
        }
        // Immediate first poll
        poll()
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func poll() {
        guard let baseURL, let token else { return }

        let statusURL = baseURL.appendingPathComponent("status")
        var request = URLRequest(url: statusURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5
        request.addCloudflareAccessHeaders()

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self, error == nil, let data else { return }
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                DispatchQueue.main.async {
                    self.onAuthRejected?()
                }
                return
            }

            if (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil {
                self.debug("poll-status bytes=\(data.count)")
                let event = SSEEvent(
                    id: nil,
                    event: "poll-status",
                    data: String(data: data, encoding: .utf8) ?? "{}"
                )
                DispatchQueue.main.async {
                    self.onEvent?(event)
                }
            }
        }
        task.resume()
    }

    // MARK: - SSE Parsing

    fileprivate func handleSSEConnected() {
        DispatchQueue.main.async {
            self.debug("connected")
            self.state = .connected
        }
    }

    fileprivate func handleAuthRejected() {
        stopSSE()
        stopPolling()
        state = .disconnected
        DispatchQueue.main.async {
            self.onAuthRejected?()
        }
    }

    fileprivate func handleReceivedData(_ data: Data) {
        resetHeartbeatTimer()

        guard let text = String(data: data, encoding: .utf8) else { return }
        lineBuffer += text

        // Process complete lines
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
            lineBuffer = String(lineBuffer[newlineRange.upperBound...])
            processSSELine(line)
        }
    }

    private func processSSELine(_ line: String) {
        // Empty line = end of event
        if line.isEmpty {
            dispatchCurrentEvent()
            return
        }

        // Comment (heartbeat)
        if line.hasPrefix(":") {
            return
        }

        // Parse field:value
        if line.hasPrefix("id:") {
            let value = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            currentEventId = value
        } else if line.hasPrefix("event:") {
            let value = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            currentEventType = value
        } else if line.hasPrefix("data:") {
            let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            currentEventData.append(value)
        } else if line.hasPrefix("retry:") {
            // Could adjust reconnection interval; ignored for now
        }
    }

    private func dispatchCurrentEvent() {
        guard !currentEventData.isEmpty else {
            // Reset but no event to dispatch
            currentEventType = nil
            currentEventId = nil
            return
        }

        let data = currentEventData.joined(separator: "\n")
        let event = SSEEvent(
            id: currentEventId,
            event: currentEventType,
            data: data
        )

        if let id = currentEventId {
            lastEventId = id
        }

        // Reset
        currentEventType = nil
        currentEventData = []
        currentEventId = nil

        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    fileprivate func handleSSEError(_ error: Error?) {
        debug("error \(error?.localizedDescription ?? "unknown")")
        recordSSEFailure()
        reconnectOrFallback()
    }

    fileprivate func handleSSEComplete() {
        // Stream ended gracefully -- reconnect
        debug("complete")
        reconnectOrFallback()
    }

    private func debug(_ message: String) {
        print("[SSEClient] \(message)")
    }
}

// MARK: - URLSession Delegate for streaming

private final class SSESessionDelegate: NSObject, URLSessionDataDelegate {

    private weak var client: SSEClient?

    init(client: SSEClient) {
        self.client = client
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            client?.handleSSEConnected()
            completionHandler(.allow)
        } else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            client?.handleAuthRejected()
            completionHandler(.cancel)
        } else {
            if let httpResponse = response as? HTTPURLResponse {
                print("[SSEClient] unexpected-response status=\(httpResponse.statusCode)")
            }
            client?.handleSSEError(nil)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        client?.handleReceivedData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            client?.handleSSEError(error)
        } else {
            client?.handleSSEComplete()
        }
    }
}
