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
        // A colon group belongs to one parameter. Its contents finish the color, even
        // when some components are missing. The next semicolon starts another rendition.
        if parameters.hasSubparameters, parameters.subparameterCount(at: index) > 0 {
            let mode = parameters[parameter: index, subparameter: 0] ?? 0
            return colonColor(mode, parameters, at: index, first: 1)
        }

        index += 1
        let mode = parameters[index]
        if parameters.hasSubparameters, parameters.subparameterCount(at: index) > 0 {
            // Mixed forms such as 38;2::r:g:b attach the colon group to the mode.
            return colonColor(mode, parameters, at: index, first: 0)
        }

        switch mode {
        case 5:
            // 38;5;n selects a palette index.
            index += 1
            return .indexed(byte(parameters[index]))
        case 2:
            // 38;2;r;g;b gives the three components directly. A colon group on red
            // or green supplies the remaining components in that same parameter.
            index += 1
            let red = byte(parameters[index])
            if parameters.hasSubparameters, parameters.subparameterCount(at: index) > 0 {
                return .rgb(red, byte(parameters[parameter: index, subparameter: 0]),
                            byte(parameters[parameter: index, subparameter: 1]))
            }
            index += 1
            let green = byte(parameters[index])
            if parameters.hasSubparameters, parameters.subparameterCount(at: index) > 0 {
                return .rgb(red, green, byte(parameters[parameter: index, subparameter: 0]))
            }
            index += 1
            return .rgb(red, green, byte(parameters[index]))
        default:
            // An unknown mode still consumes its operand. Zero keeps the extra
            // color-space field. A colon group or end of input ends either form early.
            for _ in 0..<(mode == 0 ? 5 : 4) {
                index += 1
                if index >= parameters.count || parameters.subparameterCount(at: index) > 0 { break }
            }
            return nil
        }
    }

    private static func colonColor(_ mode: Int, _ parameters: ControlParameters, at index: Int,
                                   first: Int) -> Terminal.Color? {
        switch mode {
        case 5:
            // 38:5:n
            return .indexed(byte(parameters[parameter: index, subparameter: first]))
        case 2:
            // 38:2:cs:r:g:b. The color-space field may be empty.
            return .rgb(byte(parameters[parameter: index, subparameter: first + 1]),
                        byte(parameters[parameter: index, subparameter: first + 2]),
                        byte(parameters[parameter: index, subparameter: first + 3]))
        default:
            return nil
        }
    }

    private static func byte(_ value: Int?) -> UInt8 {
        UInt8(truncatingIfNeeded: value ?? 0)
    }
}
