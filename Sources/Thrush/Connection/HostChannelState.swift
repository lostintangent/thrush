import Foundation
import ThrushCore

/// The session owns the host channel. A pane subscribes to changes in its screen while visible.
final class HostChannelState {
    typealias Open = @Sendable (Terminal.Size) async throws -> any TerminalTransport

    private let open: Open
    private var channel: (any TerminalTransport)?
    // Includes an in-flight resize. The terminal itself retains the last accepted grid.
    private var scheduledSize: Terminal.Size?
    private var reader: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var presentation: Presentation?

    init(open: @escaping Open) { self.open = open }

    /// A slow pane needs the latest screen. Terminal bytes never pass through this buffer.
    private final class Presentation {
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var resumed: Bool?
        var hasOutput = false
        var isReading = false
    }

    func attach(to worker: isolated TerminalWorker, userInitiated: Bool) -> Bool {
        if presentation == nil, worker.state == .active || worker.state == .connecting || worker.state == .closing {
            presentation = Presentation()
            if worker.state == .active {
                presentation?.resumed = true
                presentation?.hasOutput = true
                return false
            }
        }
        guard worker.beginAttachment(userInitiated: userInitiated) else { return false }
        presentation?.changes.continuation.finish()
        presentation = Presentation()
        worker.state = .connecting
        let stamp = worker.lifetime
        let size = worker.requestedSize
        // An indefinitely suspended host read or open must not retain the worker and its screen.
        reader = Task { [weak worker, open] in
            do {
                let channel = try await open(size)
                guard try await worker?.acceptHostChannel(channel, size: size, stamp: stamp) == true else {
                    // A cancelled factory can still deliver an open resource.
                    await Task { await channel.close() }.value
                    return
                }
                while !Task.isCancelled, let bytes = try await channel.read() {
                    try await worker?.receiveHostBytes(bytes, stamp: stamp)
                }
            } catch {
                // Failure and EOF both end this channel with its last confirmed screen.
            }
            await worker?.hostChannelEnded(stamp: stamp)
        }
        return true
    }

    func detach(from _: isolated TerminalWorker) {
        presentation?.changes.continuation.finish()
        presentation = nil
    }

    func nextEvent(in worker: isolated TerminalWorker) async throws -> TerminalWorker.Event {
        guard let view = presentation else { throw TerminalWorker.ConnectionError.inactiveAttachment }
        guard !view.isReading else { throw TerminalWorker.ConnectionError.concurrentRead }
        view.isReading = true
        defer { view.isReading = false }
        var changes = view.changes.stream.makeAsyncIterator()
        while true {
            try Task.checkCancellation()
            guard view === presentation else { throw CancellationError() }
            if let resumed = view.resumed {
                view.resumed = nil
                return .ready(resumed: resumed)
            }
            if view.hasOutput {
                view.hasOutput = false
                return .output
            }
            if worker.state == .ended { return .exit }
            guard await changes.next() != nil else { throw CancellationError() }
        }
    }

    fileprivate func opened(_ channel: any TerminalTransport, size: Terminal.Size,
                            stamp: UInt64, in worker: isolated TerminalWorker) async throws {
        self.channel = channel
        scheduledSize = size
        worker.terminal = Terminal(size: size, palette: worker.terminal.palette)
        worker.lastReceiptTime = nil
        await worker.publishMetadata(title: worker.terminal.title, hasEnded: false)
        guard worker.lifetime == stamp else { throw CancellationError() }
        // The pane can rotate while the channel is opening.
        while worker.terminal.size != worker.requestedSize {
            try await resizeIfNeeded(in: worker)
            guard worker.lifetime == stamp else { throw CancellationError() }
        }
        worker.state = .active
        worker.hasSeenReady = true
        presentation?.resumed = false
        presentation?.changes.continuation.yield()
    }

    fileprivate func received(_ bytes: Data, stamp: UInt64, in worker: isolated TerminalWorker) async throws {
        guard !bytes.isEmpty else {
            await Task.yield()
            return
        }
        worker.recordReceipt(of: bytes)
        let reply = worker.apply(bytes)
        presentation?.hasOutput = true
        presentation?.changes.continuation.yield()
        if !reply.isEmpty { try await write(.bytes(Data(reply)), in: worker) }
        guard worker.lifetime == stamp else { throw CancellationError() }
        await worker.publishMetadata(title: worker.terminal.title)
    }

