import Foundation
import Thrush

/// A host owns one attachment at a time. Reuse its client ID on the next attachment.
/// Pull one event at a time so output is applied before another message is requested.
package actor TerminalConnection {
    package enum Event: Equatable, Sendable {
        case ready(resumed: Bool)
        case output
        case exit
    }

    private enum Phase {
        case attaching, active, closing, ended
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

    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private var terminal: Terminal
    private var phase = Phase.attaching
    private var isReading = false
    private var lastWrite: Task<Void, Error>?

    package init(baseURL: URL, clientID: String, size: Terminal.Size) throws {
        guard !clientID.isEmpty,
              var location = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              location.host != nil, location.query == nil, location.fragment == nil
        else { throw ConnectionError.invalidEndpoint }
        switch location.scheme {
        case "http", "ws": location.scheme = "ws"
        case "https", "wss": location.scheme = "wss"
        default: throw ConnectionError.invalidEndpoint
        }
        location.path = baseURL.appending(path: "socket").path
        location.queryItems = [
            URLQueryItem(name: "service", value: "terminal"),
            URLQueryItem(name: "clientId", value: clientID),
            URLQueryItem(name: "cols", value: String(size.columns)),
            URLQueryItem(name: "rows", value: String(size.rows)),
        ]
        // URLSearchParams on the server decodes an unescaped plus as a space.
        location.percentEncodedQuery = location.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = location.url else { throw ConnectionError.invalidEndpoint }
        session = URLSession(configuration: .ephemeral)
        socket = session.webSocketTask(with: url)
        terminal = Terminal(size: size)
        socket.resume()
    }

    deinit { session.invalidateAndCancel() }

    package func nextEvent() async throws -> Event {
        guard phase == .attaching || phase == .active else { throw ConnectionError.inactiveAttachment }
        guard !isReading else { throw ConnectionError.concurrentRead }
        isReading = true
        defer { isReading = false }
        do {
            let message = try await socket.receive()
            switch message {
            case .data(let data):
                guard phase == .active || phase == .closing else { throw ConnectionError.unexpectedMessage }
                let reply = terminal.receive(data)
                if !reply.isEmpty && phase == .active { try await write(.data(Data(reply))) }
                return .output
            case .string(let json):
                let control = try JSONDecoder().decode(ServerControl.self, from: Data(json.utf8))
                switch (control.type, phase) {
                case (.ready, .attaching):
                    guard let resumed = control.resumed else { throw ConnectionError.unexpectedMessage }
                    phase = .active
                    return .ready(resumed: resumed)
                case (.exit, .active), (.exit, .closing):
                    detach()
                    return .exit
                default:
                    throw ConnectionError.unexpectedMessage
                }
            @unknown default:
                throw ConnectionError.unexpectedMessage
            }
        } catch {
            detach()
            throw error
        }
    }

    package func text(inRow row: Int) -> String { terminal.text(inRow: row) }

    package func send(_ input: Terminal.Input) async throws {
        guard phase == .active else { throw ConnectionError.inactiveAttachment }
        let bytes = terminal.encode(input)
        if !bytes.isEmpty { try await write(.data(Data(bytes))) }
    }

    /// Sends the protocol's resize control. Applying grid reflow belongs to the core resize milestone.
    package func sendResize(to size: Terminal.Size) async throws {
        guard phase == .active else { throw ConnectionError.inactiveAttachment }
        try await writeControl(ClientControl(type: .resize, cols: size.columns, rows: size.rows))
    }

    package func closeShell() async throws {
        guard phase == .active else { throw ConnectionError.inactiveAttachment }
        phase = .closing
        try await writeControl(ClientControl(type: .close))
        detach()
    }

    /// Releasing this socket alone lets the server retain its PTY for a later attachment.
    package func detach() {
        guard phase != .ended else { return }
        phase = .ended
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func writeControl(_ control: ClientControl) async throws {
        let bytes = try JSONEncoder().encode(control)
        try await write(.string(String(decoding: bytes, as: UTF8.self)))
    }

    /// Actor methods can interleave while URLSession is sending. Chain writes before suspending.
    private func write(_ message: URLSessionWebSocketTask.Message) async throws {
        let previous = lastWrite
        let next = Task { [socket] in
            try await previous?.value
            try await socket.send(message)
        }
        lastWrite = next
        do {
            try await next.value
        } catch {
            detach()
            throw error
        }
    }
}
