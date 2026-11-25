import Darwin
import Foundation
import ThrushCore
@preconcurrency import Network

private typealias WS = NWProtocolWebSocket
private struct Control: Decodable { let type: String; let cols, rows: Int? }

private final class Shell: @unchecked Sendable {
    let id: String
    let pty: PseudoTerminal
    var terminal: Terminal
    var peer: Peer?
    var behind = false
    var orphan: DispatchWorkItem?

    init(_ request: TerminalRequest, _ pty: PseudoTerminal) {
        id = request.id
        self.pty = pty
        terminal = Terminal(size: .init(columns: request.columns, rows: request.rows))
    }

    func resize(_ columns: Int, _ rows: Int) {
        terminal.resize(to: .init(columns: columns, rows: rows))
        pty.resize(columns: columns, rows: rows)
    }

    func restore(on peer: Peer) {
        let snapshot = Data(terminal.replayBytes())
        guard snapshot.count <= 64 * 1024 * 1024 else {
            peer.close(.protocolCode(.messageTooBig))
            return
        }
        behind = false
        peer.send(.text, Data(#"{"type":"ready","resumed":true}"#.utf8))
        peer.send(.binary, snapshot)
    }

    func output(_ bytes: Data) {
        let replies = terminal.receive(Span(viewing: bytes.bytes))
        if let peer, !peer.closing, !behind, peer.pendingFrames < 256, peer.queuedLiveBytes + bytes.count <= 1_048_576 {
            peer.send(.binary, bytes, live: true)
        } else {
            behind = peer != nil
            if !replies.isEmpty { _ = pty.write(Data(replies)) }
        }
    }
}

private final class Peer: @unchecked Sendable {
    let connection: NWConnection
    weak var shell: Shell?
    var queuedLiveBytes = 0
    var pendingFrames = 0
    var closing = false

    init(_ connection: NWConnection) { self.connection = connection }

    func send(_ opcode: WS.Opcode, _ data: Data, live: Bool = false, closeCode: WS.CloseCode? = nil) {
        guard !closing || opcode == .close else { return }
        let metadata = WS.Metadata(opcode: opcode)
        if let closeCode { metadata.closeCode = closeCode }
        let context = NWConnection.ContentContext(identifier: "terminal", isFinal: opcode == .close, metadata: [metadata])
        // A serialized snapshot may be larger than the live budget. Bound the live frames behind it separately.
        let liveBytes = live ? data.count : 0
        queuedLiveBytes += liveBytes
        pendingFrames += 1
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            queuedLiveBytes -= liveBytes
            pendingFrames -= 1
            if error != nil || opcode == .close { connection.cancel(); return }
            if pendingFrames == 0, !closing, let shell, shell.peer === self, shell.behind { shell.restore(on: self) }
        })
    }

    func close(_ code: WS.CloseCode) {
        guard !closing else { return }
        closing = true
        send(.close, Data(), closeCode: code)
    }
}

private final class Server: @unchecked Sendable {
    let queue = DispatchQueue(label: "thrush.pty-server")
    let done = DispatchSemaphore(value: 0)
    let cleanup = DispatchGroup()
    let listener: NWListener
    let shell: String
    let directory: URL
    let environment: [String: String]
    var failure: NWError?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var shells: [String: Shell] = [:]
    private var signals: [DispatchSourceSignal] = []

    init(port: UInt16, shell: String, directory: URL, environment: [String: String]) throws {
        self.shell = shell
        self.directory = directory
        self.environment = environment
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let ws = WS.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 1_048_576
        params.defaultProtocolStack.applicationProtocols = [ws, NWProtocolFramer.Options(definition: Upgrade.definition)]
        listener = try NWListener(using: params)
    }