    func send(_ input: Terminal.Input, in worker: isolated TerminalWorker,
              notify: (@Sendable () -> Void)?) async throws {
        guard worker.state == .active else { throw TerminalWorker.ConnectionError.inactiveAttachment }
        let bytes = worker.terminal.encode(input)
        if !bytes.isEmpty { try await write(.bytes(Data(bytes)), in: worker, notify: notify) }
    }

    func resize(in worker: isolated TerminalWorker) async throws {
        if worker.state == .active { try await resizeIfNeeded(in: worker) }
    }

    private func resizeIfNeeded(in worker: isolated TerminalWorker) async throws {
        let size = worker.requestedSize
        guard size != scheduledSize else { return }
        scheduledSize = size
        try await write(.resize(size), in: worker)
    }

    private enum Write { case bytes(Data), resize(Terminal.Size) }

    private func write(_ operation: Write, in worker: isolated TerminalWorker,
                       notify: (@Sendable () -> Void)? = nil) async throws {
        guard let channel else { throw TerminalWorker.ConnectionError.inactiveAttachment }
        let stamp = worker.lifetime
        let next = worker.orderWrite { worker in
            guard worker.lifetime == stamp else { throw CancellationError() }
            notify?()
            switch operation {
            case .bytes(let data): try await channel.write(data)
            case .resize(let size):
                try await channel.resize(to: size)
                guard worker.lifetime == stamp else { throw CancellationError() }
                worker.terminal.resize(to: size)
            }
        }
        do {
            try await next.value
            guard worker.lifetime == stamp else { throw CancellationError() }
        } catch {
            if worker.lifetime == stamp { await end(in: worker, mayRestart: true) }
            throw error
        }
    }

    func release(in worker: isolated TerminalWorker) async {
        if worker.state != .ended { await close(in: worker) }
    }

    func close(in worker: isolated TerminalWorker) async {
        await end(in: worker, mayRestart: false)
    }

    fileprivate func end(in worker: isolated TerminalWorker, mayRestart: Bool) async {
        if worker.state == .ended || worker.state == .closing {
            if !mayRestart { worker.exitedNaturally = false }
            await closing?.value
            return
        }
        // Invalidate queued writes before waking the host's blocked read or write.
        worker.lifetime &+= 1
        worker.exitedNaturally = mayRestart
        worker.state = .closing
        reader?.cancel()
        reader = nil
        let channel = self.channel
        self.channel = nil
        worker.lastWrite = nil
        // EOF arrives on the reader we just cancelled. Cleanup runs uncancelled, once per channel.
        let cleanup = Task {
            await channel?.close()
            await worker.publishMetadata(title: worker.terminal.title, hasEnded: true)
            worker.state = .ended
            closing = nil
            presentation?.changes.continuation.yield()
        }
        closing = cleanup
        await cleanup.value
    }
}

extension TerminalWorker {
    init(observer: TerminalSession.MetadataObserver, openTransport: @escaping HostChannelState.Open) {
        self.init(transport: .hostChannel(HostChannelState(open: openTransport)), size: nil,
                  palette: .default, state: .detached, observer: observer)
    }

    // The reader borrows the worker for each callback and releases it before its next read.
    fileprivate func acceptHostChannel(_ channel: any TerminalTransport, size: Terminal.Size, stamp: UInt64) async throws -> Bool {
        guard lifetime == stamp, state == .connecting, case .hostChannel(let host) = transport else { return false }
        try await host.opened(channel, size: size, stamp: stamp, in: self)
        return true
    }

    fileprivate func receiveHostBytes(_ bytes: Data, stamp: UInt64) async throws {
        guard lifetime == stamp, case .hostChannel(let host) = transport else { throw CancellationError() }
        try await host.received(bytes, stamp: stamp, in: self)
    }

    fileprivate func hostChannelEnded(stamp: UInt64) async {
        guard lifetime == stamp, case .hostChannel(let host) = transport else { return }
        await host.end(in: self, mayRestart: true)
    }
}
