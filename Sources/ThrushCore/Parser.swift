// Turns shell output into text and named control functions, across reads that can end anywhere,
// even inside a character or a sequence. It's the only code that knows the wire grammar, and it
// knows nothing about what a function does.

/// Reads bytes as text to print and control functions to perform.
struct Parser: Sendable {
    /// What the parser read: text to print or a function to perform.
    enum Token {
        case text(Text)
        case function(ControlFunction)
    }

    /// Printable text, either a run of ASCII in the chunk or glyphs decoded into ``glyphs``.
    enum Text {
        case ascii(Range<Int>)
        case glyphs(count: Int)
    }

    private static let escape: UInt8 = 0x1b
    private static let delete: UInt8 = 0x7f

    /// The last control sequence's parameters. Its readers are mutating, so reading one never copies them.
    var parameters = Parameters()
    /// The last control string's payload.
    private(set) var payload = Payload()
    /// The glyphs behind the last `.glyphs(count:)`, each a scalar with the flag for its width.
    private(set) var glyphs = InlineArray<64, UInt32>(repeating: 0)

    // Reading the lazy static calls out to `swift_once` for tens of milliseconds after its first use.
    let transitions = Self.transitions
    private(set) var state = State.ground
    /// A character the last read ended partway through.
    private(set) var scanner = TextScanner()
    /// The sequence's private marker and intermediates, packed in wire order.
    private(set) var collected: UInt32 = 0
    /// The number naming the OSC being read, or -1 before its first digit.
    private(set) var oscIdentifier = -1
    /// The string being read, or `.unsupported` when Thrush doesn't perform it.
    private(set) var string = ControlFunction.unsupported

    /// Reads from `index` to the next piece of text or the next complete function, and returns nil
    /// once the chunk is used up. Bytes that make neither, such as half a sequence, a string's text,
    /// DEL or an ignored sequence, are consumed on the way.
    @inline(__always)
    mutating func next(in bytes: Span<UInt8>, from index: inout Int) -> Token? {
        while index < bytes.count {
            let byte = bytes[index]
            // An ASCII byte ends any character left incomplete before it.
            if byte < 0x80, !scanner.isComplete { scanner = TextScanner() }
            if state == .ground {
                if TextScanner.isPrintableASCII(byte) {
                    let start = index
                    index = TextScanner.endOfASCII(in: bytes, from: start)
                    return .text(.ascii(start..<index))
                }
                if byte < 0x20, byte != Self.escape {
                    index += 1
                    return .function(ControlFunction(executing: byte))
                }
                if byte == Self.delete {
                    index += 1
                    continue
                }
                if byte >= 0x80 {
                    let (count, control) = scanner.decodeText(in: bytes, index: &index, into: &glyphs)
                    if count > 0 { return .text(.glyphs(count: count)) }
                    if let control, let function = read(control) { return .function(function) }
                    continue
                }
                if let function = readWholeSequence(in: bytes, from: &index) { return .function(function) }
            }
            if let function = readSequence(in: bytes, from: &index) { return .function(function) }
        }
        return nil
    }

    /// Reads a C1 control that came between pieces of text.
    private mutating func read(_ control: Unicode.Scalar) -> ControlFunction? {
        advance(transition(from: state, scalar: control.value), code: control.value)
    }

    /// Reads a sequence from `index` until it completes a function, ends without one or the chunk runs out.
    private mutating func readSequence(in bytes: Span<UInt8>, from index: inout Int) -> ControlFunction? {
        while index < bytes.count {
            let byte = bytes[index]
            var code = UInt32(byte)
            index += 1
            if byte < 0x80 {
                if !scanner.isComplete { scanner = TextScanner() }
                if TextScanner.isPrintableASCII(byte) {
                    switch state {
                    case .oscPayload, .dcsPayload, .invalidOSC, .ignoredString:
                        // A string's printable text is read as a run, and kept only for a payload Thrush performs.
                        let start = index - 1
                        index = TextScanner.endOfASCII(in: bytes, from: index)
                        if state == .oscPayload || state == .dcsPayload { payload.append(bytes.extracting(start..<index)) }
                        continue
                    default: break
                    }
                }
            } else {
                // Inside a sequence other bytes decode to scalars, and every scalar past the C1 controls reads alike.
                guard let scalar = scanner.decode(byte), scalar != TextScanner.byteOrderMark else { continue }
                code = scalar.value
            }
            let transition = transition(from: state, scalar: code)
            if transition.operation == .parameter {
                // Digits, colons and semicolons are read as a run.
                state = transition.nextState
                let start = index - 1
                index = Self.endOfParameters(in: bytes, from: index)
                parameters.append(start..<index, of: bytes)
                continue
            }
            if let function = advance(transition, code: code) { return function }
            if state == .ground { return nil }
        }
        return nil
    }

