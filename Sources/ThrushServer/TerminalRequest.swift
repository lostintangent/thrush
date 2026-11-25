import Foundation
@preconcurrency import Network

struct TerminalRequest {
    let id: String
    let columns: Int
    let rows: Int

    static func valid(columns: Int, rows: Int) -> Bool {
        (2...512).contains(columns) && (1...256).contains(rows)
    }

    init?(_ header: String, port: NWEndpoint.Port) {
        var lines = header.components(separatedBy: "\r\n").makeIterator()
        let request = lines.next()?.split(separator: " ") ?? []
        guard request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1",
              request[1].hasPrefix("/socket?"), let url = URLComponents(string: String(request[1])),
              url.path == "/socket", url.fragment == nil else { return nil }
        var fields: [String: String] = [:]
        while let line = lines.next(), !line.isEmpty {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].lowercased()
            if key == "host" || key == "origin" {
                guard fields[key] == nil else { return nil }
                fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
            }
        }
        guard let host = fields["host"], ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host),
              fields["origin"] == nil || fields["origin"] == "http://" + host else { return nil }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard let value = item.value, query[item.name] == nil else { return nil }
            query[item.name] = value
        }
        guard query["service"] == "terminal", let id = query["clientId"], !id.isEmpty, id.utf8.count <= 128,
              let columns = Int(query["cols"] ?? ""), let rows = Int(query["rows"] ?? ""),
              Self.valid(columns: columns, rows: rows) else { return nil }
        self.id = id
        self.columns = columns
        self.rows = rows
    }
}

// Network's WebSocket layer handles the handshake and frames. Its server callback omits the
// request target, so inspect the bounded HTTP header beneath that layer, then pass it through.
final class Upgrade: NWProtocolFramerImplementation {
    static let label = "Thrush terminal request"
    static let definition = NWProtocolFramer.Definition(implementation: Upgrade.self)
    private static let lock = NSLock()
    private nonisolated(unsafe) static var pending: [NWEndpoint: (ObjectIdentifier, TerminalRequest)] = [:]

    static func take(_ remote: NWEndpoint) -> TerminalRequest? {
        lock.withLock { pending.removeValue(forKey: remote)?.1 }
    }

    required init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        framer.passThroughOutput()
        return .willMarkReady
    }
    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        var needed = 1
        var header: Data?
        let limit = 8192
        _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: limit) { bytes, complete in
            guard let bytes else { return 0 }
            let data = Data(bytes)
            if let end = data.range(of: Data("\r\n\r\n".utf8)) {
                header = data.prefix(upTo: end.upperBound)
            } else {
                needed = complete || data.count >= limit ? 0 : data.count + 1
            }
            return 0 // Leave the original bytes for Network's WebSocket handshake.
        }
        guard let header else {
            if needed == 0 { framer.markFailed(error: .posix(.EPROTO)) }
            return needed
        }
        guard let remote = framer.remote, case .hostPort(_, let port) = framer.local,
              let text = String(data: header, encoding: .utf8), let request = TerminalRequest(text, port: port) else {
            framer.markFailed(error: .posix(.EACCES))
            return 0
        }
        Self.lock.withLock { Self.pending[remote] = (ObjectIdentifier(self), request) }
        framer.markReady()
        _ = framer.deliverInputNoCopy(length: header.count, message: .init(definition: Self.definition), isComplete: false)
        framer.passThroughInput()
        return 0
    }
    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {}
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {
        guard let remote = framer.remote else { return }
        Self.lock.withLock {
            if Self.pending[remote]?.0 == ObjectIdentifier(self) { Self.pending.removeValue(forKey: remote) }
        }
    }
}
