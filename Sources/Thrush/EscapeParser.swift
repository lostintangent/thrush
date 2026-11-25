/// An incremental parser for the control repertoire in the recorded shell and Vim sessions.
/// Unknown control strings stream directly to their terminator without allocating payload storage.
struct EscapeParser: Sendable {
    enum Action {
        case printable, carriageReturn, lineFeed, backspace
        case keypad(Bool)
        case csi(final: UInt8, prefix: UInt8?, intermediate: UInt8?, parameters: [Int])
    }

    private enum State: Equatable {
        case ground, escape, escapeIntermediate, csi, ignoreCSI, controlString(osc: Bool)
    }

    private var state: State = .ground
    private var parameters: [Int] = []
    private var prefix: UInt8?
    private var intermediate: UInt8?
    private var hasParameter = false
    var isGround: Bool { state == .ground }

    mutating func consume(_ scalar: Unicode.Scalar) -> Action? {
        switch scalar.value {
        case 0x18, 0x1a, 0x9c: // CAN, SUB and ST
            state = .ground
            return nil
        case 0x1b:
            state = .escape
            return nil
        default:
            break
        }

        if case .controlString(let osc) = state {
            if osc && scalar.value == 0x07 { state = .ground }
            return nil
        }

        switch scalar.value {
        case 0x08: return .backspace
        case 0x0a...0x0c: return .lineFeed
        case 0x0d: return .carriageReturn
        case 0x90, 0x98, 0x9e, 0x9f:
            state = .controlString(osc: false)
            return nil
        case 0x9d:
            state = .controlString(osc: true)
            return nil
        case 0x9b:
            beginCSI()
            return nil
        case 0x00...0x1f, 0x7f...0x9f:
            return nil
        default:
            break
        }

        switch state {
        case .ground:
            return .printable
        case .escape:
            switch scalar.value {
            case 0x5b: beginCSI()
            case 0x5d: state = .controlString(osc: true)
            case 0x50, 0x58, 0x5e, 0x5f: state = .controlString(osc: false)
            case 0x20...0x2f: state = .escapeIntermediate
            case 0x3d, 0x3e:
                state = .ground
                return .keypad(scalar.value == 0x3d)
            default: state = .ground
            }
        case .escapeIntermediate:
            if !(0x20...0x2f).contains(scalar.value) { state = .ground }
        case .csi:
            switch scalar.value {
            case 0x40...0x7e:
                state = .ground
                return .csi(final: UInt8(scalar.value), prefix: prefix, intermediate: intermediate, parameters: parameters)
            case 0x3c...0x3f where prefix == nil && intermediate == nil && !hasParameter:
                prefix = UInt8(scalar.value)
            case 0x20...0x2f where intermediate == nil:
                intermediate = UInt8(scalar.value)
            case 0x30...0x39 where intermediate == nil:
                hasParameter = true
                let index = parameters.count - 1
                parameters[index] = min(Int(Int32.max), parameters[index] * 10 + Int(scalar.value - 0x30))
            case 0x3b where intermediate == nil && parameters.count < 32:
                hasParameter = true
                parameters.append(0)
            default:
                state = .ignoreCSI
            }
        case .ignoreCSI:
            if (0x40...0x7e).contains(scalar.value) { state = .ground }
        case .controlString:
            break
        }
        return nil
    }

    private mutating func beginCSI() {
        parameters.removeAll(keepingCapacity: true)
        parameters.append(0)
        prefix = nil
        intermediate = nil
        hasParameter = false
        state = .csi
    }
}
