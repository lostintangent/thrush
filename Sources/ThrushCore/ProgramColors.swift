// Programs set, query and restore the theme's colors with OSC 4, 10, 11, 12, 104, 110, 111 and 112.
// A set layers over the app's theme until the program restores it, even across a theme change.

extension Terminal {
    /// A theme color that a program can set, query or restore.
    package enum ColorSlot: Hashable, Sendable {
        /// One of the 256 indexed colors.
        case indexed(UInt8)
        /// The default text color.
        case foreground
        /// The default canvas color.
        case background
        /// The cursor color.
        case cursor
    }

    /// The colors a program set over the app's theme.
    package struct ProgramColors: Equatable, Sendable {
        // Empty until a program sets an indexed color, and emptied again once none is set.
        private var indexed: [RGB?] = []
        private var foreground: RGB?
        private var background: RGB?
        private var cursor: RGB?

        package init() {}

        /// True when the theme shows unchanged.
        package var isEmpty: Bool { indexed.isEmpty && foreground == nil && background == nil && cursor == nil }

        /// The program's color for a slot, or nil when the slot shows the theme's color.
        package private(set) subscript(slot: ColorSlot) -> RGB? {
            get {
                switch slot {
                case .indexed(let index): indexed.isEmpty ? nil : indexed[Int(index)]
                case .foreground: foreground
                case .background: background
                case .cursor: cursor
                }
            }
            set {
                switch slot {
                case .indexed(let index):
                    if indexed.isEmpty { indexed = Array(repeating: nil, count: 256) }
                    indexed[Int(index)] = newValue
                    if newValue == nil, !indexed.contains(where: { $0 != nil }) { indexed = [] }
                case .foreground: foreground = newValue
                case .background: background = newValue
                case .cursor: cursor = newValue
                }
            }
        }

        /// The color a slot shows: the program's when it set one, otherwise the theme's.
        package func resolve(_ slot: ColorSlot, palette: Palette, cursor: RGB) -> RGB {
            if let color = self[slot] { return color }
            return switch slot {
            case .indexed(let index): palette[index: index]
            case .foreground: palette.foreground
            case .background: palette.background
            case .cursor: cursor
            }
        }

        /// Applies one command's requests in order and returns whether any color changed. A query
        /// reports the color shown at that point.
        mutating func apply(_ command: ControlFunction.OSC, payload: [UInt8], palette: Palette, cursor: RGB,
                            replies: inout [UInt8]) -> Bool {
            var fields = Fields(payload[...])
            var changed = false
            func set(_ slot: ColorSlot, _ color: RGB?) {
                if self[slot] != color {
                    self[slot] = color
                    changed = true
                }
            }
            func setOrReport(_ slot: ColorSlot, _ specification: Field) {
                if specification.elementsEqual("?".utf8) {
                    replies += (slot.setting(resolve(slot, palette: palette, cursor: cursor), sixteenBit: true) + "\u{1b}\\").utf8
                } else if let color = RGB(specification: specification) {
                    set(slot, color)
                }
            }
            switch command {
            case .indexedColor:
                // Fields pair an index with a specification. A trailing index without one is ignored.
                while let index = fields.next(), fields.rest != nil, let specification = fields.next() {
                    if let index = Self.index(index) { setOrReport(.indexed(index), specification) }
                }
            case .foregroundColor, .backgroundColor, .cursorColor:
                // Each field advances to the next of foreground, background and cursor.
                let first = command == .foregroundColor ? 0 : command == .backgroundColor ? 1 : 2
                for (slot, specification) in zip(Self.defaultSlots[first...], fields) {
                    setOrReport(slot, specification)
                }
            case .restoreIndexedColors where payload.isEmpty:
                changed = !indexed.isEmpty
                indexed = []
            case .restoreIndexedColors:
                for field in fields { if let index = Self.index(field) { set(.indexed(index), nil) } }
            case .restoreForegroundColor: set(.foreground, nil)
            case .restoreBackgroundColor: set(.background, nil)
            case .restoreCursorColor: set(.cursor, nil)
            case .setIconAndWindowTitle, .setWindowTitle, .hyperlink, .clipboard: break
            }
            return changed
        }

        private static let defaultSlots: [ColorSlot] = [.foreground, .background, .cursor]

        // Decimal digits only, with any leading zeros, naming one of the 256 indexed colors.
        private static func index(_ field: Field) -> UInt8? {
            guard !field.isEmpty else { return nil }
            var value = 0
            for byte in field {
                guard (0x30...0x39).contains(byte) else { return nil }
                value = min(256, value * 10 + Int(byte - 0x30))
            }
            return UInt8(exactly: value)
        }
    }
}

