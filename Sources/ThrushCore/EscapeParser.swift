/// An incremental parser for the control repertoire in the recorded shell and Vim sessions.
/// Unknown control strings stream directly to their terminator without allocating payload storage.
struct EscapeParser: Sendable {
    enum Action {
        case printable, carriageReturn, lineFeed, backspace
        case keypad(Bool)
        case colorQueries([ColorQuery])
        case csi(final: UInt8, prefix: UInt8?, intermediate: UInt8?, parameters: [Int])
    }

    private enum State: Equatable {
        case ground, escape, escapeIntermediate, csi, ignoreCSI, osc, controlString
    }

    private var state: State = .ground
    private var colorQueries = ColorQueryParser()
    private var parameters: [Int] = []
    private var prefix: UInt8?
    private var intermediate: UInt8?
    private var hasParameter = false
    var isGround: Bool { state == .ground }

    mutating func consume(_ scalar: Unicode.Scalar) -> Action? {
        if state == .osc {
            switch scalar.value {
            case 0x07, 0x1b, 0x9c: // BEL, the ESC of a 7-bit ST, or 8-bit ST
                state = scalar.value == 0x1b ? .escape : .ground
                let queries = colorQueries.finish()
                return queries.isEmpty ? nil : .colorQueries(queries)
            case 0x18, 0x1a, 0x80...0x9f:
                // CAN/SUB cancel without replies. A new C1 introducer replaces this OSC.
                state = .ground
                colorQueries = ColorQueryParser()
            case 0x00...0x1f:
                return nil
            default:
                colorQueries.put(scalar.value)
                return nil
            }
        }

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

        if state == .controlString { return nil }

        switch scalar.value {
        case 0x08: return .backspace
        case 0x0a...0x0c: return .lineFeed
        case 0x0d: return .carriageReturn
        case 0x90, 0x98, 0x9e, 0x9f:
            state = .controlString
            return nil
        case 0x9d:
            state = .osc
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
            case 0x5d: state = .osc
            case 0x50, 0x58, 0x5e, 0x5f: state = .controlString
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
        case .osc, .controlString:
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

/// Recognize only the query fields a host palette can answer. Invalid fields and unknown OSCs
/// consume constant space. The ordered list of valid requests is held until termination so a
/// cancellation can discard the entire command without sending a partial reply.
private struct ColorQueryParser: Sendable {
    private enum Field {
        case identifier, index, indexedSpec(UInt8?), foreground, background, ignore
    }

    private enum Token {
        case empty, number(Int), question, invalid

        mutating func append(_ code: UInt32) {
            switch (self, code) {
            case (.empty, 0x3f):
                self = .question
            case (.empty, 0x30...0x39):
                self = .number(Int(code - 0x30))
            case (.number(let value), 0x30...0x39):
                self = .number(min(256, value * 10 + Int(code - 0x30)))
            default:
                self = .invalid
            }
        }
    }

    private var field = Field.identifier
    private var token = Token.empty
    private var queries: [ColorQuery] = []
    private var payloadLength: Int?
    // The pinned OscHandler discards payloads longer than ten million UTF-16 code units.
    private static let payloadLimit = 10_000_000

    mutating func put(_ code: UInt32) {
        if let payloadLength {
            let length = payloadLength + (code > 0xffff ? 2 : 1)
            if length > Self.payloadLimit {
                queries = []
                field = .ignore
                self.payloadLength = nil
                return
            }
            self.payloadLength = length
        }
        if case .ignore = field { return }
        if code == 0x3b { finishField() }
        else { token.append(code) }
    }

    mutating func finish() -> [ColorQuery] {
        finishField()
        let result = queries
        self = Self()
        return result
    }

    private mutating func finishField() {
        defer { token = .empty }
        switch field {
        case .identifier:
            switch token {
            case .number(4): field = .index
            case .number(10): field = .foreground
            case .number(11): field = .background
            default: field = .ignore; return
            }
            payloadLength = 0
        case .index:
            if case .number(let index) = token {
                field = .indexedSpec(UInt8(exactly: index))
            } else {
                field = .indexedSpec(nil)
            }
        case .indexedSpec(let index):
            if let index, case .question = token { queries.append(.indexed(index)) }
            field = .index
        case .foreground:
            if case .question = token { queries.append(.foreground) }
            field = .background
        case .background:
            if case .question = token { queries.append(.background) }
            field = .ignore
        case .ignore:
            break
        }
    }
}