    /// Reads a control sequence that arrived whole, with only digits, colons and semicolons before its final
    /// byte, in one pass. A whole SGR's parameters are lent from the chunk rather than copied. Any other
    /// sequence is left started for the state machine to finish.
    @inline(__always)
    private mutating func readWholeSequence(in bytes: Span<UInt8>, from index: inout Int) -> ControlFunction? {
        guard bytes.count - index >= 2, bytes[index] == Self.escape, bytes[index + 1] == UInt8(ascii: "[") else { return nil }
        clear()
        let start = index + 2
        index = Self.endOfParameters(in: bytes, from: start)
        if index < bytes.count, Self.isFinal(bytes[index]) {
            let final = bytes[index]
            let header = start..<index
            index += 1
            if final == Self.graphicRendition {
                parameters.lend(header)
                return .csi(.graphicRendition)
            }
            parameters.append(header, of: bytes)
            return ControlFunction(csi: UInt32(final))
        }
        state = .csiEntry
        if start < index {
            parameters.append(start..<index, of: bytes)
            state = .csiParameters
        }
        return nil
    }

    private static let graphicRendition = UInt8(ControlFunction.CSI.graphicRendition.rawValue)

    /// Digits, colons and semicolons.
    private static func isParameter(_ byte: UInt8) -> Bool { (0x30...0x3B).contains(byte) }

    /// The index after the run of parameter bytes that starts at `start`.
    @inline(never)
    private static func endOfParameters(in bytes: Span<UInt8>, from start: Int) -> Int {
        var end = start
        while end < bytes.count, isParameter(bytes[end]) { end += 1 }
        return end
    }

    /// The final byte of a CSI or escape sequence, from `@` to `~`.
    private static func isFinal(_ byte: UInt8) -> Bool { (0x40...0x7E).contains(byte) }

    /// Takes one step of the state machine, and returns the function the step completes, if any.
    @inline(__always)
    private mutating func advance(_ transition: Transition, code: UInt32) -> ControlFunction? {
        let previous = state
        state = transition.nextState
        // Operations that read a byte are reachable only for single-byte code points.
        let byte = UInt8(truncatingIfNeeded: code)
        switch transition.operation {
        case .ignore: break
        case .execute: return ControlFunction(executing: byte)
        case .clear: clear()
        case .collect: collected = collected << 8 | code
        case .parameter: parameters.append(byte)
        case .escapeFinal: return ControlFunction(escape: collected << 8 | code)
        case .controlFinal: return ControlFunction(csi: collected << 8 | code)
        case .startDCS: startString(ControlFunction.DCS(rawValue: collected << 8 | code).map(ControlFunction.dcs))
        case .oscDigit:
            let digit = Int(code - 0x30)
            if oscIdentifier <= (Int.max - digit) / 10 {
                oscIdentifier = max(0, oscIdentifier) * 10 + digit
            } else {
                state = .invalidOSC
            }
        case .startOSC: startString(ControlFunction.OSC(rawValue: oscIdentifier).map(ControlFunction.osc))
        case .put: payload.append(code)
        case .finish:
            // An OSC can end right after its number, with an empty payload.
            if previous == .oscIdentifier { startString(ControlFunction.OSC(rawValue: oscIdentifier).map(ControlFunction.osc)) }
            clear()
            return payload.isKept ? string : .unsupported
        case .cancel: return .unsupported
        case .cancelAndClear:
            clear()
            return .unsupported
        }
        return nil
    }

    /// Forgets the last sequence's header, as each new sequence starts.
    private mutating func clear() {
        collected = 0
        oscIdentifier = -1
        parameters.removeAll()
    }

    /// Starts a string's payload, which keeps its text only for a function Thrush performs.
    private mutating func startString(_ function: ControlFunction?) {
        string = function ?? .unsupported
        payload.start(keeping: function != nil)
    }
}
