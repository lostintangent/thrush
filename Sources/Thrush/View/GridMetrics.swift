import CoreGraphics
import CoreText
import ThrushCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Geometry inside the usable native view. Bounds arrive in points; Metal gets pixel edges.
struct GridMetrics {
    let scale: CGFloat
    let pointSize: CGFloat
    let font: CTFont
    let advancePixels: CGFloat
    let baselinePixels: Int
    let rowHeightPixels: Int
    let decorations: Decorations
    private let insetX: CGFloat
    private let insetY: CGFloat

    init(scale: CGFloat, pointSize: CGFloat? = nil) {
        precondition(scale.isFinite && scale > 0)
        #if os(macOS)
        let defaultSize: CGFloat = 14
        let insets = CGPoint(x: 12, y: 10)
        #else
        let defaultSize: CGFloat = 13
        let insets = CGPoint(x: 10, y: 8)
        #endif
        let size = pointSize ?? defaultSize
        precondition(size.isFinite && size > 0)
        self.scale = scale
        self.pointSize = size
        #if os(macOS)
        font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        #else
        font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        #endif
        var digit: UniChar = 0x30
        var glyph: CGGlyph = 0
        precondition(CTFontGetGlyphsForCharacters(font, &digit, &glyph, 1))
        advancePixels = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1) * scale
        rowHeightPixels = max(1, Int((18 * size / defaultSize * scale).rounded()))
        baselinePixels = Int((ceil(CTFontGetAscent(font)) * scale).rounded())
        decorations = Decorations(font: font, scale: scale, baseline: CGFloat(baselinePixels), row: CGFloat(rowHeightPixels))
        insetX = (insets.x * scale).rounded()
        insetY = (insets.y * scale).rounded()
    }

    /// Lines drawn with text, in whole pixels from the row's top. Underlines take the font's own position
    /// and thickness. A double underline's two thinner lines bound a band below the underline's top, and a
    /// curly one waves across that same band, so every underline stays inside its row.
    struct Decorations {
        let thickness: Float
        let underline: Float
        let band: Float
        let doubleThickness: Float
        let strikethrough: Float
        let overline: Float

        init(font: CTFont, scale: CGFloat, baseline: CGFloat, row: CGFloat) {
            let fontThickness = CTFontGetUnderlineThickness(font) * scale
            let thickness = max(1, fontThickness.rounded(.up))
            let thin = max(1, (thickness / 2).rounded())
            let band = max(2 * thin + 1, (thickness + 2 * fontThickness).rounded())
            let center = baseline - CTFontGetUnderlinePosition(font) * scale
            self.thickness = Float(thickness)
            underline = Float(min((center - thickness / 2).rounded(), row - band))
            self.band = Float(band)
            doubleThickness = Float(thin)
            strikethrough = Float((baseline - CTFontGetXHeight(font) * scale / 2 - thickness / 2).rounded())
            // An overline clears the ascenders by the underline's own gap below the baseline, so it reads
            // with its own row rather than as an underline of the row above.
            var ascender: CGGlyph = 0
            var letter: UniChar = 0x6c  // l
            precondition(CTFontGetGlyphsForCharacters(font, &letter, &ascender, 1))
            let top = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &ascender, nil, 1).maxY * scale
            let gap = CGFloat(underline) - baseline
            overline = Float(max(0, (baseline - top - gap - thickness).rounded()))
        }

        /// How far a curly underline's center swings above and below the middle of its band.
        var curl: Float { (band - thickness) / 2 }
    }

    func x(_ column: Int) -> Float {
        Float(insetX + (CGFloat(column) * advancePixels).rounded())
    }

    func y(_ row: Int) -> Float {
        Float(insetY) + Float(row * rowHeightPixels)
    }

    func size(in bounds: CGSize) -> Terminal.Size {
        let width = max(0, (bounds.width * scale).rounded() - 2 * insetX)
        let height = max(0, (bounds.height * scale).rounded() - 2 * insetY)
        // Count the same rounded edges the renderer uses. A subpixel remainder can
        // still fit the next edge when the cumulative advance rounds down.
        let columns = Int(ceil((width + 0.5) / advancePixels)) - 1
        return Terminal.Size(columns: max(2, columns), rows: max(1, Int(height) / rowHeightPixels))
    }
}
