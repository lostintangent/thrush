import Metal
import ThrushCore

struct Quad {
    var rect: SIMD4<Float>
    var uv: SIMD4<Float> = .zero
    var paint: SIMD4<UInt32>
}

struct RowGeometry {
    struct Batch {
        let texture: any MTLTexture
        let first: Int
        var count: Int
    }
    var buffer: (any MTLBuffer)?
    var batches: [Batch] = []
}

/// Build one immutable, row-local vertex buffer. Colors remain palette references until drawing.
struct RowBuilder {
    let metrics: GridMetrics
    let atlas: GlyphAtlas
    let solid: any MTLTexture
    private var quads: [Quad] = []
    private var batches: [RowGeometry.Batch] = []

    init(metrics: GridMetrics, atlas: GlyphAtlas, solid: any MTLTexture) {
        self.metrics = metrics
        self.atlas = atlas
        self.solid = solid
    }

    mutating func cell(_ cell: Terminal.Cell, column: Int, availableWidth: Int, underCursor: Bool = false, selected: Bool = false) throws {
        let x = metrics.x(column)
        let width = metrics.x(column + min(max(1, cell.width), availableWidth)) - x
        let height = Float(metrics.rowHeightPixels)
        let style = cell.style
        var ink = Paint.token(style.foreground, default: Paint.foreground)
        var paper = Paint.token(style.background, default: Paint.background)
        if style.inverse { swap(&ink, &paper) }
        if selected { ink = Paint.selectionInk; paper = Paint.selection }
        if underCursor { ink = selected ? Paint.selection : Paint.cursorInk; paper = selected ? Paint.selectionInk : Paint.cursor }
        if paper != Paint.background {
            fill(x: x, y: 0, width: width, height: height, color: paper)
        }
        guard !style.invisible else { return }
        if !cell.text.isEmpty, cell.text != " " {
            let key = GlyphKey(text: cell.text, width: max(1, cell.width), bold: style.bold, italic: style.italic)
            let glyph = try atlas.glyph(for: key)
            // Sample one atlas pixel per backing pixel, even when cumulative snapping
            // leaves this cell one pixel narrower than the tile.
            let drawnWidth = min(width, glyph.pixelSize.x)
            let rect = SIMD4(x, 0, drawnWidth, height)
            var uv = glyph.uv
            uv.z *= drawnWidth / glyph.pixelSize.x
            append(Quad(rect: rect, uv: uv, paint: SIMD4(ink, glyph.isColor ? 2 : 1, style.dim ? 1 : 0, 0)),
                   texture: glyph.texture)
        }
        let rule = max(1, Float(metrics.scale.rounded()))
        if style.underline { fill(x: x, y: height - rule, width: width, height: rule, color: ink) }
        if style.strikethrough { fill(x: x, y: (height * 0.52).rounded(), width: width, height: rule, color: ink) }
    }

    mutating func fill(x: Float, y: Float, width: Float, height: Float, color: UInt32) {
        append(Quad(rect: SIMD4(x, y, width, height), paint: SIMD4(color, 0, 0, 0)), texture: nil)
    }

    private mutating func append(_ quad: Quad, texture: (any MTLTexture)?) {
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
        return RowGeometry(buffer: buffer, batches: batches)
    }
}
