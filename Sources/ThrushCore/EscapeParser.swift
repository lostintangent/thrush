// Frames control sequences across input chunks. The terminal can act on each complete
// identifier or consume a string as it arrives, even when one read ends halfway through it.

/// A control's private prefix, intermediate bytes and final byte packed in wire order.
struct ControlIdentifier: Hashable, Sendable {
    let rawValue: UInt32

    init(_ final: UInt8, prefix: UInt8? = nil, intermediate: UInt8? = nil, secondIntermediate: UInt8? = nil) {
        var collected = UInt32(prefix ?? 0)
        if let intermediate { collected = collected << 8 | UInt32(intermediate) }
        if let secondIntermediate { collected = collected << 8 | UInt32(secondIntermediate) }
        self.init(collected: collected, final: final)
    }

    fileprivate init(collected: UInt32, final: UInt8) {
        rawValue = collected << 8 | UInt32(final)
    }
}

/// Frames ASCII bytes and decoded Unicode scalars into VT controls.
/// String payloads are forwarded as they arrive.
struct EscapeParser: Sendable {
    static let escape: UInt8 = 0x1b
    static let delete: UInt8 = 0x7f

    enum Action {
        case printable, execute(UInt8)
        case esc(ControlIdentifier), csi(ControlIdentifier)
        case oscStart(Int), dcsStart(ControlIdentifier)
        case stringPut(Unicode.Scalar), stringEnd(success: Bool)
    }

    private enum PendingAction { case stringEnd(Bool), execute(UInt8) }

    private(set) var state = State.ground
    private(set) var collected: UInt32 = 0
    /// Read the completed header after a CSI or DCS start, before consuming the next scalar.
    private(set) var parameters = ControlParameters()
    private(set) var oscIdentifier = -1
    private var pending: PendingAction?
    var isGround: Bool { state == .ground }

    /// Printable ASCII has no effect inside these strings. Controls still need framing.
    var discardsASCII: Bool {
        switch state {
        case .discardedOSC, .discardedDCS, .ignoredString, .invalidOSC: true
        default: false
        }
    }

    /// A scalar can finish an empty OSC or interrupt a string and execute a C1
    /// control. Drain the second notification after an OSC start or string end.
    mutating func takePendingAction() -> Action? {
        defer { pending = nil }
        switch pending {
        case .stringEnd(let success): return .stringEnd(success: success)
        case .execute(let byte): return .execute(byte)
        case nil: return nil
        }
    }

    /// Suppress payload delivery after dispatch declines a string command.
    mutating func discardStringPayload() {
        switch state {
        case .oscPayload: state = .discardedOSC
        case .dcsPayload: state = .discardedDCS
        default:
            // An OSC without a payload separator starts and ends on the same scalar.
            if case .stringEnd = pending { pending = nil }
        }
    }

    /// Consumes ASCII from ESC, or from anywhere inside a control, until one action is ready or text can resume.
    ///
    /// A CSI that arrives whole, with only digits, colons and semicolons before its final byte, lends its
    /// parameters instead of storing them. `parameterBytes` gives their range in `bytes`, and `parameters`
    /// stays empty unless the caller passes them to `storeParameters(_:)`.
    // Inlined into its one caller, Terminal's readSequence, so each sequence costs a single call.
    @inline(__always)
    mutating func consume(_ bytes: Span<UInt8>, from index: inout Int, parameterBytes: inout Range<Int>?) -> Action? {
        if isGround, bytes.count - index >= 2, bytes[index] == Self.escape, bytes[index + 1] == UInt8(ascii: "[") {
            state = .csiEntry
            beginHeader()
            index += 2
            let start = index
            while index < bytes.count, Self.isParameter(bytes[index]) { index += 1 }
            if index < bytes.count, Self.isFinal(bytes[index]) {
                parameterBytes = start..<index
                let identifier = ControlIdentifier(bytes[index])
                index += 1
                state = .ground
                return .csi(identifier)
            }
            // The rest of the header arrives later or has a prefix or intermediate, so it uses the same
            // stored parameters as a header split across reads.
            if start < index {
                state = .csiParameters
                for position in start..<index { parameters.append(bytes[position]) }
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            guard byte < 0x80 else { break }
            let code = UInt32(byte)
            let transition = Self.transition(from: state, scalar: code)
            if transition.operation == .parameter {
                state = transition.nextState
                // All parameter bytes continue in the same CSI or DCS parameter state.
                repeat {
                    parameters.append(bytes[index])
                    index += 1
                } while index < bytes.count && Self.isParameter(bytes[index])
            } else {
                index += 1
                if let action = advance(transition, code: code) { return action }
            }
            if isGround || discardsASCII { break }
        }
        return nil
    }

    /// Stores the parameters a complete CSI lent, for a function that reads them by position.
    mutating func storeParameters(_ bytes: Span<UInt8>) {
        for index in bytes.indices { parameters.append(bytes[index]) }
    }

    /// Digits, colons and semicolons.
    private static func isParameter(_ byte: UInt8) -> Bool { (0x30...0x3B).contains(byte) }

    /// The final byte of a CSI or escape sequence, from `@` to `~`.
    private static func isFinal(_ byte: UInt8) -> Bool { (0x40...0x7E).contains(byte) }

    private mutating func beginHeader() {
        collected = 0
        parameters.reset()
    }

    @inline(__always)
    mutating func consume(ascii byte: UInt8) -> Action? {
        let code = UInt32(byte)
        return advance(Self.transition(from: state, scalar: code), code: code)
    }

    @inline(__always)
    mutating func consume(_ scalar: Unicode.Scalar) -> Action? {
        advance(Self.transition(from: state, scalar: scalar.value), code: scalar.value)
    }

    @inline(__always)
    private mutating func advance(_ transition: Transition, code: UInt32) -> Action? {
        state = transition.nextState
        // Operations that use a byte are reachable only for single-byte code points.
        let byte = UInt8(truncatingIfNeeded: code)
        switch transition.operation {
        case .ignore: return nil
        case .print: return .printable
        case .execute: return .execute(byte)
        case .beginEscape:
            collected = 0
        case .beginHeader, .cancelAndBeginHeader:
            beginHeader()
            if transition.operation == .cancelAndBeginHeader { return .stringEnd(success: false) }
        case .collect:
            collected = collected << 8 | code
        case .parameter:
            parameters.append(byte)
        case .escapeFinal: return .esc(ControlIdentifier(collected: collected, final: byte))
        case .controlFinal: return .csi(ControlIdentifier(collected: collected, final: byte))
        case .startDCS: return .dcsStart(ControlIdentifier(collected: collected, final: byte))
        case .beginOSC, .cancelAndBeginOSC:
            oscIdentifier = -1
            if transition.operation == .cancelAndBeginOSC { return .stringEnd(success: false) }
        case .oscDigit:
            let digit = Int(code - 0x30)
            if oscIdentifier <= (Int.max - digit) / 10 {
                oscIdentifier = max(0, oscIdentifier) * 10 + digit
            } else {
                state = .invalidOSC
            }
        case .startOSC: return .oscStart(oscIdentifier)
        case .put: return .stringPut(Unicode.Scalar(code)!)
        case .finish, .cancel:
            collected = 0
            return .stringEnd(success: transition.operation == .finish)
        case .finishEmptyOSC, .cancelEmptyOSC:
            collected = 0
            pending = .stringEnd(transition.operation == .finishEmptyOSC)
            return .oscStart(oscIdentifier)
        case .cancelAndExecute:
            pending = .execute(byte)
            return .stringEnd(success: false)
        }
        return nil
    }
}
