import Darwin
import Dispatch
import Foundation

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
        let (child, master, device) = try Self.spawn(shell: shell, directory: directory, environment: environment,
                                                     size: Self.size(columns: request.columns, rows: request.rows))
        fd = master
        self.queue = queue
        reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        process = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        reader.setEventHandler { [weak self] in _ = self?.read() }
        cleanup.enter()
        fdSources.enter()
        reader.setCancelHandler { [fdSources] in fdSources.leave() }
        fdSources.notify(queue: .global()) {
            Self.endJobs(on: device, of: child)
            close(master) // An exiting child may itself be waiting for the PTY to close.
            kill(-child, SIGKILL)
            kill(child, SIGKILL)
            while waitpid(child, nil, 0) == -1 && errno == EINTR {}
            cleanup.leave()
        }
        process.setEventHandler { [weak self] in
            guard let self, !closed else { return }
            // Child exit can be delivered before the final PTY readability notification.
            while read() > 0 {}
            onExit()
        }
        reader.activate()
        process.activate()
    }

    private func read() -> Int {
        guard !closed else { return 0 }
        var count: Int
        repeat { count = Darwin.read(fd, &buffer, buffer.count) } while count == -1 && errno == EINTR
        if count > 0 { onOutput(Data(buffer.prefix(count))); return count }
        if !eof && (count == 0 || (count == -1 && errno == EIO)) { eof = true; reader.suspend() }
        return 0
    }

    func resize(columns: Int, rows: Int) {
        var size = Self.size(columns: columns, rows: rows)
        _ = ioctl(fd, TIOCSWINSZ, &size)
    }

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

    private static func size(columns: Int, rows: Int) -> winsize {
        winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
    }

    /// Starts this executable as the shell's supervisor, leading a new session with the PTY as its standard streams.
    private static func spawn(shell: String, directory: URL, environment: [String: String],
                              size: winsize) throws -> (child: pid_t, master: Int32, device: dev_t) {
        guard let executable = Bundle.main.executablePath else { throw POSIXError(.ENOENT) }
        var master: Int32 = -1, slave: Int32 = -1, size = size, tty = stat()
        var name = [CChar](repeating: 0, count: 128)
        try check(openpty(&master, &slave, &name, nil, &size) == 0 ? 0 : errno)
        defer { close(slave) }
        do {
            try check(fstat(slave, &tty) == 0 && fcntl(master, F_SETFL, O_NONBLOCK) == 0 ? 0 : errno)
            var files: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
            try check(posix_spawn_file_actions_init(&files))
            defer { posix_spawn_file_actions_destroy(&files) }
            try check(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }
            var all = sigset_t(), none = sigset_t()
            sigfillset(&all)
            sigemptyset(&none)
            try check(posix_spawnattr_setsigdefault(&attributes, &all))
            try check(posix_spawnattr_setsigmask(&attributes, &none))
            let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            try check(posix_spawnattr_setflags(&attributes, Int16(flags)))
            try check(posix_spawn_file_actions_addchdir(&files, directory.path))
            // Opening the slave in the new session gives interactive shells a controlling terminal.
            try check(posix_spawn_file_actions_addopen(&files, 0, name, O_RDWR, 0))
            try check(posix_spawn_file_actions_adddup2(&files, 0, 1))
            try check(posix_spawn_file_actions_adddup2(&files, 0, 2))
            let arguments = [executable, "--pty-child", shell].map { strdup($0) } + [nil]
            let entries = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { (arguments + entries).forEach { free($0) } }
            var child: pid_t = 0
            try check(posix_spawn(&child, executable, &files, &attributes, arguments, entries))
            return (child, master, tty.st_rdev)
        } catch {
            close(master)
            throw error
        }
    }

    /// Runs as the PTY's session leader until the shell exits, then ends the shell's background jobs.
    static func supervise(shell: String) -> Int32 {
        let leader = getpid()
        var tty = stat(), child: pid_t = 0
        guard shell.hasPrefix("/"), getsid(0) == leader, isatty(0) == 1, fstat(0, &tty) == 0 else { return 126 }
        if tcgetsid(0) != leader && ioctl(0, TIOCSCTTY, 0) < 0 { return 126 }
        let arguments = [strdup(shell), nil]
        defer { free(arguments[0]) }
        guard posix_spawn(&child, shell, nil, nil, arguments, environ) == 0 else { return 127 }
        // The child inherits normal dispositions. Only it should react to interactive signals.
        for interactive in [SIGINT, SIGQUIT, SIGTSTP, SIGHUP] { signal(interactive, SIG_IGN) }
        while waitpid(child, nil, 0) == -1 && errno == EINTR {}
        endJobs(on: tty.st_rdev, of: leader)
        return 0
    }

    // Darwin clears a shell's controlling tty when its session leader exits. The supervisor
    // retains that session until it has also ended the shell's background jobs.
    private static func endJobs(on device: dev_t, of leader: pid_t) {
        let type = UInt32(PROC_TTY_ONLY), tty = UInt32(bitPattern: device), width = MemoryLayout<pid_t>.size
        var jobs = [pid_t](repeating: 0, count: max(0, Int(proc_listpids(type, tty, nil, 0))) / width + 32)
        let bytes = proc_listpids(type, tty, &jobs, Int32(jobs.count * width))
        for job in jobs.prefix(max(0, Int(bytes)) / width) where job > 1 && job != leader && getsid(job) == leader {
            kill(job, SIGKILL)
        }
    }

    private static func check(_ error: Int32) throws {
        if error != 0 { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
    }
}
