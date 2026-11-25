/// Reads a string command’s payload as it arrives and commits its effects at the terminator.
/// A cancelled or overlong command discards even the color queries already parsed.
struct TerminalStringHandler: Sendable {
    enum Function: Sendable {
        case indexedColor, foregroundColor, backgroundColor
    }

    // Discard the entire command when its payload exceeds this many UTF-16 code units.
    private static let payloadLimit = 10_000_000
    private var remainingCodeUnits = 0
    private var color: ColorQueryPayload?

    mutating func start(_ function: Function?) {
        color = function.map(ColorQueryPayload.init)
        remainingCodeUnits = Self.payloadLimit
    }

    mutating func put(_ scalar: Unicode.Scalar) {
        guard color != nil else { return }
        remainingCodeUnits -= scalar.value > 0xffff ? 2 : 1
        if remainingCodeUnits < 0 {
            color = nil
        } else {
            color?.put(scalar)
        }
    }

    mutating func finish(success: Bool) -> [ColorQuery] {
        defer { color = nil }
        return success ? color?.finish() ?? [] : []
    }
}

/// OSC 4 accepts index/specification pairs. OSC 10 and 11 advance through default
/// colors with each field. Only a complete question-mark field requests a reply.
private struct ColorQueryPayload: Sendable {
    private enum Field {
        case index, indexedSpec(UInt8?), foreground, background, ignore
    }

    private enum Token {
        case empty, number(Int), question, invalid

        mutating func append(_ scalar: Unicode.Scalar) {
            switch (self, scalar.value) {
            case (.empty, 0x3f):
                self = .question
            case (.empty, 0x30...0x39):
                self = .number(Int(scalar.value - 0x30))
            case (.number(let value), 0x30...0x39):
                self = .number(min(256, value * 10 + Int(scalar.value - 0x30)))
            default:
                self = .invalid
            }
        }
    }

    private var field: Field
    private var token: Token = .empty
    private var queries: [ColorQuery] = []

    init(_ function: TerminalStringHandler.Function) {
        switch function {
        case .indexedColor: field = .index
        case .foregroundColor: field = .foreground
        case .backgroundColor: field = .background
        }
    }

    mutating func put(_ scalar: Unicode.Scalar) {
        if case .ignore = field { return }
        if scalar == ";" { finishField() }
        else { token.append(scalar) }
    }

    mutating func finish() -> [ColorQuery] {
        finishField()
        return queries
    }

    private mutating func finishField() {
        defer { token = .empty }
        switch field {
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
