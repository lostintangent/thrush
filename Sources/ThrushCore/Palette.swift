// Defines the default, indexed and RGB colors of a terminal theme. Drawing and replies
// to a program’s color queries use the same palette, under any colors the program set.

extension Terminal {
    /// An sRGB color with 8-bit channels.
    public struct RGB: Equatable, Sendable {
        /// The red channel, from 0 through 255.
        public let red: UInt8
        /// The green channel, from 0 through 255.
        public let green: UInt8
        /// The blue channel, from 0 through 255.
        public let blue: UInt8

        /// Creates an opaque sRGB color from three 8-bit channel values.
        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// The cursor color when the app's theme supplies none.
        package static let white = RGB(0xffffff)

        fileprivate init(_ packed: UInt32) {
            self.init(red: UInt8(packed >> 16), green: UInt8(truncatingIfNeeded: packed >> 8),
                      blue: UInt8(truncatingIfNeeded: packed))
        }
    }

    /// The terminal's default foreground and background colors and its 16 configurable ANSI colors.
    public struct Palette: Equatable, Sendable {
        /// The default text color, also reported to programs that query the foreground.
        public let foreground: RGB
        /// The default canvas color, also reported to programs that query the background.
        public let background: RGB
        /// The eight standard ANSI colors in index order, followed by their eight bright variants.
        public let ansi: [RGB]

        /// Creates a palette with the given default colors and exactly 16 ANSI entries in index order.
        public init(foreground: RGB, background: RGB, ansi: [RGB]) {
            precondition(ansi.count == 16, "A terminal palette has 16 ANSI colors")
            self.foreground = foreground
            self.background = background
            self.ansi = ansi
        }

        /// White text on a black background with the Tango ANSI colors.
        package static let `default` = Self(
            foreground: RGB(0xffffff), background: RGB(0x000000),
            ansi: [
                0x2e3436, 0xcc0000, 0x4e9a06, 0xc4a000, 0x3465a4, 0x75507b, 0x06989a, 0xd3d7cf,
                0x555753, 0xef2929, 0x8ae234, 0xfce94f, 0x729fcf, 0xad7fa8, 0x34e2e2, 0xeeeeec,
            ].map(RGB.init)
        )

        /// The color at an index in the 256-color terminal palette.
        ///
        /// Indices 0–15 use ``ansi``, 16–231 use a 6 × 6 × 6 color cube, and 232–255 use a gray ramp.
        package subscript(index index: UInt8) -> RGB {
            if index < 16 { return ansi[Int(index)] }
            if index >= 232 {
                let gray = 8 + (index - 232) * 10
                return RGB(red: gray, green: gray, blue: gray)
            }
            let cube = index - 16
            func intensity(_ coordinate: UInt8) -> UInt8 { coordinate == 0 ? 0 : 55 + 40 * coordinate }
            return RGB(red: intensity(cube / 36), green: intensity((cube / 6) % 6), blue: intensity(cube % 6))
        }
    }
}

