import Foundation
import Network
import Testing

/// A loopback WebSocket peer for testing shell metadata and native attachment lifetimes.
@MainActor final class ShellTestPeer {
    private let listener: NWListener
    private var sockets: [NWConnection] = []
    var automaticallySendsReady = true
    var resumeNextAttachment = false
    private(set) var port: UInt16?
    private(set) var opens = 0
    private(set) var closes = 0
    private(set) var receivedText: [String] = []
    private(set) var receivedBinary: [String] = []

    init() throws {
        let options = NWParameters.tcp
        options.requiredInterfaceType = .loopback
        options.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        listener = try NWListener(using: options, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            MainActor.assumeIsolated { self?.port = self?.listener.port?.rawValue }
        }
        listener.newConnectionHandler = { [weak self] socket in
            MainActor.assumeIsolated { self?.accept(socket) }
        }
        listener.start(queue: .main)
    }

    private func accept(_ socket: NWConnection) {
        sockets.append(socket)
        socket.stateUpdateHandler = { [weak self, weak socket] state in
            guard case .ready = state, let socket else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.opens += 1
                if self.automaticallySendsReady {
                    let ready = #"{"type":"ready","resumed":\#(self.resumeNextAttachment)}"#
                    self.send(ready, opcode: .text, to: socket)
                }
                self.receive(socket)
            }
        }
        socket.start(queue: .main)
    }

    private func receive(_ socket: NWConnection) {
        socket.receiveMessage { [weak self] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ws = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if ws?.opcode == .text, let data { self.receivedText.append(String(decoding: data, as: UTF8.self)) }
                if ws?.opcode == .binary, let data { self.receivedBinary.append(String(decoding: data, as: UTF8.self)) }
                if ws?.opcode == .close || error != nil {
                    self.closes += 1
                    socket.cancel()
                } else {
                    self.receive(socket)
                }
            }
        }
    }

    func send(_ payload: String, opcode: NWProtocolWebSocket.Opcode) throws {
        let socket = try #require(sockets.last)
        send(payload, opcode: opcode, to: socket)
    }

    private func send(_ payload: String, opcode: NWProtocolWebSocket.Opcode, to socket: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "shell", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
        socket.send(content: Data(payload.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// Ends the latest attachment without a close code, as a lost network does.
    func drop() { sockets.last?.cancel() }

    func stop() {
        listener.cancel()
        sockets.forEach { $0.cancel() }
    }
}
