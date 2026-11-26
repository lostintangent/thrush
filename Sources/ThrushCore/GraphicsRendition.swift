// Applies Select Graphic Rendition (SGR) parameters to the style used for subsequent text.
// A single command can change several attributes, so its fields take effect in order.

extension Terminal.Style {
    /// A color with a color-space identifier needs up to five colon subparameters.
    /// An omitted component remains distinct from a literal zero.
    private struct Operand {
        let value: Int
        var components: InlineArray<5, Int32>?

        init(_ value: Int) { self.value = value }

        subscript(_ index: Int) -> Int? {
            guard let components, components[index] >= 0 else { return nil }
            return Int(components[index])
        }
    }

    /// The color after 38, 48 or 58. It comes from a colon group or from the semicolon operands that
    /// follow, which it takes one at a time.
    private struct ExtendedColor {
        private var mode: Int?
        private var values = InlineArray<3, Int>(repeating: 0)
        private var fields = 0
        private var isComplete = false

        init(_ selector: Operand) {
            // A colon group contains the whole color, including any omitted components.
            if selector.components != nil { take(group: selector, mode: selector[0] ?? 0, first: 1) }
        }

        /// 38;5;n takes one field and 38;2;r;g;b three. Unrecognized modes consume four fields, and
        /// mode zero also a color-space field.
        var needsField: Bool {
            guard !isComplete else { return false }
            guard let mode else { return true }
            return fields < (mode == 5 ? 1 : mode == 2 ? 3 : mode == 0 ? 5 : 4)
        }

        mutating func take(_ field: Operand) {
            guard mode != nil else {
                // 38;2::r:g:b puts the colon group on the mode instead of the selector.
                if field.components != nil { take(group: field, mode: field.value, first: 0) } else { mode = field.value }
                return
            }
            if fields < values.count { values[fields] = field.value }
            fields += 1
            // A colon group ends the fields. In 38;2;r:g:b and 38;2;r;g:b it supplies the rest of the triple.
            guard field.components != nil else { return }
            for ordinal in 0..<max(0, values.count - fields) { values[fields + ordinal] = field[ordinal] ?? 0 }
            isComplete = true
        }

        private mutating func take(group: Operand, mode: Int, first: Int) {
            self.mode = mode
            // 38:2:cs:r:g:b includes a color-space identifier, which can be empty.
            let start = mode == 2 ? first + 1 : first
            for ordinal in 0..<values.count { values[ordinal] = group[start + ordinal] ?? 0 }
            isComplete = true
        }

        var color: Terminal.Color? {
            let byte = { UInt8(truncatingIfNeeded: values[$0]) }
            return switch mode {
            case 5: .indexed(byte(0))
            case 2: .rgb(byte(0), byte(1), byte(2))
            default: nil
            }
        }
    }

    mutating func applySGR(_ parameters: ControlParameters) {
        var index = 0
        applyRenditions {
            guard index < parameters.count else { return nil }
            defer { index += 1 }
            var operand = Operand(parameters[index])
            let count = parameters.subparameterCount(at: index)
            if count > 0 {
                var components = InlineArray<5, Int32>(repeating: -1)
                for ordinal in 0..<min(count, components.count) {
                    components[ordinal] = Int32(parameters[parameter: index, subparameter: ordinal] ?? -1)
                }
                operand.components = components
            }
            return operand
        }
    }

