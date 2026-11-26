import ThrushCore

// The host reaches each terminal by its handle and passes bytes through linear memory: it writes
// a chunk into the input buffer, and reads a replay or replies from the output buffer. Both
// buffers stay put until the next call that names them, which may move them as they grow.

nonisolated(unsafe) private var terminals: [Terminal?] = []
nonisolated(unsafe) private var input = Bytes()
nonisolated(unsafe) private var output = Bytes()

@_expose(wasm, "thrush_new")
func newTerminal(columns: Int32, rows: Int32) -> Int32 {
    let terminal = Terminal(size: .init(columns: Int(columns), rows: Int(rows)))
    if let free = terminals.firstIndex(where: { $0 == nil }) {
        terminals[free] = terminal
        return Int32(free)
    }
    terminals.append(terminal)
    return Int32(terminals.count - 1)
}

@_expose(wasm, "thrush_free")
func freeTerminal(handle: Int32) {
    terminals[Int(handle)] = nil
}

/// The input buffer, with room for at least `count` bytes.
@_expose(wasm, "thrush_input")
func inputBuffer(count: Int32) -> UnsafeMutablePointer<UInt8> {
    input.reserve(Int(count))
}

/// Parses the first `count` bytes of the input buffer, and returns the length of the replies it
/// leaves in the output buffer.
@_expose(wasm, "thrush_write")
func write(handle: Int32, count: Int32) -> Int32 {
    let bytes = UnsafeBufferPointer(start: input.base, count: Int(count))
    let replies = terminals[Int(handle)]!.receive(bytes)
    return output.store(replies)
}

@_expose(wasm, "thrush_resize")
func resize(handle: Int32, columns: Int32, rows: Int32) {
    terminals[Int(handle)]!.resize(to: .init(columns: Int(columns), rows: Int(rows)))
}

/// Leaves the bytes that redraw this terminal on a blank one in the output buffer, and returns
/// their length.
@_expose(wasm, "thrush_replay")
func replay(handle: Int32) -> Int32 {
    output.store(terminals[Int(handle)]!.replayBytes())
}

@_expose(wasm, "thrush_output")
func outputBuffer() -> UnsafeMutablePointer<UInt8> {
    output.base
}

private struct Bytes {
    private(set) var base = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 16)
    private var capacity = 1 << 16

    mutating func reserve(_ count: Int) -> UnsafeMutablePointer<UInt8> {
        if count > capacity {
            base.deallocate()
            capacity = max(count, capacity * 2)
            base = .allocate(capacity: capacity)
        }
        return base
    }

    mutating func store(_ bytes: [UInt8]) -> Int32 {
        let base = reserve(bytes.count)
        bytes.withUnsafeBufferPointer { if let start = $0.baseAddress { base.update(from: start, count: $0.count) } }
        return Int32(bytes.count)
    }
}
