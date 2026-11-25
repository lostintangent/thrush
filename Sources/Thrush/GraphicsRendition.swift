extension Terminal.Style {
    /// Update attributes independently so one SGR sequence can combine colors and emphasis.
    mutating func applySGR(_ parameters: [Int]) {
        var index = 0
        while index < parameters.count {
            let parameter = parameters[index]
            index += 1
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
            case 38, 48:
                guard let color = Self.extendedColor(parameters, index: &index) else { return }
                if parameter == 38 { foreground = color } else { background = color }
            default: break
            }
        }
    }

    private static func extendedColor(_ parameters: [Int], index: inout Int) -> Terminal.Color? {
        guard index < parameters.count else { return nil }
        switch parameters[index] {
        case 5 where index + 1 < parameters.count:
            index += 2
            return .indexed(UInt8(truncatingIfNeeded: parameters[index - 1]))
        case 2 where index + 3 < parameters.count:
            let red = UInt8(truncatingIfNeeded: parameters[index + 1])
            let green = UInt8(truncatingIfNeeded: parameters[index + 2])
            let blue = UInt8(truncatingIfNeeded: parameters[index + 3])
            index += 4
            return .rgb(red, green, blue)
        default:
            return nil
        }
    }
}
