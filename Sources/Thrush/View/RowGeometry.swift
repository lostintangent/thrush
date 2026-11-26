import Metal
import ThrushCore

/// One instanced rectangle in a row's vertex buffer. Its layout matches `Quad` in the shader source
/// in ShaderPipeline.swift field for field, so the GPU reads these bytes directly.
struct Quad {
    var rect: SIMD4<Float>
    var uv: SIMD4<Float> = .zero
    var paint: SIMD4<UInt32>
}

/// What the shader draws for a quad, from its second paint component.
enum Material {
    static let solid: UInt32 = 0
    /// A glyph's coverage in the atlas, colored with the quad's ink.
    static let mask: UInt32 = 1
    /// A color glyph, such as an emoji, drawn as the atlas holds it.
    static let color: UInt32 = 2
    static let curl: UInt32 = 3
    static let dots: UInt32 = 4
}

/// Bits in a quad's third paint component. The shader turns each into an alpha multiplier.
enum Effect {
    static let dim: UInt32 = 1
    /// The quad takes the frame's blink opacity, so a blink redraws no rows.
    static let blink: UInt32 = 2
    /// A link's resting mark, quieter than the text it marks.
    static let linkMark: UInt32 = 4
    /// The wash a pressed link lays over its cells.
    static let press: UInt32 = 8
}

/// How a cell shows the link its text belongs to.
enum LinkMark {
    case none
    /// A quiet dashed underline, unless the program underlines the text itself.
    case resting
    /// A solid underline in the text's full ink, as under the pointer with ⌘ held.
    case engaged
    /// Engaged, with a wash over the cell while a finger or click holds the link down.
    case pressed
    /// Out of the grid while a copy of the link is lifted into its menu. Like concealed text, the cell
    /// keeps its background, selection and cursor.
    case lifted
}

/// The links on one row that its cells' styles don't name: the addresses found in its text, and the
/// columns of the engaged link.
struct RowLinks: Hashable {
    var found: [Range<Int>] = []
    var engaged: [Range<Int>] = []
    /// How the engaged link's columns show.
    var engagedMark = LinkMark.engaged

    func mark(at column: Int, inProgramLink: Bool) -> LinkMark {
        if engaged.contains(where: { $0.contains(column) }) { return engagedMark }
        return inProgramLink || found.contains(where: { $0.contains(column) }) ? .resting : .none
    }
}

struct RowGeometry {
    struct Batch {
        let texture: any MTLTexture
        let first: Int
        var count: Int
    }
    var buffer: (any MTLBuffer)?
    var batches: [Batch] = []
    /// Whether any of the row's ink blinks.
    var blinks = false
}

/// Build one immutable, row-local vertex buffer. Colors remain palette references until drawing.
struct RowBuilder {
    let metrics: GridMetrics
    let atlas: GlyphAtlas
    let solid: any MTLTexture
    private var quads: [Quad] = []
    private var batches: [RowGeometry.Batch] = []
    private var blinks = false

    init(metrics: GridMetrics, atlas: GlyphAtlas, solid: any MTLTexture) {
        self.metrics = metrics
        self.atlas = atlas
        self.solid = solid
    }

