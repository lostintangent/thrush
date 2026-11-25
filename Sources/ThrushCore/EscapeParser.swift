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

/// Frames a Unicode scalar stream into VT controls. String payloads are forwarded
/// as they arrive; the framer never accumulates their contents.
struct EscapeParser: Sendable {
    enum Action {
        case printable, execute(UInt8)
        case esc(ControlIdentifier), csi(ControlIdentifier)
        case oscStart(Int), dcsStart(ControlIdentifier)
        case stringPut(Unicode.Scalar), stringEnd(success: Bool)
    }

    private enum Pending { case stringEnd(Bool), execute(UInt8) }

    private var state = Tag(State.ground)
    private var collected: UInt32 = 0
    /// Read the completed header after a CSI or DCS start, before consuming the next scalar.
    private(set) var parameters = ControlParameters()
    private var oscIdentifier = -1
    private var pending: Pending?
    var isGround: Bool { state.matches(.ground) }

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
        case .oscPayload: state = Tag(.discardedOSC)
        case .dcsPayload: state = Tag(.discardedDCS)
        default:
            // An OSC without a payload separator starts and ends on the same scalar.
            if case .stringEnd = pending { pending = nil }
        }
    }

    @inline(__always)
    mutating func consume(_ scalar: Unicode.Scalar) -> Action? {
        let code = scalar.value
        let transition = Self.transition(from: state, scalar: code)
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
            collected = 0
            parameters.reset()
            if transition.operation.matches(.cancelAndBeginHeader) { return .stringEnd(success: false) }
        case .collect:
            collected = collected << 8 | code
        case .parameter:
            parameters.append(byte)
        case .escapeFinal: return .esc(ControlIdentifier(collected: collected, final: byte))
        case .controlFinal: return .csi(ControlIdentifier(collected: collected, final: byte))
        case .startDCS: return .dcsStart(ControlIdentifier(collected: collected, final: byte))
        case .beginOSC, .cancelAndBeginOSC:
            oscIdentifier = -1
            if transition.operation.matches(.cancelAndBeginOSC) { return .stringEnd(success: false) }
        case .oscDigit:
            let digit = Int(code - 0x30)
            if oscIdentifier <= (Int.max - digit) / 10 {
                oscIdentifier = max(0, oscIdentifier) * 10 + digit
            } else {
                state = Tag(.invalidOSC)
            }
        case .startOSC: return .oscStart(oscIdentifier)
        case .put: return .stringPut(scalar)
        case .finish, .cancel:
            collected = 0
            return .stringEnd(success: transition.operation.matches(.finish))
        case .finishEmptyOSC, .cancelEmptyOSC:
            collected = 0
            pending = .stringEnd(transition.operation.matches(.finishEmptyOSC))
            return .oscStart(oscIdentifier)
        case .cancelAndExecute:
            pending = .execute(byte)
            return .stringEnd(success: false)
        default: preconditionFailure("Invalid framing table operation")
        }
        return nil
    }
}
