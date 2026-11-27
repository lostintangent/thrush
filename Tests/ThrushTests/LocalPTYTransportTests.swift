#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import Thrush

/// An app-supplied transport with a real PTY as the shell's standard input, output and error.
private actor LocalShellPTY: TerminalTransport {
    private let process = Process()
    private let master: FileHandle
    private(set) var waitingForOutput = false
    private var closed = false
    nonisolated let pid: Int32
    var isRunning: Bool { process.isRunning }

    init(size: Terminal.Size, script: String, arguments: [String] = []) throws {
        var window = winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.columns), ws_xpixel: 0, ws_ypixel: 0)
        var masterFD: Int32 = -1, slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, &window) == 0 else { throw Self.systemError() }
        master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        defer { try? slave.close() }

        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "thrush-test"] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "TERM": "vt100"]
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave
        try process.run()
        pid = process.processIdentifier
    }

    func read() async throws -> Data? {
        guard !closed else { return nil }
        waitingForOutput = true
        defer {
            waitingForOutput = false
            if closed { try? master.close() }
        }
        let fd = master.fileDescriptor
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try Self.readChunk(from: fd) })
            }
        }
    }

    // Task cancellation cannot wake this OS wait. Closing the shell releases its PTY slave.
    private static func readChunk(from fd: Int32) throws -> Data? {
        var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var ready: Int32
        repeat { ready = poll(&event, 1, 10_000) } while ready < 0 && errno == EINTR
        guard ready > 0 else { throw ready == 0 ? POSIXError(.ETIMEDOUT) : systemError() }
        var buffer = [UInt8](repeating: 0, count: 512)
        var count: Int
        repeat { count = Darwin.read(fd, &buffer, buffer.count) } while count < 0 && errno == EINTR
        if count == 0 || (count < 0 && errno == EIO) { return nil }
        guard count > 0 else { throw systemError() }
        return Data(buffer.prefix(count))
    }

    func write(_ bytes: Data) throws { try master.write(contentsOf: bytes) }

    func resize(to size: Terminal.Size) throws {
        var window = winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.columns), ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(master.fileDescriptor, TIOCSWINSZ, &window) == 0 else { throw Self.systemError() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if process.isRunning { process.terminate() }
        if !waitingForOutput { try? master.close() }
    }

    private static func systemError() -> POSIXError { POSIXError(.init(rawValue: errno) ?? .EIO) }
}

@MainActor private func waitForPTY(_ label: String, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        try #require(ContinuousClock.now < deadline, "Timed out waiting for \(label)")
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func localShellResizesAndContinuesWhileHidden() async throws {
    let gate = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: gate) }
    let opened = Mutex<[LocalShellPTY]>([])
    defer { Task { for shell in opened.withLock({ $0 }) { await shell.close() } } }
    let script = """
        set -e
        test -t 0 && test -t 1 && test -t 2 || exit 1
        stty -echo
        printf 'FIRST %s %s\\n' "$$" "$(stty size)"
        IFS= read -r line
        printf 'INPUT %s %s\\n' "$line" "$(stty size)"
        while test ! -f "$1"; do sleep 0.02; done
        printf 'HIDDEN %s\\n' "$$"
        IFS= read -r line
        printf 'FINAL %s %s\\n' "$$" "$line"
        """
    let session = TerminalSession(openTransport: { size in
        let shell = try LocalShellPTY(size: size, script: script, arguments: [gate.path])
        opened.withLock { $0.append(shell) }
        return shell
    })
    let actor = session.actor
    try await actor.sendResize(to: .init(columns: 43, rows: 8))
    try #require(await actor.show())
    try #require(try await actor.nextEvent() == .ready(resumed: false))
    let shell = try #require(opened.withLock { $0.first })

    let first = "FIRST \(shell.pid) 8 43"
    try await waitForPTY("the PTY's measured initial size") { await actor.text(inRow: 0) == first }
    try await actor.sendResize(to: .init(columns: 51, rows: 9))
    try await actor.send(.text("acorn"))
    try await actor.send(.key(.enter))
    try await waitForPTY("input and resized PTY") { await actor.text(inRow: 1) == "INPUT acorn 9 51" }

    await actor.hide()
    try Data().write(to: gate)
    try await waitForPTY("output produced while hidden") { await actor.text(inRow: 2) == "HIDDEN \(shell.pid)" }
    let showing = await session.show(userInitiated: false, theme: .dark)
    #expect(showing.state == .live)
    #expect(showing.screen?.rows[0].text == first)
    #expect(showing.screen?.rows[2].text == "HIDDEN \(shell.pid)")
    #expect(opened.withLock { $0.count } == 1)
    try await actor.send(.text("finish\r"))
    try await waitForPTY("shell EOF") { session.hasEnded }
    #expect(await actor.text(inRow: 3) == "FINAL \(shell.pid) finish")
}

@MainActor @Test(.timeLimit(.minutes(1))) func closingLocalShellInterruptsPendingRead() async throws {
    let opened = Mutex<LocalShellPTY?>(nil)
    defer { Task { await opened.withLock { $0 }?.close() } }
    let session = TerminalSession(openTransport: { size in
        let shell = try LocalShellPTY(size: size, script: "IFS= read -r line")
        opened.withLock { $0 = shell }
        return shell
    })
    try await session.actor.sendResize(to: .init(columns: 40, rows: 8))
    try #require(await session.actor.show())
    try #require(try await session.actor.nextEvent() == .ready(resumed: false))
    let shell = try #require(opened.withLock { $0 })
    try await waitForPTY("a pending read on the quiet PTY") { await shell.waitingForOutput }
    let closing = Task { try await session.close() }
    try await waitForPTY("the pending read to return") { await !shell.waitingForOutput }
    try await waitForPTY("the shell process to exit") { await !shell.isRunning }
    try await closing.value
    #expect(session.hasEnded)
}
#endif
