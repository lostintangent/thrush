import Foundation
import ThrushCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The terminal's palette and the colors used to draw its cursor and selection.
/// To customize the built-in themes, edit a copy of `dark` or `light` and pass it to the terminal view.
public struct TerminalTheme: Equatable, Sendable {
    /// The default text, background and ANSI colors. The terminal view uses this palette for OSC color replies.
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
    public static let dark = TerminalTheme(
        palette: .init(foreground: rgb(0xe3eaf0), background: rgb(0x131d27), ansi: [
            0x0b1016, 0xe28282, 0x93cba2, 0xdebb7b, 0x88b6e5, 0xbba0d7, 0x78c4ce, 0xc1cdd4,
            0x8697a4, 0xf49c98, 0xb2dfb5, 0xf2d69c, 0xa9cfff, 0xd3b9f2, 0x9ce0e4, 0xf4f7f9
        ].map(rgb)), cursor: rgb(0xfd9a01), cursorInk: rgb(0x131d27), selection: rgb(0x466b85),
        selectionInk: rgb(0xf8fbfe)
    )

    /// The default terminal theme for a light system appearance.
    public static let light = TerminalTheme(
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

    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}

#if os(macOS)
extension NSColor {
    convenience init(terminal color: Terminal.RGB) {
        self.init(cgColor: color.cgColor)!
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
#else
extension UIColor {
    convenience init(terminal color: Terminal.RGB) {
        self.init(cgColor: color.cgColor)
    }
}
#endif

/// The first 256 entries hold indexed terminal colors. A direct RGB token bypasses this table.
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

    /// The program's colors replace the theme's where it set them. Selection stays on the theme.
    static func table(_ theme: TerminalTheme, _ program: Terminal.ProgramColors) -> [SIMD4<Float>] {
        func color(_ slot: Terminal.ColorSlot) -> Terminal.RGB {
            program.resolve(slot, palette: theme.palette, cursor: theme.cursor)
        }
        let foreground = color(.foreground), background = color(.background)
        // The theme's ink suits only the theme's cursor. Under a program's, keep the glyph readable.
        let cursorInk = program[.cursor].map {
            $0.contrast(with: foreground) > $0.contrast(with: background) ? foreground : background
        } ?? theme.cursorInk
        var colors = (0...255).map { color(.indexed(UInt8($0))).vector }
        colors += [foreground, background, color(.cursor), cursorInk, theme.selection, theme.selectionInk].map(\.vector)
        return colors
    }
}

extension Terminal.RGB {
    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ component: UInt8) -> Double {
            let value = Double(component) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, from 1 to 21.
    func contrast(with other: Terminal.RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Whether white text contrasts more than black on this color.
    var isDark: Bool { contrast(with: .init(red: 255, green: 255, blue: 255)) > contrast(with: .init(red: 0, green: 0, blue: 0)) }
}

// Colors for native controls beside the canvas. The opaque backing replaces glass under Reduce Transparency.
package extension TerminalTheme {
    var opaqueBacking: Terminal.RGB {
        if self == .dark { return .init(red: 0x1D, green: 0x29, blue: 0x34) }
        if self == .light { return .init(red: 0xE8, green: 0xEE, blue: 0xF1) }
        return .init(red: 0x2A, green: 0x27, blue: 0x24)
    }
}
