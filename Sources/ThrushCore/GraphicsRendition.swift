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

    /// The framer has already restricted this span to digits, colons and semicolons.
    @inline(__always)
    private static func decimal(in bytes: Span<UInt8>, at index: inout Int) -> Int? {
        guard index < bytes.count, bytes[index] <= UInt8(ascii: "9") else { return nil }
        var value = 0
        repeat {
            value = min(Int(Int32.max), value * 10 + Int(bytes[index] - UInt8(ascii: "0")))
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
            case 0: self = .init()
            case 1: bold = true
            case 2: dim = true
            case 3: italic = true
            // 4:0 removes the underline. The other underline styles draw as a single line.
            case 4: underline = operand[0] != 0
            case 5: blink = true
            case 7: inverse = true
            case 8: invisible = true
            case 9: strikethrough = true
            case 21: underline = true
            case 22:
                bold = false
                dim = false
            case 23: italic = false
            case 24: underline = false
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
                // Consume underline color (58) as one operand even though the grid does not display it.
                if let color = Self.extendedColor(operand, next: next) {
                    if parameter == 38 { foreground = color }
                    if parameter == 48 { background = color }
                }
            default: break
            }
        }
    }

    @inline(__always)
    private static func extendedColor(_ operand: Operand, next: () -> Operand?) -> Terminal.Color? {
        // A colon group contains the whole color, including any omitted components.
        if operand.components != nil {
            return colonColor(operand[0] ?? 0, operand, first: 1)
        }
        // 38;2::r:g:b puts the colon group on the mode instead of the selector.
        let mode = next() ?? Operand(0)
        if mode.components != nil { return colonColor(mode.value, mode, first: 0) }
        switch mode.value {
        case 5: return .indexed(byte(next()?.value))
        case 2:
            // In 38;2;r;g;b, a colon group on red or green supplies the rest of the RGB triple.
            let red = next() ?? Operand(0)
            if red.components != nil { return .rgb(byte(red.value), byte(red[0]), byte(red[1])) }
            let green = next() ?? Operand(0)
            if green.components != nil { return .rgb(byte(red.value), byte(green.value), byte(green[0])) }
            return .rgb(byte(red.value), byte(green.value), byte(next()?.value))
        default:
            // Unrecognized modes consume four fields. Mode zero also takes a color-space field.
            for _ in 0..<(mode.value == 0 ? 5 : 4) {
                guard let field = next(), field.components == nil else { break }
            }
            return nil
        }
    }

    @inline(__always)
    private static func colonColor(_ mode: Int, _ field: Operand, first: Int) -> Terminal.Color? {
        switch mode {
        case 5: return .indexed(byte(field[first]))
        // 38:2:cs:r:g:b includes a color-space identifier, which can be empty.
        case 2: return .rgb(byte(field[first + 1]), byte(field[first + 2]), byte(field[first + 3]))
        default: return nil
        }
    }

    private static func byte(_ value: Int?) -> UInt8 {
        UInt8(truncatingIfNeeded: value ?? 0)
    }
}
