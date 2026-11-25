import Foundation
import QuartzCore
import ThrushCore

/// The channel belongs to the session. The pane subscribes only to changes in its screen.
final class StreamTransport {
    typealias Open = @Sendable (Terminal.Size) async throws -> any TerminalTransport

    let open: Open
    var channel: (any TerminalTransport)?
    var scheduledSize: Terminal.Size?
    var reader: Task<Void, Never>?
    var closing: Task<Void, Never>?
    var presentation: Presentation?

    init(open: @escaping Open) { self.open = open }

    /// A slow or hidden pane needs the latest screen. Bytes never pass through this buffer.
    final class Presentation {
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var resumed: Bool?
        var hasOutput = false
        var isReading = false
    }

    func observe() { presentation = Presentation() }

    func stopObserving() {
        presentation?.changes.continuation.finish()
        presentation = nil
    }
}

extension TerminalWorker {
    func startStream(_ stream: StreamTransport) {
        let stamp = lifetime
        let size = requestedSize
        stream.stopObserving()
        stream.observe()
        state = .connecting
        stream.reader = Task { [weak self, open = stream.open] in
            do {
                let channel = try await open(size)
                // The factory may have ignored cancellation while opening. Even then,
                // exactly one owner gets the channel and releases it.
                guard await self?.installStream(channel, size: size, stamp: stamp) == true else {
                    await Task { await channel.close() }.value
                    return
                }
                try await self?.activateStream(stamp: stamp)
                while !Task.isCancelled, let bytes = try await channel.read() {
                    try await self?.applyStream(bytes, stamp: stamp)
                }
            } catch {
                // A raw channel has no reattach handshake. Keep the last confirmed screen.
            }
            await self?.finishStream(stamp: stamp)
        }
    }

    private func installStream(_ channel: any TerminalTransport, size: Terminal.Size, stamp: UInt64) -> Bool {
        guard lifetime == stamp, state == .connecting, let stream else { return false }
        stream.channel = channel
        stream.scheduledSize = size
        terminal = Terminal(size: size, palette: terminal.palette)
        lastReceiptTime = nil
        return true
    }

    private func activateStream(stamp: UInt64) async throws {
        guard let stream, lifetime == stamp else { throw CancellationError() }
        await publishMetadata(title: terminal.title, hasEnded: false)
        guard lifetime == stamp else { throw CancellationError() }
        // The pane can rotate while a channel is opening.
        while terminal.size != requestedSize {
            try await resizeStream(stream)
            guard lifetime == stamp else { throw CancellationError() }
        }
        state = .active
        hasSeenReady = true
        stream.presentation?.resumed = false
        stream.presentation?.changes.continuation.yield()
    }

    private func applyStream(_ bytes: Data, stamp: UInt64) async throws {
        guard let stream, lifetime == stamp else { throw CancellationError() }
        guard !bytes.isEmpty else {
            await Task.yield()
            return
        }
        lastReceiptTime = CACurrentMediaTime()
        receivedBytes += bytes.count
        let reply = terminal.receive(Span(viewing: bytes.bytes))
        appliedBytes += bytes.count
        stream.presentation?.hasOutput = true
        stream.presentation?.changes.continuation.yield()
        if !reply.isEmpty { try await sendToStream(stream, .write(Data(reply))) }
        guard lifetime == stamp else { throw CancellationError() }
        await publishMetadata(title: terminal.title)
    }

    func nextStreamEvent(_ stream: StreamTransport) async throws -> Event {
        guard let view = stream.presentation else { throw ConnectionError.inactiveAttachment }
        guard !view.isReading else { throw ConnectionError.concurrentRead }
        view.isReading = true
        defer { view.isReading = false }
        var changes = view.changes.stream.makeAsyncIterator()
        while true {
            try Task.checkCancellation()
            guard view === stream.presentation else { throw CancellationError() }
            if let resumed = view.resumed {
                view.resumed = nil
                return .ready(resumed: resumed)
            }
            if view.hasOutput { view.hasOutput = false; return .output }
            if state == .ended { return .exit }
            guard await changes.next() != nil else { throw CancellationError() }
        }
    }

    enum StreamWrite {
        case write(Data)
        case resize(Terminal.Size)
    }

    func resizeStream(_ stream: StreamTransport) async throws {
        guard requestedSize != stream.scheduledSize else { return }
        stream.scheduledSize = requestedSize
        try await sendToStream(stream, .resize(requestedSize))
    }

    func sendToStream(_ stream: StreamTransport, _ operation: StreamWrite,
                      notify: (@Sendable () -> Void)? = nil) async throws {
        guard let channel = stream.channel else { throw ConnectionError.inactiveAttachment }
        let stamp = lifetime
        let next = orderWrite { worker in
            guard worker.lifetime == stamp else { throw CancellationError() }
            notify?()
            switch operation {
            case .write(let data): try await channel.write(data)
            case .resize(let size):
                try await channel.resize(to: size)
                guard worker.lifetime == stamp else { throw CancellationError() }
                // An unsuccessful resize leaves the last confirmed screen intact.
                worker.terminal.resize(to: size)
            }
        }
        do {
            try await next.value
            guard lifetime == stamp else { throw CancellationError() }
        } catch {
            await finishStream(stamp: stamp)
            throw error
        }
    }

    private func finishStream(stamp: UInt64) async {
        guard lifetime == stamp, let stream else { return }
        await endStream(stream, mayRestart: true)
    }

    func endStream(_ stream: StreamTransport, mayRestart: Bool) async {
        if state == .ended || state == .closing {
            if !mayRestart { exitedNaturally = false }
            await stream.closing?.value
            return
        }
        // Invalidate queued writes before waking the channel's blocked read or write.
        lifetime &+= 1
        exitedNaturally = mayRestart
        state = .closing
        stream.reader?.cancel()
        stream.reader = nil
        let channel = stream.channel
        stream.channel = nil
        lastWrite = nil

        // EOF arrives on the reader task we just cancelled. Give the host an
        // uncancelled cleanup task, also shared by simultaneous close requests.
        let cleanup = Task {
            await channel?.close()
            await publishMetadata(title: terminal.title, hasEnded: true)
            state = .ended
            stream.closing = nil
            stream.presentation?.changes.continuation.yield()
        }
        stream.closing = cleanup
        await cleanup.value
    }
}
