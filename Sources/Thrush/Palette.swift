extension Terminal {
    /// An sRGB color with 8-bit channels.
    public struct RGB: Equatable, Sendable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        fileprivate init(_ packed: UInt32) {
            self.init(red: UInt8(packed >> 16), green: UInt8(truncatingIfNeeded: packed >> 8),
                      blue: UInt8(truncatingIfNeeded: packed))
        }
    }

    /// The host's active default colors and 16 ANSI entries. Extended indices use the xterm cube and gray ramp.
    public struct Palette: Equatable, Sendable {
        public let foreground: RGB
        public let background: RGB
        public let ansi: [RGB]

        public init(foreground: RGB, background: RGB, ansi: [RGB]) {
            precondition(ansi.count == 16, "A terminal palette has 16 ANSI colors")
            self.foreground = foreground
            self.background = background
            self.ansi = ansi
        }

        /// The pinned browser terminal's colors when the host supplies no theme.
        public static let `default` = Self(
            foreground: RGB(0xffffff), background: RGB(0x000000),
            ansi: [
                0x2e3436, 0xcc0000, 0x4e9a06, 0xc4a000, 0x3465a4, 0x75507b, 0x06989a, 0xd3d7cf,
                0x555753, 0xef2929, 0x8ae234, 0xfce94f, 0x729fcf, 0xad7fa8, 0x34e2e2, 0xeeeeec,
            ].map(RGB.init)
        )

        /// A 256-color index: the 16 ANSI entries, then the 6 × 6 × 6 cube and the 24-step gray ramp.
        public subscript(index index: UInt8) -> RGB {
            if index < 16 { return ansi[Int(index)] }
            if index >= 232 {
                let gray = 8 + (index - 232) * 10
                return RGB(red: gray, green: gray, blue: gray)
            }
            let cube = index - 16
            func intensity(_ coordinate: UInt8) -> UInt8 { coordinate == 0 ? 0 : 55 + 40 * coordinate }
            return RGB(red: intensity(cube / 36), green: intensity((cube / 6) % 6), blue: intensity(cube % 6))
        }

        func appendReplies(to output: inout [UInt8], for queries: [ColorQuery]) {
            for query in queries {
                let color: RGB
                switch query {
                case .indexed(let index):
                    output.append(contentsOf: "\u{1b}]4;".utf8)
                    output.append(contentsOf: String(index).utf8)
                    color = self[index: index]
                case .foreground:
                    output.append(contentsOf: "\u{1b}]10".utf8)
                    color = foreground
                case .background:
                    output.append(contentsOf: "\u{1b}]11".utf8)
                    color = background
                }
                output.append(contentsOf: ";rgb:".utf8)
                Self.appendChannel(color.red, to: &output)
                output.append(0x2f)
                Self.appendChannel(color.green, to: &output)
                output.append(0x2f)
                Self.appendChannel(color.blue, to: &output)
                output.append(contentsOf: [0x1b, 0x5c])
            }
        }

        private static func appendChannel(_ channel: UInt8, to output: inout [UInt8]) {
            func hex(_ digit: UInt8) -> UInt8 { digit < 10 ? 48 + digit : 87 + digit }
            let high = hex(channel >> 4)
            let low = hex(channel & 15)
            // Replicating the 8-bit value gives xterm's four-digit, 16-bit channel.
            output.append(contentsOf: [high, low, high, low])
        }
    }
}

enum ColorQuery: Sendable {
    case indexed(UInt8), foreground, background
}
