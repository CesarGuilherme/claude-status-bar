import Foundation
import Network

/// The browser's way back from sign-in, the same one Claude Code's own login
/// uses: a one-shot HTTP server on the loopback interface (never reachable
/// from the network). It takes `GET /callback?code=…&state=…`, sends the
/// browser on to Anthropic's success page and closes.
final class OAuthLoopback: @unchecked Sendable {
    struct Callback: Equatable, Sendable {
        var code: String
        var state: String
    }

    static let successURL = "https://platform.claude.com/oauth/code/success?app=claude-code"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "claude-status-bar.oauth-loopback")
    private let lock = NSLock()
    private var ready: CheckedContinuation<UInt16, Error>?
    private var waiter: CheckedContinuation<Callback, Error>?
    private var outcome: Result<Callback, Error>?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
    }

    static func redirectURI(port: UInt16) -> String {
        "http://localhost:\(port)/callback"
    }

    /// Starts listening and returns the port the system picked.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { ready = continuation }
            listener.stateUpdateHandler = { [weak self] state in self?.changed(state) }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    /// The code the browser brings back. Throws on timeout, on an `error`
    /// answer from the authorize page, or when `cancel()` is called.
    func callback(timeout: TimeInterval) async throws -> Callback {
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { self?.finish(.failure(UsageError.oauth("timeout"))) }
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let done: Result<Callback, Error>? = lock.withLock {
                if let outcome { return outcome }
                waiter = continuation
                return nil
            }
            if let done { continuation.resume(with: done) }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    /// Reads `code`, `state` or `error` from the request line of a callback.
    static func parse(requestLine: String) -> Result<Callback, Error>? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let url = URLComponents(string: "http://localhost" + parts[1]),
              url.path == "/callback"
        else { return nil }
        let query = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        if let error = query["error"] { return .failure(UsageError.oauth(error)) }
        guard let code = query["code"], !code.isEmpty, let state = query["state"] else { return nil }
        return .success(Callback(code: code, state: state))
    }

    private func changed(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener.port?.rawValue ?? 0
            takeReady()?.resume(returning: port)
        case .failed(let error):
            takeReady()?.resume(throwing: error)
            finish(.failure(error))
        default:
            break
        }
    }

    private func takeReady() -> CheckedContinuation<UInt16, Error>? {
        lock.withLock {
            defer { ready = nil }
            return ready
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let line = request.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            guard let result = Self.parse(requestLine: line) else {
                // A favicon or any other path: not the callback.
                Self.respond(connection, status: "404 Not Found", location: nil)
                return
            }
            switch result {
            case .success:
                Self.respond(connection, status: "302 Found", location: Self.successURL)
            case .failure:
                Self.respond(connection, status: "400 Bad Request", location: nil)
            }
            self?.finish(result)
        }
    }

    private static func respond(_ connection: NWConnection, status: String, location: String?) {
        var head = "HTTP/1.1 \(status)\r\n"
        if let location { head += "Location: \(location)\r\n" }
        head += "Content-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<Callback, Error>) {
        let waiting: CheckedContinuation<Callback, Error>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(with: result)
        listener.cancel()
    }
}
