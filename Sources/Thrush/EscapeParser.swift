/// Recognize just the operations used by the first shell transcript. Unsupported CSI,
/// intermediate escapes and control strings consume no space proportional to their length.
struct EscapeParser: Sendable {
    enum Action {
        case `print`, carriageReturn, lineFeed, backspace, cursorReport
        case applicationCursorKeys(Bool)
    }

    private enum State {
        case ground, escape, escapeIntermediate, csi, ignoreCSI
        case controlString(osc: Bool)
    }

    private var state: State = .ground
    private var parameters = Parameters()

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
            return .print
        case .escape:
            switch scalar.value {
            case 0x5b: beginCSI()                              // ESC [
            case 0x5d: state = .controlString(osc: true)        // ESC ]
            case 0x50, 0x58, 0x5e, 0x5f: state = .controlString(osc: false)
            case 0x20...0x2f: state = .escapeIntermediate
            default: state = .ground
            }
        case .escapeIntermediate:
            if !(0x20...0x2f).contains(scalar.value) { state = .ground }
        case .csi:
            if (0x40...0x7e).contains(scalar.value) {
                state = .ground
                return parameters.action(final: scalar)
            }
            if !parameters.consume(scalar) { state = .ignoreCSI }
        case .ignoreCSI:
            if (0x40...0x7e).contains(scalar.value) { state = .ground }
        case .controlString:
            break
        }
        return nil
    }

    private mutating func beginCSI() {
        parameters = Parameters()
        state = .csi
    }

    /// DSR uses the first parameter. DECSET/DECRST can list several private modes.
    /// Digits above 6 cease to affect any operation implemented at this milestone.
    private struct Parameters: Sendable {
        var isPrivate = false
        var current: Int?
        var first: Int?
        var sawModeOne = false

        mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x3f where !isPrivate && current == nil && first == nil:
                isPrivate = true
            case 0x30...0x39:
                current = min(7, (current ?? 0) * 10 + Int(scalar.value - 0x30))
            case 0x3b:
                first = first ?? current ?? 0
                sawModeOne = sawModeOne || current == 1
                current = nil
            default:
                return false
            }
            return true
        }

        func action(final: Unicode.Scalar) -> Action? {
            if isPrivate && (sawModeOne || current == 1) {
                switch final {
                case "h": return .applicationCursorKeys(true)
                case "l": return .applicationCursorKeys(false)
                default: return nil
                }
            }
            if !isPrivate && final == "n" && (first ?? current) == 6 {
                return .cursorReport
            }
            return nil
        }
    }
}
