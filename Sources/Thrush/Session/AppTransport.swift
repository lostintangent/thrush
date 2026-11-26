import Foundation
import ThrushCore

/// Drives the transport supplied by the app. Its view subscribes to screen changes while visible.
final class AppTransport {
    typealias Open = @Sendable (Terminal.Size) async throws -> any TerminalTransport

    private let open: Open
    private var transport: (any TerminalTransport)?
    // Includes an in-flight resize. The terminal itself retains the last accepted grid.
    private var scheduledSize: Terminal.Size?
    private var reader: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var subscription: Subscription?

    init(open: @escaping Open) { self.open = open }

    /// A slow view needs the latest screen. Terminal bytes never pass through this buffer.
    private final class Subscription {
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var firstEvent: SessionActor.Event?
        var hasOutput = false
        var isReading = false
    }

    func show(in session: isolated SessionActor) -> Bool {
        if subscription == nil, session.state == .active || session.state == .connecting || session.state == .closing {
            subscription = Subscription()
            if session.state == .active {
                subscription?.firstEvent = .screen
                return false
            }
        }
        guard session.beginOpening() else { return false }
        subscription?.changes.continuation.finish()
        subscription = Subscription()
        session.state = .connecting
        let stamp = session.lifetime
        let size = session.requestedSize
        // A suspended read or open must not retain the session and its screen.
        reader = Task { [weak session, open] in
            do {
                let transport = try await open(size)
                guard try await session?.acceptAppTransport(transport, size: size, stamp: stamp) == true else {
                    // A cancelled factory can still deliver an open resource.
                    await Task { await transport.close() }.value
                    return
                }
                while !Task.isCancelled, let bytes = try await transport.read() {
                    try await session?.receiveAppBytes(bytes, stamp: stamp)
                }
            } catch {
                // Failure and EOF both end this transport with its last confirmed screen.
            }
            await session?.appTransportEnded(stamp: stamp)
        }
        return true
    }

    func hide(in _: isolated SessionActor) {
        subscription?.changes.continuation.finish()
        subscription = nil
    }

    func nextEvent(in session: isolated SessionActor) async throws -> SessionActor.Event {
        guard let view = subscription else { throw SessionActor.TransportError.inactiveTransport }
        guard !view.isReading else { throw SessionActor.TransportError.concurrentRead }
        view.isReading = true
        defer { view.isReading = false }
        var changes = view.changes.stream.makeAsyncIterator()
        while true {
            try Task.checkCancellation()
            guard view === subscription else { throw CancellationError() }
            if let event = view.firstEvent {
                view.firstEvent = nil
                return event
            }
            if view.hasOutput {
                view.hasOutput = false
                return .output
            }
            if session.state == .ended { return .exit }
            guard await changes.next() != nil else { throw CancellationError() }
        }
    }

    fileprivate func opened(_ transport: any TerminalTransport, size: Terminal.Size,
                            stamp: UInt64, in session: isolated SessionActor) async throws {
        self.transport = transport
        scheduledSize = size
        session.resetTerminal(size: size)
        session.lastReceiptTime = nil
        await session.publishMetadata(title: session.terminal.title, hasEnded: false)
        guard session.lifetime == stamp else { throw CancellationError() }
        // The view can rotate while the transport is opening.
        while session.terminal.size != session.requestedSize {
            try await resizeIfNeeded(in: session)
            guard session.lifetime == stamp else { throw CancellationError() }
        }
        session.state = .active
        session.hasSeenReady = true
        subscription?.firstEvent = .ready(resumed: false)
        subscription?.changes.continuation.yield()
    }

    fileprivate func received(_ bytes: Data, stamp: UInt64, in session: isolated SessionActor) async throws {
        guard !bytes.isEmpty else {
            await Task.yield()
            return
        }
        session.recordReceipt(of: bytes)
        let reply = session.apply(bytes)
        subscription?.hasOutput = true
        subscription?.changes.continuation.yield()
        if !reply.isEmpty { try await write(.bytes(Data(reply)), in: session) }
        guard session.lifetime == stamp else { throw CancellationError() }
        await session.publishMetadata(title: session.terminal.title)
    }

    func send(_ input: Terminal.Input, in session: isolated SessionActor,
              notify: (@Sendable () -> Void)?) async throws {
        guard session.state == .active else { throw SessionActor.TransportError.inactiveTransport }
        let bytes = session.terminal.encode(input)
        if !bytes.isEmpty { try await write(.bytes(Data(bytes)), in: session, notify: notify) }
    }

    func resize(in session: isolated SessionActor) async throws {
        if session.state == .active { try await resizeIfNeeded(in: session) }
    }

    private func resizeIfNeeded(in session: isolated SessionActor) async throws {
        let size = session.requestedSize
        guard size != scheduledSize else { return }
        scheduledSize = size
        try await write(.resize(size), in: session)
    }

    private enum Write { case bytes(Data), resize(Terminal.Size) }

    private func write(_ operation: Write, in session: isolated SessionActor,
                       notify: (@Sendable () -> Void)? = nil) async throws {
        guard let transport else { throw SessionActor.TransportError.inactiveTransport }
        let stamp = session.lifetime
        let next = session.orderWrite { session in
            guard session.lifetime == stamp else { throw CancellationError() }
            notify?()
            switch operation {
            case .bytes(let data): try await transport.write(data)
            case .resize(let size):
                try await transport.resize(to: size)
                guard session.lifetime == stamp else { throw CancellationError() }
                session.terminal.resize(to: size)
            }
        }
        do {
            try await next.value
            guard session.lifetime == stamp else { throw CancellationError() }
        } catch {
            if session.lifetime == stamp { await close(in: session) }
            throw error
        }
    }

    func close(in session: isolated SessionActor) async {
        if session.state == .ended || session.state == .closing {
            await closing?.value
            return
        }
        // Invalidate queued writes before waking a blocked read or write.
        session.lifetime &+= 1
        session.state = .closing
        reader?.cancel()
        reader = nil
        let transport = self.transport
        self.transport = nil
        session.lastWrite = nil
        // EOF arrives on the reader we just cancelled. Cleanup runs uncancelled, once per transport.
        let cleanup = Task {
            await transport?.close()
            await session.publishMetadata(title: session.terminal.title, hasEnded: true)
            session.state = .ended
            closing = nil
            subscription?.changes.continuation.yield()
        }
        closing = cleanup
        await cleanup.value
    }
}

extension SessionActor {
    init(observer: TerminalSession.MetadataObserver, openTransport: @escaping AppTransport.Open) {
        self.init(transport: .app(AppTransport(open: openTransport)), size: nil,
                  palette: .default, state: .idle, observer: observer)
    }

    // The reader borrows the session for each callback and releases it before its next read.
    fileprivate func acceptAppTransport(_ transport: any TerminalTransport, size: Terminal.Size, stamp: UInt64) async throws -> Bool {
        guard lifetime == stamp, state == .connecting, case .app(let app) = self.transport else { return false }
        try await app.opened(transport, size: size, stamp: stamp, in: self)
        return true
    }

    fileprivate func receiveAppBytes(_ bytes: Data, stamp: UInt64) async throws {
        guard lifetime == stamp, case .app(let app) = transport else { throw CancellationError() }
        try await app.received(bytes, stamp: stamp, in: self)
    }

    fileprivate func appTransportEnded(stamp: UInt64) async {
        guard lifetime == stamp, case .app(let app) = transport else { return }
        await app.close(in: self)
    }
}
