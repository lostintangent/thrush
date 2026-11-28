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
    var attachment: Attachment?
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

    func restore(on attachment: Attachment) {
        let snapshot = Data(terminal.replayBytes())
        guard snapshot.count <= 64 * 1024 * 1024 else {
            attachment.close(.protocolCode(.messageTooBig))
            return
        }
        behind = false
        attachment.send(.text, Data(#"{"type":"ready","resumed":true}"#.utf8))
        attachment.send(.binary, snapshot)
    }

    func output(_ bytes: Data) {
        let reply = terminal.write(Span(viewing: bytes.bytes))
        if let attachment, !attachment.closing, !behind, attachment.pendingFrames < 256, attachment.queuedLiveBytes + bytes.count <= 1_048_576 {
            attachment.send(.binary, bytes, live: true)
        } else {
            behind = attachment != nil
            if !reply.isEmpty { _ = pty.write(Data(reply)) }
        }
    }
}

private final class Attachment: @unchecked Sendable {
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
            if pendingFrames == 0, !closing, let shell, shell.attachment === self, shell.behind { shell.restore(on: self) }
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
    let shellPath: String
    let directory: URL
    let environment: [String: String]
    var failure: NWError?
    private var attachments: [ObjectIdentifier: Attachment] = [:]
    private var shells: [String: Shell] = [:]
    private var signals: [DispatchSourceSignal] = []

    init(port: UInt16, shellPath: String, directory: URL, environment: [String: String]) throws {
        self.shellPath = shellPath
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
        attachments.values.forEach { $0.connection.cancel() }
        shells.values.forEach { $0.orphan?.cancel(); $0.pty.stop() }
        done.signal()
    }

    private func accept(_ connection: NWConnection) {
        guard attachments.count < 32 else { connection.cancel(); return }
        let attachment = Attachment(connection)
        attachments[ObjectIdentifier(attachment)] = attachment
        connection.stateUpdateHandler = { [weak self, weak attachment] state in
            guard let self, let attachment else { return }
            switch state {
            case .ready:
                guard let request = Upgrade.take(attachment.connection.endpoint) else { attachment.connection.cancel(); return }
                attach(attachment, request)
            case .failed: attachment.connection.cancel(); disconnect(attachment)
            case .cancelled: disconnect(attachment)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak attachment] in
            if let attachment, attachment.shell == nil, !attachment.closing { attachment.connection.cancel() }
        }
    }

    private func attach(_ attachment: Attachment, _ request: TerminalRequest) {
        let shell: Shell
        if let existing = shells[request.id] {
            shell = existing
            shell.orphan?.cancel()
            shell.orphan = nil
            shell.attachment?.close(.applicationCode(4000))
            shell.attachment = attachment
            shell.resize(request.columns, request.rows)
            shell.restore(on: attachment)
        } else {
            guard shells.count < 16 else { attachment.close(.protocolCode(.policyViolation)); return }
            do {
                let pty = try PseudoTerminal(shell: shellPath, directory: directory, environment: environment, request: request, queue: queue, cleanup: cleanup)
                shell = Shell(request, pty)
            } catch {
                attachment.close(.protocolCode(.internalServerError))
                return
            }
            shells[shell.id] = shell
            shell.attachment = attachment
            shell.pty.onOutput = { [weak shell] in shell?.output($0) }
            shell.pty.onExit = { [weak self, weak shell] in
                if let shell { self?.finish(shell, natural: true) }
            }
            attachment.send(.text, Data(#"{"type":"ready","resumed":false}"#.utf8))
        }
        attachment.shell = shell
        read(attachment)
    }

    private func read(_ attachment: Attachment) {
        attachment.connection.receiveMessage { [weak self, weak attachment] data, context, _, error in
            guard let self, let attachment, !attachment.closing, let shell = attachment.shell, shell.attachment === attachment else { return }
            guard error == nil, let metadata = context?.protocolMetadata(definition: WS.definition) as? WS.Metadata else {
                attachment.connection.cancel(); return
            }
            switch metadata.opcode {
            case .binary:
                if let data, !shell.pty.write(data) { attachment.close(.protocolCode(.messageTooBig)); return }
            case .text:
                guard let data, let command = try? JSONDecoder().decode(Control.self, from: data) else {
                    attachment.close(.protocolCode(.protocolError)); return
                }
                if command.type == "close" { finish(shell, natural: false); return }
                guard command.type == "resize", let cols = command.cols, let rows = command.rows,
                      TerminalRequest.valid(columns: cols, rows: rows) else { attachment.close(.protocolCode(.protocolError)); return }
                shell.resize(cols, rows)
            case .close: attachment.close(.protocolCode(.normalClosure)); return
            case .ping, .pong: break
            default: attachment.close(.protocolCode(.protocolError)); return
            }
            read(attachment)
        }
    }

    private func disconnect(_ attachment: Attachment) {
        guard attachments.removeValue(forKey: ObjectIdentifier(attachment)) != nil,
              let shell = attachment.shell, shell.attachment === attachment else { return }
        shell.attachment = nil
        let orphan = DispatchWorkItem { [weak self, weak shell] in
            if let shell, shell.attachment == nil { self?.finish(shell, natural: false) }
        }
        shell.orphan = orphan
        queue.asyncAfter(deadline: .now() + 30, execute: orphan)
    }

    private func finish(_ shell: Shell, natural: Bool) {
        guard shells[shell.id] === shell else { return }
        shells.removeValue(forKey: shell.id)
        shell.orphan?.cancel()
        shell.pty.stop()
        if let attachment = shell.attachment {
            if natural {
                if shell.behind { shell.restore(on: attachment) }
                attachment.send(.text, Data(#"{"type":"exit"}"#.utf8))
            }
            attachment.close(.protocolCode(.normalClosure))
        }
        shell.attachment = nil
    }
}

func startServer(port: UInt16, shell: String, directory: URL, environment: [String: String]) throws {
    let server = try Server(port: port, shellPath: shell, directory: directory, environment: environment)
    server.run()
    if let error = server.failure { throw error }
}