    /// Read one semicolon operand at a time, including the colon components belonging to it.
    /// The final byte is already known, so an interrupted control can never change the style.
    @inline(__always)
    mutating func applySGR(_ bytes: Span<UInt8>) {
        var index = 0
        var remainingOperands = ControlParameters.limit
        var remainingComponents = ControlParameters.limit
        applyRenditions {
            guard remainingOperands > 0 else { return nil }
            remainingOperands -= 1
            var operand = Operand(Self.decimal(in: bytes, at: &index) ?? 0)
            if index < bytes.count, bytes[index] == UInt8(ascii: ":") {
                var components = InlineArray<5, Int32>(repeating: -1)
                var count = 0
                repeat {
                    index += 1
                    let value = Self.decimal(in: bytes, at: &index)
                    if remainingComponents > 0 {
                        remainingComponents -= 1
                        if count < components.count { components[count] = Int32(value ?? -1) }
                        count += 1
                    }
                } while index < bytes.count && bytes[index] == UInt8(ascii: ":")
                if count > 0 { operand.components = components }
            }
            if index < bytes.count {
                index += 1 // The semicolon starts another operand, even when it is the last byte.
            } else {
                remainingOperands = 0
            }
            return operand
        }
    }

    /// The parser has already restricted this span to digits, colons and semicolons.
    @inline(__always)
    private static func decimal(in bytes: Span<UInt8>, at index: inout Int) -> Int? {
        guard index < bytes.count, bytes[index] <= UInt8(ascii: "9") else { return nil }
        var value = 0
        repeat {
            // Clamping at every digit keeps the value far from overflow.
            value = min(Int(Int32.max), value &* 10 &+ Int(bytes[index] &- UInt8(ascii: "0")))
            index += 1
        } while index < bytes.count && bytes[index] <= UInt8(ascii: "9")
        return value
    }

    /// Each operand changes one attribute or supplies components to the preceding color.
    @inline(__always)
    private mutating func applyRenditions(next: () -> Operand?) {
        while let operand = next() {
            let parameter = operand.value
            switch parameter {
            case 0: resetRenditions()
            case 1: bold = true
            case 2: dim = true
            case 3: italic = true
            // 4:1 through 4:5 choose the style and 4:0 removes it. Any other style is single.
            case 4: underline = Terminal.Underline(rawValue: UInt8(clamping: operand[0] ?? 1)) ?? .single
            case 5: blink = true
            case 7: inverse = true
            case 8: invisible = true
            case 9: strikethrough = true
            case 21: underline = .double
            case 22:
                bold = false
                dim = false
            case 23: italic = false
            case 24: underline = .none
            case 25: blink = false
            case 27: inverse = false
            case 28: invisible = false
            case 29: strikethrough = false
            case 30...37: foreground = .indexed(UInt8(parameter - 30))
            case 40...47: background = .indexed(UInt8(parameter - 40))
            case 90...97: foreground = .indexed(UInt8(parameter - 90 + 8))
            case 100...107: background = .indexed(UInt8(parameter - 100 + 8))
            case 39: foreground = .default
            case 49: background = .default
            case 38, 48, 58:
                var fields = ExtendedColor(operand)
                while fields.needsField, let field = next() { fields.take(field) }
                if let color = fields.color {
                    switch parameter {
                    case 38: foreground = color
                    case 48: background = color
                    default: underlineColor = color
                    }
                }
            case 53: overline = true
            case 55: overline = false
            case 59: underlineColor = .default
            default: break
            }
        }
    }

    /// The SGR parameters that select this style, starting from the default with 0. The link is not
    /// a rendition, so OSC 8 sets it separately.
    var renditionParameters: String {
        var parameters = ["0"]
        let underlineCode = switch underline {
        case .none: ""
        case .single: "4"
        default: "4:\(underline.rawValue)"
        }
        for (set, code) in [(bold, "1"), (dim, "2"), (italic, "3"), (!underlineCode.isEmpty, underlineCode), (blink, "5"),
                            (inverse, "7"), (invisible, "8"), (strikethrough, "9"), (overline, "53")] where set {
            parameters.append(code)
        }
        for (color, prefix) in [(foreground, "38"), (background, "48"), (underlineColor, "58")] {
            switch color {
            case .default: break
            case .indexed(let index): parameters.append("\(prefix);5;\(index)")
            case .rgb(let r, let g, let b): parameters.append("\(prefix);2;\(r);\(g);\(b)")
            }
        }
        return parameters.joined(separator: ";")
    }
}
