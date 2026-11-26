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

    /// Reads one semicolon operand at a time, including the colon components belonging to it, and
    /// applies each as it's read. The final byte is already known, so an interrupted control can never
    /// change the style.
    @inline(__always)
    mutating func applySGR(_ parameters: inout Parameters, in chunk: Span<UInt8>) {
        parameters.withBytes(in: chunk) { applySGR($0) }
    }

    @inline(never)
    mutating func applySGR(_ bytes: Span<UInt8>) {
        var index = 0
        var remainingOperands = Parameters.limit
        var remainingComponents = Parameters.limit
        applyRenditions {
            guard remainingOperands > 0 else { return nil }
            remainingOperands -= 1
            var operand = Operand(Parameters.number(in: bytes, at: &index) ?? 0)
            if index < bytes.count, bytes[index] == Parameters.colon {
                var components = InlineArray<5, Int32>(repeating: -1)
                var count = 0
                repeat {
                    index += 1
                    let value = Parameters.number(in: bytes, at: &index)
                    if remainingComponents > 0 {
                        remainingComponents -= 1
                        if count < components.count { components[count] = Int32(value ?? -1) }
                        count += 1
                    }
                } while index < bytes.count && bytes[index] == Parameters.colon
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

    /// The SGR parameters that turn `previous` into this style. A style that only adds or replaces
    /// renditions writes what changed. One that turns any off starts over from 0, since a parameter
    /// like 22 turns off more than one, and so does a style without a previous one. The link is not a
    /// rendition, so OSC 8 sets it separately.
    func renditionParameters(from previous: Self?) -> String {
        let base = previous.flatMap { turnsOff($0) ? nil : $0 }
        var parameters = base == nil ? "0" : ""
        let from = base ?? Self()
        func add(_ code: String) { parameters += parameters.isEmpty ? code : ";" + code }
        if bold && !from.bold { add("1") }
        if dim && !from.dim { add("2") }
        if italic && !from.italic { add("3") }
        if underline != from.underline { add(underline == .single ? "4" : "4:" + String(underline.rawValue)) }
        if blink && !from.blink { add("5") }
        if inverse && !from.inverse { add("7") }
        if invisible && !from.invisible { add("8") }
        if strikethrough && !from.strikethrough { add("9") }
        if overline && !from.overline { add("53") }
        func add(_ color: Terminal.Color, replacing old: Terminal.Color, _ selector: Int) {
            guard color != old else { return }
            switch color {
            case .default: break
            // The 16 colors have their own parameters, 30 to 37 and 90 to 97 for the text and 40 to 47
            // and 100 to 107 for the background. The underline color has none.
            case .indexed(let index) where index < 16 && selector != 58:
                add(String(selector - 8 + (index < 8 ? Int(index) : Int(index) + 52)))
            case .indexed(let index): add(String(selector) + ";5;" + String(index))
            case .rgb(let r, let g, let b): add(String(selector) + ";2;" + String(r) + ";" + String(g) + ";" + String(b))
            }
        }
        add(foreground, replacing: from.foreground, 38)
        add(background, replacing: from.background, 48)
        add(underlineColor, replacing: from.underlineColor, 58)
        return parameters
    }

    /// Whether this style turns off a rendition `previous` has. Returning a color or the underline to
    /// its default turns it off, while changing it to another replaces it.
    private func turnsOff(_ previous: Self) -> Bool {
        previous.bold && !bold || previous.dim && !dim || previous.italic && !italic
            || previous.blink && !blink || previous.inverse && !inverse || previous.invisible && !invisible
            || previous.strikethrough && !strikethrough || previous.overline && !overline
            || previous.underline != .none && underline == .none
            || previous.foreground != .default && foreground == .default
            || previous.background != .default && background == .default
            || previous.underlineColor != .default && underlineColor == .default
    }
}
