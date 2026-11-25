import Darwin
import Dispatch
import Foundation
import ThrushPTY

// All PTY events and ownership changes run on the server's serial queue.
final class PseudoTerminal: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private let fdSources = DispatchGroup()
    private let reader: DispatchSourceRead
    private let process: DispatchSourceProcess
    private var writer: DispatchSourceWrite?
    private var input = Data()
    private var closed = false
    private var eof = false
    private var buffer = [UInt8](repeating: 0, count: 32_768)
    var onOutput: (Data) -> Void = { _ in }
    var onExit: () -> Void = {}

    init(shell: String, directory: URL, environment: [String: String], request: TerminalRequest, queue: DispatchQueue, cleanup: DispatchGroup) throws {
        var child: pid_t = 0, master: Int32 = -1, device: dev_t = 0
        var entries = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { entries.forEach { free($0) } }
        guard let executable = Bundle.main.executablePath else { throw POSIXError(.ENOENT) }
        let error = thrush_spawn(executable, shell, directory.path, &entries, Int32(request.columns), Int32(request.rows), &child, &master, &device)
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        fd = master
        self.queue = queue
        reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        process = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        reader.setEventHandler { [weak self] in _ = self?.read() }
        cleanup.enter()
        fdSources.enter()
        reader.setCancelHandler { [fdSources] in fdSources.leave() }
        fdSources.notify(queue: .global()) { [master, child, device] in
            thrush_close(master, child, device)
            cleanup.leave()
        }
        process.setEventHandler { [weak self] in
            guard let self, !closed else { return }
            // Child exit can be delivered before the final PTY readability notification.
            var remaining = Int(thrush_available(fd))
            while remaining > 0 {
                let n = read(limit: remaining)
                if n <= 0 { break }
                remaining -= n
            }
            onExit()
        }
        reader.activate()
        process.activate()
    }

    private func read(limit: Int = .max) -> Int {
        guard !closed else { return 0 }
        var count: Int
        repeat { count = Darwin.read(fd, &buffer, min(buffer.count, limit)) } while count == -1 && errno == EINTR
        if count > 0 { onOutput(Data(buffer.prefix(count))); return count }
        if !eof && (count == 0 || (count == -1 && errno == EIO)) { eof = true; reader.suspend() }
        return 0
    }

    func resize(columns: Int, rows: Int) { thrush_resize(fd, Int32(columns), Int32(rows)) }

    func write(_ data: Data) -> Bool {
        guard !closed, input.count + data.count <= 1_048_576 else { return false }
        input.append(data)
        flush()
        return true
    }

    private func flush() {
        guard !closed else { return }
        while !input.isEmpty {
            let n = input.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 { input.removeFirst(n); continue }
            if n == -1 && errno == EINTR { continue }
            if n == -1 && errno == EAGAIN && writer == nil {
                let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                fdSources.enter()
                source.setCancelHandler { [fdSources] in fdSources.leave() }
                source.setEventHandler { [weak self] in self?.flush() }
                writer = source
                source.activate()
            }
            return
        }
        writer?.cancel()
        writer = nil
    }

    func stop() {
        guard !closed else { return }
        closed = true
        writer?.cancel()
        process.cancel()
        if eof { reader.resume() }
        reader.cancel()
    }
}
