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

    private var state = State.ground.rawValue
    private var collected: UInt32 = 0
    /// Read the completed header after a CSI or DCS start, before consuming the next scalar.
    private(set) var parameters = ControlParameters()
    private var oscIdentifier = -1
    private var pending: Pending?
    var isGround: Bool { state == State.ground.rawValue }
    // Printable ASCII is inert in these payloads. Controls still use the transition table.
    var discardsASCII: Bool {
        switch state {
        case State.discardedOSC.rawValue, State.discardedDCS.rawValue, State.ignoredString.rawValue, State.invalidOSC.rawValue: true
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
        case State.oscPayload.rawValue: state = State.discardedOSC.rawValue
        case State.dcsPayload.rawValue: state = State.discardedDCS.rawValue
        default:
            // An OSC without a payload separator starts and ends on the same scalar.
            if case .stringEnd = pending { pending = nil }
        }
    }

    // Inlining this transition lets the receive loop switch on its action directly.
    // It also reduced the compiled core by 612 bytes in the Bash replay comparison.
    @inline(__always) mutating func consume(_ scalar: Unicode.Scalar) -> Action? {
        let code = scalar.value
        let index = Int(state) << 8 | Int(min(code, 0xA0))
        let transition = Self.transitions[index]
        state = transition.nextState
        // Operations that use a byte are reachable only for single-byte code points.
        let byte = UInt8(truncatingIfNeeded: code)
        switch transition.operation {
        case Operation.ignore.rawValue: return nil
        case Operation.print.rawValue: return .printable
        case Operation.execute.rawValue: return .execute(byte)
        case Operation.beginEscape.rawValue:
            collected = 0
        case Operation.beginHeader.rawValue, Operation.cancelAndBeginHeader.rawValue:
            collected = 0
            parameters.reset()
            if transition.operation == Operation.cancelAndBeginHeader.rawValue { return .stringEnd(success: false) }
        case Operation.collect.rawValue:
            collected = collected << 8 | code
        case Operation.parameter.rawValue:
            parameters.append(byte)
        case Operation.escapeFinal.rawValue: return .esc(ControlIdentifier(collected: collected, final: byte))
        case Operation.controlFinal.rawValue: return .csi(ControlIdentifier(collected: collected, final: byte))
        case Operation.startDCS.rawValue: return .dcsStart(ControlIdentifier(collected: collected, final: byte))
        case Operation.beginOSC.rawValue, Operation.cancelAndBeginOSC.rawValue:
            oscIdentifier = -1
            if transition.operation == Operation.cancelAndBeginOSC.rawValue { return .stringEnd(success: false) }
        case Operation.oscDigit.rawValue:
            let digit = Int(code - 0x30)
            if oscIdentifier <= (Int.max - digit) / 10 {
                oscIdentifier = max(0, oscIdentifier) * 10 + digit
            } else {
                state = State.invalidOSC.rawValue
            }
        case Operation.startOSC.rawValue: return .oscStart(oscIdentifier)
        case Operation.put.rawValue: return .stringPut(scalar)
        case Operation.finish.rawValue, Operation.cancel.rawValue:
            collected = 0
            return .stringEnd(success: transition.operation == Operation.finish.rawValue)
        case Operation.finishEmptyOSC.rawValue, Operation.cancelEmptyOSC.rawValue:
            collected = 0
            pending = .stringEnd(transition.operation == Operation.finishEmptyOSC.rawValue)
            return .oscStart(oscIdentifier)
        case Operation.cancelAndExecute.rawValue:
            pending = .execute(byte)
            return .stringEnd(success: false)
        default: preconditionFailure("Invalid framing table operation")
        }
        return nil
    }
}
