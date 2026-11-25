import ThrushCore

/// The terminal's palette and the colors used to draw its cursor and selection.
/// To customize Slate, edit a copy of `slateDark` or `slateLight` and assign it to the pane or view.
public struct TerminalTheme: Equatable, Sendable {
    /// The default text, background and ANSI colors. The pane uses this palette for OSC color replies.
    public var palette: Terminal.Palette
    /// The color of the block, underline or bar cursor.
    public var cursor: Terminal.RGB
    /// The text color inside a block cursor.
    public var cursorInk: Terminal.RGB
    /// The background color of selected cells.
    public var selection: Terminal.RGB
    /// The text color of selected cells.
    public var selectionInk: Terminal.RGB

    /// Creates a theme from a terminal palette and the cursor and selection colors.
    public init(palette: Terminal.Palette, cursor: Terminal.RGB, cursorInk: Terminal.RGB,
                selection: Terminal.RGB, selectionInk: Terminal.RGB) {
        self.palette = palette
        self.cursor = cursor
        self.cursorInk = cursorInk
        self.selection = selection
        self.selectionInk = selectionInk
    }

    /// The default terminal theme for a dark system appearance.
    public static let slateDark = TerminalTheme(
        palette: .init(foreground: rgb(0xe3eaf0), background: rgb(0x131d27), ansi: [
            0x0b1016, 0xe28282, 0x93cba2, 0xdebb7b, 0x88b6e5, 0xbba0d7, 0x78c4ce, 0xc1cdd4,
            0x8697a4, 0xf49c98, 0xb2dfb5, 0xf2d69c, 0xa9cfff, 0xd3b9f2, 0x9ce0e4, 0xf4f7f9
        ].map(rgb)), cursor: rgb(0xfd9a01), cursorInk: rgb(0x131d27), selection: rgb(0x466b85),
        selectionInk: rgb(0xf8fbfe)
    )

    /// The default terminal theme for a light system appearance.
    public static let slateLight = TerminalTheme(
        palette: .init(foreground: rgb(0x233442), background: rgb(0xfbfdfe), ansi: [
            0x000000, 0xa43d46, 0x30683e, 0x79601c, 0x2b608f, 0x764d80, 0x276a70, 0x6d767c,
            0x586d7b, 0xbb3147, 0x197539, 0x856100, 0x16699e, 0x864887, 0x007278, 0x757575
        ].map(rgb)), cursor: rgb(0x995500), cursorInk: rgb(0xffffff), selection: rgb(0x7391a6),
        selectionInk: rgb(0x101c25)
    )
}

private func rgb(_ hex: UInt32) -> Terminal.RGB {
    Terminal.RGB(red: UInt8(hex >> 16), green: UInt8(truncatingIfNeeded: hex >> 8), blue: UInt8(truncatingIfNeeded: hex))
}

extension Terminal.RGB {
    var vector: SIMD4<Float> {
        SIMD4(Float(red) / 255, Float(green) / 255, Float(blue) / 255, 1)
    }
}

/// The first 256 entries match xterm indexes. A direct RGB token bypasses this table.
enum Paint {
    static let foreground: UInt32 = 256
    static let background: UInt32 = 257
    static let cursor: UInt32 = 258
    static let cursorInk: UInt32 = 259
    static let selection: UInt32 = 260
    static let selectionInk: UInt32 = 261

    static func token(_ color: Terminal.Color, default fallback: UInt32) -> UInt32 {
        switch color {
        case .default: fallback
        case .indexed(let i): UInt32(i)
        case let .rgb(r, g, b): 0x80000000 | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
        }
    }

    static func table(_ theme: TerminalTheme) -> [SIMD4<Float>] {
        var colors = (0...255).map { theme.palette[index: UInt8($0)].vector }
        colors += [theme.palette.foreground, theme.palette.background, theme.cursor, theme.cursorInk,
                   theme.selection, theme.selectionInk].map(\.vector)
        return colors
    }
}

// Opaque backing for native chrome when Reduce Transparency is enabled.
package extension TerminalTheme {
    var hostBacking: Terminal.RGB {
        if self == .slateDark { return .init(red: 0x1D, green: 0x29, blue: 0x34) }
        if self == .slateLight { return .init(red: 0xE8, green: 0xEE, blue: 0xF1) }
        return .init(red: 0x2A, green: 0x27, blue: 0x24)
    }
    var separator: Terminal.RGB {
        if self == .slateDark { return .init(red: 0x35, green: 0x42, blue: 0x4E) }
        if self == .slateLight { return .init(red: 0xB7, green: 0xC3, blue: 0xCA) }
        return .init(red: 0x48, green: 0x41, blue: 0x3B)
    }
}
