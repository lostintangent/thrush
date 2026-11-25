// Applies Select Graphic Rendition (SGR) parameters to the style used for subsequent text.
// A single command can change several attributes, so its fields take effect in order.

extension Terminal.Style {
    /// Update attributes independently so one SGR sequence can combine colors and emphasis.
    mutating func applySGR(_ parameters: ControlParameters) {
        var index = 0
        while index < parameters.count {
            let parameter = parameters[index]
            switch parameter {
            case 0: self = .init()
            case 1: bold = true
            case 2: dim = true
            case 7: inverse = true
            case 22:
                bold = false
                dim = false
            case 23: italic = false
            case 27: inverse = false
            case 29: strikethrough = false
            case 30...37: foreground = .indexed(UInt8(parameter - 30))
            case 40...47: background = .indexed(UInt8(parameter - 40))
            case 90...97: foreground = .indexed(UInt8(parameter - 90 + 8))
            case 100...107: background = .indexed(UInt8(parameter - 100 + 8))
            case 39: foreground = .default
            case 49: background = .default
            case 38, 48, 58:
                // Consume underline color (58) as one operand even though the grid does not display it.
                if let color = Self.extendedColor(parameters, index: &index) {
                    if parameter == 38 { foreground = color }
                    if parameter == 48 { background = color }
                }
            default: break
            }
            index += 1
        }
    }

    private static func extendedColor(_ parameters: ControlParameters, index: inout Int) -> Terminal.Color? {
        // ISO 8613-6 orders these fields as target, mode, color space, and up to three components.
        // Semicolon colors and indexed colors omit the color-space slot. A colon group ends the
        // operand, leaving the following semicolon parameter available for another SGR command.
        var fields: InlineArray<6, Int> = [0, 0, 0, 0, 0, 0]
        var slot = 0
        repeat {
            fields[slot] = parameters[index]
            let subparameterCount = parameters.subparameterCount(at: index)
            if subparameterCount > 0 {
                for ordinal in 0..<subparameterCount {
                    slot += 1
                    if slot == 2 && fields[1] == 5 { slot += 1 }
                    guard slot < fields.count else { break }
                    fields[slot] = parameters[parameter: index, subparameter: ordinal] ?? 0
                }
                break
            }
            if fields[1] == 5 && slot >= 3 || fields[1] == 2 && slot == 5 { break }
            index += 1
            slot += 1
            if slot == 2 && fields[1] != 0 { slot += 1 }
        } while index < parameters.count && slot < fields.count

        switch fields[1] {
        case 5: return .indexed(UInt8(truncatingIfNeeded: fields[3]))
        case 2: return .rgb(UInt8(truncatingIfNeeded: fields[3]),
                            UInt8(truncatingIfNeeded: fields[4]),
                            UInt8(truncatingIfNeeded: fields[5]))
        default:
            return nil
        }
    }
}