extension Terminal.ColorSlot {
    /// The OSC that sets this slot to `color`, without its terminator. A report replicates each 8-bit
    /// channel into the four hex digits of a 16-bit one, and a replay writes just the two it keeps.
    func setting(_ color: Terminal.RGB, sixteenBit: Bool) -> String {
        let number = switch self {
        case .indexed(let index): "4;\(index)"
        case .foreground: "10"
        case .background: "11"
        case .cursor: "12"
        }
        func channel(_ value: UInt8) -> String {
            let hex = (value < 16 ? "0" : "") + String(value, radix: 16)
            return sixteenBit ? hex + hex : hex
        }
        return "\u{1b}]\(number);rgb:\(channel(color.red))/\(channel(color.green))/\(channel(color.blue))"
    }
}

extension Terminal.RGB {
    /// Parses `rgb:` and three slash-separated channels of one to four hex digits each, all the
    /// same width, or `#` and 3, 6, 9 or 12 hex digits, ignoring letter case. Color names are not
    /// supported.
    fileprivate init?(specification: Field) {
        let start = specification.startIndex, count = specification.count
        let isHash = specification.first == UInt8(ascii: "#")
        let channels: (Field, Field, Field)
        if isHash {
            let width = (count - 1) / 3, green = start + 1 + width, blue = green + width
            guard (1...4).contains(width), count == 1 + 3 * width else { return nil }
            channels = (specification[(start + 1)..<green], specification[green..<blue], specification[blue...])
        } else {
            guard count > 4, zip(specification, "rgb:".utf8).allSatisfy({ Self.lowercased($0) == $1 }),
                  let first = specification[(start + 4)...].firstIndex(of: UInt8(ascii: "/")),
                  let second = specification[(first + 1)...].firstIndex(of: UInt8(ascii: "/")) else { return nil }
            channels = (specification[(start + 4)..<first], specification[(first + 1)..<second],
                        specification[(second + 1)...])
            let width = channels.0.count
            guard (1...4).contains(width), channels.1.count == width, channels.2.count == width else { return nil }
        }
        guard let red = Self.channel(channels.0, isHash: isHash), let green = Self.channel(channels.1, isHash: isHash),
              let blue = Self.channel(channels.2, isHash: isHash) else { return nil }
        self.init(red: red, green: green, blue: blue)
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 { (0x41...0x5a).contains(byte) ? byte | 0x20 : byte }

    private static func channel(_ digits: Field, isHash: Bool) -> UInt8? {
        var value = 0
        for byte in digits {
            switch lowercased(byte) {
            case let digit where (0x30...0x39).contains(digit): value = value << 4 | Int(digit - 0x30)
            case let digit where (0x61...0x66).contains(digit): value = value << 4 | Int(digit - 0x57)
            default: return nil
            }
        }
        let width = digits.count
        // Hash notation keeps the high bits of each channel, so #abc is a0, b0, c0.
        if isHash { return UInt8(truncatingIfNeeded: width == 1 ? value << 4 : value >> (4 * width - 8)) }
        // `rgb:` scales each channel to 8 bits, rounding to the nearest value.
        let maximum = 1 << (4 * width) - 1
        return UInt8((value * 510 + maximum) / (2 * maximum))
    }
}
