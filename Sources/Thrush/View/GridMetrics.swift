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
        insetX = (insets.x * scale).rounded()
        insetY = (insets.y * scale).rounded()
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