    func run() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.stop() }
            signals.append(source)
            source.activate()
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = listener.port {
                    FileHandle.standardOutput.write(Data("Listening on: http://127.0.0.1:\(port)/\n".utf8))
                }
            case .failed(let error): failure = error; stop()
            default: break
            }
        }
        listener.start(queue: queue)
        done.wait()
        cleanup.wait()
    }

    private func stop() {
        listener.cancel()
        signals.forEach { $0.cancel() }
        peers.values.forEach { $0.connection.cancel() }
        shells.values.forEach { $0.orphan?.cancel(); $0.pty.stop() }
        done.signal()
    }

    private func accept(_ connection: NWConnection) {
        guard peers.count < 32 else { connection.cancel(); return }
        let peer = Peer(connection)
        peers[ObjectIdentifier(peer)] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .ready:
                guard let request = Upgrade.take(peer.connection.endpoint) else { peer.connection.cancel(); return }
                attach(peer, request)
            case .failed: peer.connection.cancel(); disconnect(peer)
            case .cancelled: disconnect(peer)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak peer] in
            if let peer, peer.shell == nil, !peer.closing { peer.connection.cancel() }
        }
    }

    private func attach(_ peer: Peer, _ request: TerminalRequest) {
        let session: Shell
        if let existing = shells[request.id] {
            session = existing
            session.orphan?.cancel()
            session.orphan = nil
            session.peer?.close(.applicationCode(4000))
            session.peer = peer
            session.resize(request.columns, request.rows)
            session.restore(on: peer)
        } else {
            guard shells.count < 16 else { peer.close(.protocolCode(.policyViolation)); return }
            do {
                let pty = try PseudoTerminal(shell: shell, directory: directory, environment: environment, request: request, queue: queue, cleanup: cleanup)
                session = Shell(request, pty)
            } catch {
                peer.close(.protocolCode(.internalServerError))
                return
            }
            shells[session.id] = session
            session.peer = peer
            session.pty.onOutput = { [weak session] in session?.output($0) }
            session.pty.onExit = { [weak self, weak session] in
                if let session { self?.finish(session, natural: true) }
            }
            peer.send(.text, Data(#"{"type":"ready","resumed":false}"#.utf8))
        }
        peer.shell = session
        read(peer)
    }

    private func read(_ peer: Peer) {
        peer.connection.receiveMessage { [weak self, weak peer] data, context, _, error in
            guard let self, let peer, !peer.closing, let session = peer.shell, session.peer === peer else { return }
            guard error == nil, let metadata = context?.protocolMetadata(definition: WS.definition) as? WS.Metadata else {
                peer.connection.cancel(); return
            }
            switch metadata.opcode {
            case .binary:
                if let data, !session.pty.write(data) { peer.close(.protocolCode(.messageTooBig)); return }
            case .text:
                guard let data, let command = try? JSONDecoder().decode(Control.self, from: data) else {
                    peer.close(.protocolCode(.protocolError)); return
                }
                if command.type == "close" { finish(session, natural: false); return }
                guard command.type == "resize", let cols = command.cols, let rows = command.rows,
                      TerminalRequest.valid(columns: cols, rows: rows) else { peer.close(.protocolCode(.protocolError)); return }
                session.resize(cols, rows)
            case .close: peer.close(.protocolCode(.normalClosure)); return
            case .ping, .pong: break
            default: peer.close(.protocolCode(.protocolError)); return
            }
            read(peer)
        }
    }

    private func disconnect(_ peer: Peer) {
        guard peers.removeValue(forKey: ObjectIdentifier(peer)) != nil,
              let session = peer.shell, session.peer === peer else { return }
        session.peer = nil
        let orphan = DispatchWorkItem { [weak self, weak session] in
            if let session, session.peer == nil { self?.finish(session, natural: false) }
        }
        session.orphan = orphan
        queue.asyncAfter(deadline: .now() + 30, execute: orphan)
    }

    private func finish(_ session: Shell, natural: Bool) {
        guard shells[session.id] === session else { return }
        shells.removeValue(forKey: session.id)
        session.orphan?.cancel()
        session.pty.stop()
        if let peer = session.peer {
            if natural {
                if session.behind { session.restore(on: peer) }
                peer.send(.text, Data(#"{"type":"exit"}"#.utf8))
            }
            peer.close(.protocolCode(.normalClosure))
        }
        session.peer = nil
    }
}

func startServer(port: UInt16, shell: String, directory: URL, environment: [String: String]) throws {
    let server = try Server(port: port, shell: shell, directory: directory, environment: environment)
    server.run()
    if let error = server.failure { throw error }
}
