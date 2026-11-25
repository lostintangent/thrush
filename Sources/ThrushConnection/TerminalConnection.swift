import Foundation
import QuartzCore
import Thrush

/// A host keeps one connection per shell tab, including while its view is backgrounded.
/// Pull one event at a time. A ready event replaces the grid and invalidates the view's row cache.
public actor TerminalConnection {
    /// Each event follows the preceding one on the same WebSocket. Binary output is already applied.
    public enum Event: Equatable, Sendable {
        case ready(resumed: Bool)
        case output
        case exit
    }

    /// A displaced tab remains idle until a person asks to reclaim it. Ended is terminal.
    public enum State: Equatable, Sendable {
        case connecting, replaying, active, detached, displaced, closing, ended
    }

    private enum ConnectionError: Error {
        case invalidEndpoint, unexpectedMessage, concurrentRead, inactiveAttachment
    }

    private struct ServerControl: Decodable {
        enum Kind: String, Decodable { case ready, exit }
        let type: Kind
        let resumed: Bool?
    }

    private struct ClientControl: Encodable {
        enum Kind: String, Encodable { case resize, close }
        let type: Kind
        var cols: Int?
        var rows: Int?
    }

    /// Only the convenience initializer owns a session. A host keeps ownership of its own session.
    private final class DemoSession: Sendable {
        let session = URLSession(configuration: .ephemeral)
        deinit { session.invalidateAndCancel() }
    }

    private let makeSocket: @Sendable (String, Terminal.Size) throws -> URLSessionWebSocketTask
    private let clientID: String
    private let onOutput: (@Sendable (Data) -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var requestedSize: Terminal.Size
    private var attachmentSize: Terminal.Size
    private var terminal: Terminal
    private var isReading = false
    private var lastWrite: Task<Void, Error>?

    public private(set) var state = State.connecting
    package private(set) var lastReceiptTime: CFTimeInterval?
    package private(set) var receivedBytes = 0
    package private(set) var appliedBytes = 0

    package init(baseURL: URL, clientID: String, size: Terminal.Size? = nil, palette: Terminal.Palette = .default,
                 onOutput: (@Sendable (Data) -> Void)? = nil) throws {
        guard var location = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              location.host != nil, location.query == nil, location.fragment == nil
        else { throw ConnectionError.invalidEndpoint }
        switch location.scheme {
        case "http", "ws": location.scheme = "ws"
        case "https", "wss": location.scheme = "wss"
        default: throw ConnectionError.invalidEndpoint
        }
        location.path = baseURL.appending(path: "socket").path
        let endpoint = location
        let owner = DemoSession()
        try self.init(clientID: clientID, size: size, palette: palette, onOutput: onOutput) { id, size in
            let url = try Self.url(for: endpoint, clientID: id, size: size)
            return owner.session.webSocketTask(with: url)
        }
    }

    /// Create a detached shell tab. A native view supplies its first measured size with
    /// sendResize(to:) before attaching. A headless caller can use the default 80 × 24.
    /// Return a fresh, suspended WebSocket task from the host's session on every attachment.
    public init(clientID: String, palette: Terminal.Palette = .default,
                makeSocket: @escaping @Sendable (String, Terminal.Size) throws -> URLSessionWebSocketTask) throws {
        try self.init(clientID: clientID, size: nil, palette: palette, onOutput: nil, makeSocket: makeSocket)
    }

    package init(clientID: String, size: Terminal.Size?, palette: Terminal.Palette = .default,
                 onOutput: (@Sendable (Data) -> Void)? = nil,
                 makeSocket: @escaping @Sendable (String, Terminal.Size) throws -> URLSessionWebSocketTask) throws {
        guard !clientID.isEmpty else { throw ConnectionError.invalidEndpoint }
        self.clientID = clientID
        self.onOutput = onOutput
        self.makeSocket = makeSocket
        let initialSize = size ?? .init(columns: 80, rows: 24)
        requestedSize = initialSize
        attachmentSize = initialSize
        terminal = Terminal(size: initialSize, palette: palette)
        if let size {
            let first = try makeSocket(clientID, size)
            socket = first
            first.resume()
        } else {
            state = .detached
        }
    }

    deinit { socket?.cancel(with: .goingAway, reason: nil) }

    /// Reattach on foreground return or after a transport error. Only a user's explicit input
    /// can reclaim a displaced client. A closed or exited shell needs a new connection.
    @discardableResult
    public func attach(userInitiated: Bool = false) throws -> Bool {
        guard state == .detached || (state == .displaced && userInitiated) else { return false }
        let next = try makeSocket(clientID, requestedSize)
        attachmentSize = requestedSize
        socket = next
        state = .connecting
        next.resume()
        return true
    }

    private static func url(for endpoint: URLComponents, clientID: String, size: Terminal.Size) throws -> URL {
        var location = endpoint
        location.queryItems = [
            URLQueryItem(name: "service", value: "terminal"),
            URLQueryItem(name: "clientId", value: clientID),
            URLQueryItem(name: "cols", value: String(size.columns)),
            URLQueryItem(name: "rows", value: String(size.rows)),
        ]
        // URLSearchParams on the server decodes an unescaped plus as a space.
        location.percentEncodedQuery = location.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = location.url else { throw ConnectionError.invalidEndpoint }
        return url
    }

    /// On resume, ready is followed by one binary frame containing the server's serialized
    /// terminal. Applying it restores the input modes before the connection accepts keystrokes.
    public func nextEvent() async throws -> Event {
        guard let current = socket, state != .closing else { throw ConnectionError.inactiveAttachment }
        guard !isReading else { throw ConnectionError.concurrentRead }
        isReading = true
        defer { if socket === current { isReading = false } }
        do {
            let message = try await current.receive()
            guard socket === current else { throw CancellationError() }
            switch message {
            case .data(let data):
                guard state == .active || state == .replaying || state == .closing else {
                    throw ConnectionError.unexpectedMessage
                }
                lastReceiptTime = CACurrentMediaTime()
                receivedBytes += data.count
                let reply = data.withUnsafeBytes { terminal.receive($0.bindMemory(to: UInt8.self)) }
                appliedBytes += data.count
                onOutput?(data)
                if !reply.isEmpty && state != .closing { try await write(.data(Data(reply)), to: current) }
                if state == .replaying { try await activate(current) }
                return .output
            case .string(let json):
                let control = try JSONDecoder().decode(ServerControl.self, from: Data(json.utf8))
                switch (control.type, state) {
                case (.ready, .connecting):
                    guard let resumed = control.resumed else { throw ConnectionError.unexpectedMessage }
                    terminal = Terminal(size: attachmentSize, palette: terminal.palette)
                    lastReceiptTime = nil
                    if resumed { state = .replaying } else { try await activate(current) }
                    return .ready(resumed: resumed)
                case (.exit, .active), (.exit, .closing):
                    if state != .closing { finish(current, as: .ended) }
                    return .exit
                default:
                    throw ConnectionError.unexpectedMessage
                }
            @unknown default:
                throw ConnectionError.unexpectedMessage
            }
        } catch {
            // A read waiting when closeShell sent its control may observe the peer's FIN
            // before the send completion. The closing writer owns teardown in that case.
            if socket === current && state != .closing { lost(current) }
            throw error
        }
    }

    package func text(inRow row: Int) -> String { terminal.text(inRow: row) }

    package func snapshot() -> Terminal.Snapshot { terminal.snapshot() }

    /// A value snapshot from the same serial owner that applies output and encodes keystrokes.
    /// Pass this to TerminalView.display on the main actor. Retain it only as long as the view needs it.
    public var currentTerminal: Terminal { terminal }

    /// Set the colors used for queries from the running program, including while the view is hidden.
    public func setPalette(_ palette: Terminal.Palette) { terminal.palette = palette }

    /// Input is scoped to the active socket. Never retain a key for an unknown future PTY.
    public func send(_ input: Terminal.Input) async throws {
        guard let current = socket, state == .active else { throw ConnectionError.inactiveAttachment }
        let bytes = terminal.encode(input)
        if !bytes.isEmpty { try await write(.data(Data(bytes)), to: current) }
    }

    /// A size change during attach is sent after ready and any replay at the URL's original size.
    public func sendResize(to size: Terminal.Size) async throws {
        requestedSize = size
        guard let current = socket, state == .active else { return }
        try await resizeIfNeeded(current)
    }

    private func activate(_ current: URLSessionWebSocketTask) async throws {
        state = .active
        try await resizeIfNeeded(current)
    }

    private func resizeIfNeeded(_ current: URLSessionWebSocketTask) async throws {
        guard terminal.size != requestedSize else { return }
        terminal.resize(to: requestedSize)
        try await writeControl(ClientControl(type: .resize, cols: requestedSize.columns, rows: requestedSize.rows),
                               to: current)
    }

    /// End the active PTY and release its socket. Ordinary dismissal uses detach().
    public func closeShell() async throws {
        guard let current = socket, state == .active else { throw ConnectionError.inactiveAttachment }
        state = .closing
        try await writeControl(ClientControl(type: .close), to: current)
        finish(current, as: .ended)
    }

    /// Background or dismissal releases the socket and allows Toy Box to retain its PTY.
    public func detach() {
        guard let current = socket, state != .closing else { return }
        lost(current)
    }

    private func lost(_ current: URLSessionWebSocketTask) {
        if current.closeCode.rawValue == 4000 {
            finish(current, as: .displaced)
        } else {
            finish(current, as: state == .closing ? .ended : .detached)
        }
    }

    private func finish(_ current: URLSessionWebSocketTask, as nextState: State) {
        guard socket === current else { return }
        socket = nil
        state = nextState
        isReading = false
        lastWrite = nil
        current.cancel(with: .normalClosure, reason: nil)
    }

    private func writeControl(_ control: ClientControl, to current: URLSessionWebSocketTask) async throws {
        let bytes = try JSONEncoder().encode(control)
        try await write(.string(String(decoding: bytes, as: UTF8.self)), to: current)
    }

    /// Actor methods can interleave at send and receive. Every queued write and its completion
    /// belong to the socket captured when the operation began.
    private func write(_ message: URLSessionWebSocketTask.Message, to current: URLSessionWebSocketTask) async throws {
        let previous = lastWrite
        let next = Task {
            try await previous?.value
            guard self.socket === current else { throw CancellationError() }
            try await current.send(message)
        }
        lastWrite = next
        do {
            try await next.value
            guard socket === current else { throw CancellationError() }
        } catch {
            if socket === current { lost(current) }
            throw error
        }
    }
}