    mutating func cell(_ cell: Terminal.Cell, column: Int, availableWidth: Int, underCursor: Bool = false, selected: Bool = false,
                       link: LinkMark = .none) throws {
        let x = metrics.x(column)
        let columns = min(max(1, cell.width), availableWidth)
        let width = metrics.x(column + columns) - x
        let height = Float(metrics.rowHeightPixels)
        let style = cell.style
        var ink = Paint.token(style.foreground, default: Paint.foreground)
        var paper = Paint.token(style.background, default: Paint.background)
        if style.inverse { swap(&ink, &paper) }
        var underline = Paint.token(style.underlineColor, default: ink)
        if selected { ink = Paint.selectionInk; paper = Paint.selection }
        if underCursor { ink = selected ? Paint.selection : Paint.cursorInk; paper = selected ? Paint.selectionInk : Paint.cursor }
        let engaged = link == .engaged || link == .pressed
        if selected || underCursor || engaged { underline = ink }
        if paper != Paint.background {
            fill(x: x, y: 0, width: width, height: height, color: paper)
        }
        if link == .pressed { fill(x: x, y: 0, width: width, height: height, color: Paint.foreground, effects: Effect.press) }
        // Concealed text keeps its background, selection and cursor. Copy still includes it.
        guard !style.invisible, link != .lifted else { return }
        // The cell being edited stays legible, so the cursor holds its glyph steady.
        let effects = (style.dim ? Effect.dim : 0) | (style.blink && !underCursor ? Effect.blink : 0)
        if !cell.text.isEmpty, cell.text != " " {
            let key = GlyphKey(text: cell.text, width: max(1, cell.width), bold: style.bold, italic: style.italic)
            let glyph = try atlas.glyph(for: key)
            // Sample one atlas pixel per backing pixel, even when cumulative snapping
            // leaves this cell one pixel narrower than the tile.
            let drawnWidth = min(width, glyph.pixelSize.x)
            let rect = SIMD4(x, 0, drawnWidth, height)
            var uv = glyph.uv
            uv.z *= drawnWidth / glyph.pixelSize.x
            append(Quad(rect: rect, uv: uv, paint: SIMD4(ink, glyph.isColor ? Material.color : Material.mask, effects, 0)),
                   texture: glyph.texture)
        }
        let line = metrics.decorations
        switch engaged ? .single : style.underline {
        case .none:
            if link == .resting { dashes(column..<(column + columns), color: underline, effects: effects | Effect.linkMark) }
        case .single:
            fill(x: x, y: line.underline, width: width, height: line.thickness, color: underline, effects: effects)
        case .double:
            for y in [line.underline, line.underline + line.band - line.doubleThickness] {
                fill(x: x, y: y, width: width, height: line.doubleThickness, color: underline, effects: effects)
            }
        case .curly:
            pattern(Material.curl, x: x, y: line.underline, width: width, height: line.band, color: underline, effects: effects)
        case .dotted:
            pattern(Material.dots, x: x, y: line.underline, width: width, height: line.thickness, color: underline, effects: effects)
        case .dashed:
            dashes(column..<(column + columns), color: underline, effects: effects)
        }
        if style.strikethrough {
            fill(x: x, y: line.strikethrough, width: width, height: line.thickness, color: ink, effects: effects)
        }
        if style.overline { fill(x: x, y: line.overline, width: width, height: line.thickness, color: ink, effects: effects) }
    }

    mutating func fill(x: Float, y: Float, width: Float, height: Float, color: UInt32, effects: UInt32 = 0) {
        append(Quad(rect: SIMD4(x, y, width, height), paint: SIMD4(color, Material.solid, effects, 0)), texture: nil)
    }

    /// An underline whose columns each clear their middle third, so every dash bridges two cells rather than
    /// sitting under one like an underscore, and the dashes keep the grid's rhythm.
    private mutating func dashes(_ columns: Range<Int>, color: UInt32, effects: UInt32) {
        let line = metrics.decorations
        for c in columns {
            let left = metrics.x(c), right = metrics.x(c + 1)
            let gap = ((right - left) / 3).rounded(), start = left + ((right - left - gap) / 2).rounded()
            for (from, to) in [(left, start), (start + gap, right)] {
                fill(x: from, y: line.underline, width: to - from, height: line.thickness, color: color, effects: effects)
            }
        }
    }

    /// A curl or dots across one band of the row. The shader reads each pixel's offset from the grid's
    /// left edge and from the band's center.
    private mutating func pattern(_ material: UInt32, x: Float, y: Float, width: Float, height: Float,
                                  color: UInt32, effects: UInt32) {
        let uv = SIMD4(x - metrics.x(0), -height / 2, width, height)
        append(Quad(rect: SIMD4(x, y, width, height), uv: uv, paint: SIMD4(color, material, effects, 0)), texture: nil)
    }

    private mutating func append(_ quad: Quad, texture: (any MTLTexture)?) {
        if quad.paint.z & Effect.blink != 0 { blinks = true }
        // A solid rectangle can use whichever atlas page is bound.
        if let last = batches.last, texture == nil || last.texture === texture {
            batches[batches.count - 1].count += 1
        } else {
            batches.append(.init(texture: texture ?? solid, first: quads.count, count: 1))
        }
        quads.append(quad)
    }

    func finish(device: any MTLDevice) throws -> RowGeometry {
        guard !quads.isEmpty else { return RowGeometry() }
        guard let buffer = quads.withUnsafeBytes({ bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }) else { throw RendererFailure.allocation }
        return RowGeometry(buffer: buffer, batches: batches, blinks: blinks)
    }
}
