/// Reads a string command’s payload as it arrives and commits its effects at the terminator.
/// A cancelled or overlong command discards even the color queries already parsed.
struct TerminalStringHandler: Sendable {
    enum Function: Sendable {
        case windowTitle, indexedColor, foregroundColor, backgroundColor
    }

    enum Effect {
        case title(String)
        case colorQueries([ColorQuery])
    }

    // The limit is measured in UTF-16 code units. An overlong command has no effect.
    private static let payloadLimit = 10_000_000
    private var remainingCodeUnits = 0
    private(set) var title: String?
    private(set) var color: ColorQueryPayload?

    mutating func start(_ function: Function?) {
        title = nil
        color = nil
        switch function {
        case .windowTitle: title = ""
        case .indexedColor: color = .init(.index)
        case .foregroundColor: color = .init(.foreground)
        case .backgroundColor: color = .init(.background)
        case nil: break
        }
        remainingCodeUnits = Self.payloadLimit
    }

    var isReadingTitle: Bool { title != nil }
    var consumedCodeUnits: Int { Self.payloadLimit - remainingCodeUnits }

    // Printable ASCII contributes exactly one UTF-16 code unit per byte.
    mutating func appendTitleASCII(_ bytes: Span<UInt8>) {
        remainingCodeUnits -= bytes.count
        if remainingCodeUnits < 0 {
            title = nil
        } else {
            bytes.withUnsafeBufferPointer { title?.append(String(decoding: $0, as: UTF8.self)) }
        }
    }

    mutating func put(_ scalar: Unicode.Scalar) {
        guard title != nil || color != nil else { return }
        remainingCodeUnits -= scalar.value > 0xffff ? 2 : 1
        if remainingCodeUnits < 0 {
            title = nil
            color = nil
        } else if title != nil {
            title?.unicodeScalars.append(scalar)
        } else {
            color?.put(scalar)
        }
    }

    mutating func finish(success: Bool) -> Effect? {
        defer {
            title = nil
            color = nil
        }
        guard success else { return nil }
        if let title { return .title(title) }
        if let queries = color?.finish(), !queries.isEmpty { return .colorQueries(queries) }
        return nil
    }
}

/// OSC 4 accepts index/specification pairs. OSC 10 and 11 advance through default
/// colors with each field. Only a complete question-mark field requests a reply.
struct ColorQueryPayload: Sendable {
    enum Field {
        case index, indexedSpec(UInt8?), foreground, background, ignore
    }

    enum Token {
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

    private(set) var field: Field
    private(set) var token: Token = .empty
    private(set) var queries: [ColorQuery] = []

    init(_ field: Field) {
        self.field = field
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
