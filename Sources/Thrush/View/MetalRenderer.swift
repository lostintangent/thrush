import Foundation
import MetalKit
import ThrushCore

enum RendererFailure: Error {
    case allocation, missingEncoder
}

@MainActor
final class MetalRenderer {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let solid: any MTLTexture
    private var colorTable: (any MTLBuffer)?
    private struct Colors: Equatable {
        let theme: TerminalTheme
        let program: Terminal.ProgramColors
    }
    private var tableColors: Colors?
    private var atlas: GlyphAtlas?
    private struct RowKey: Hashable {
        let revision: UInt64
        let selection: Range<Int>?
    }
    private var cached: [RowKey: RowGeometry] = [:]
    private var priorSize: Terminal.Size?
    private var priorBase: Bool?

    init(device: any MTLDevice, pipeline: ShaderPipeline) throws {
        self.device = device
        guard let queue = device.makeCommandQueue(),
              let solid = device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                              width: 1, height: 1, mipmapped: false))
        else { throw RendererFailure.allocation }
        self.queue = queue
        self.solid = solid
        self.pipeline = pipeline.state
    }

    func discardGeometry() { cached.removeAll() }
    func discardResources() { discardGeometry(); atlas = nil }

    struct Prepared {
        let buffer: any MTLCommandBuffer
        let rowsPrepared: Int
        let glyphUploads: Int
        /// Whether the frame drew any blinking ink.
        let blinks: Bool
    }

    /// Encode one frame. Blinking ink takes `blinkOpacity`, so a blink reuses every cached row.
    func encode(snapshot: Terminal.Snapshot?, metrics: GridMetrics, theme: TerminalTheme,
                pass: MTLRenderPassDescriptor, viewport: CGSize, selection: TerminalView.Selection? = nil,
                showsCursor: Bool = true, blinkOpacity: Float = 1) throws -> Prepared {
        // Rows keep color tokens, so a theme or program color change rebuilds only this table.
        let colors = Colors(theme: theme, program: snapshot?.programColors ?? .init())
        if tableColors != colors {
            let table = Paint.table(theme, colors.program)
            colorTable = table.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
            }
            guard colorTable != nil else { throw RendererFailure.allocation }
            tableColors = colors
        }
        if atlas == nil { atlas = try GlyphAtlas(device: device, metrics: metrics) }
        guard let atlas, let buffer = queue.makeCommandBuffer() else { throw RendererFailure.allocation }
        let initialUploads = atlas.uploadCount
        let initialPage = atlas.pageGeneration
        var dirty = 0
        var blinks = false
        var visible: [(Int, RowGeometry)] = []
        if let snapshot {
            if priorSize != snapshot.size || priorBase != snapshot.isAlternate { discardGeometry() }
            priorSize = snapshot.size
            priorBase = snapshot.isAlternate
            var next: [RowKey: RowGeometry] = [:]
            let columns = snapshot.size.columns
            let area = metrics.size(in: CGSize(width: viewport.width / metrics.scale, height: viewport.height / metrics.scale))
            let count = min(columns, area.columns)
            for (y, row) in snapshot.rows.prefix(area.rows).enumerated() {
                let range = selection?.columns(in: y, width: count)
                let key = RowKey(revision: row.generation, selection: range)
                let geo: RowGeometry
                if let existing = cached[key] ?? next[key] {
                    geo = existing
                } else {
                    var builder = RowBuilder(metrics: metrics, atlas: atlas, solid: solid)
                    var col = 0
                    while col < count {
                        let cell = row[col]
                        let span = col..<(col + max(1, cell.width))
                        try builder.cell(cell, column: col, availableWidth: count - col, selected: range?.overlaps(span) == true)
                        col += max(1, cell.width)
                    }
                    geo = try builder.finish(device: device)
                    dirty += 1
                }
                next[key] = geo
                if geo.buffer != nil { visible.append((y, geo)) }
                blinks = blinks || geo.blinks
            }
            cached = next
            if showsCursor, snapshot.cursorVisible, (0..<min(snapshot.rows.count, area.rows)).contains(snapshot.cursorRow) {
                let row = snapshot.rows[snapshot.cursorRow]
                // A pending wrap puts the logical cursor just beyond the right margin.
                var x = min(snapshot.cursorColumn, columns - 1)
                if x >= 0, x < count {
                    if x > 0, row[x].width == 0, row[x - 1].width == 2 { x -= 1 }
                    var cursor = RowBuilder(metrics: metrics, atlas: atlas, solid: solid)
                    let left = metrics.x(x)
                    let right = metrics.x(min(count, x + max(1, row[x].width)))
                    let thickness = max(1, Float((2 * metrics.scale).rounded()))
                    let height = Float(metrics.rowHeightPixels)
                    let selected = selection?.columns(in: snapshot.cursorRow, width: count)?.overlaps(x..<(x + max(1, row[x].width))) == true
                    let cursorPaint = selected ? Paint.selectionInk : Paint.cursor
                    switch snapshot.cursorShape {
                    case .block: try cursor.cell(row[x], column: x, availableWidth: count - x, underCursor: true, selected: selected)
                    case .bar: cursor.fill(x: left, y: 0, width: min(thickness, right - left), height: height, color: cursorPaint)
                    case .underline: cursor.fill(x: left, y: height - thickness, width: right - left, height: thickness, color: cursorPaint)
                    }
                    visible.append((snapshot.cursorRow, try cursor.finish(device: device)))
                }
            }
        }
        // Row buffers from a retired page survive through this command, then the next frame rebuilds them.
        if initialPage != atlas.pageGeneration { discardGeometry() }
        try atlas.encodeUploads(into: buffer)
        guard let enc = buffer.makeRenderCommandEncoder(descriptor: pass) else { throw RendererFailure.missingEncoder }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(colorTable, offset: 0, index: 2)
        for (index, row) in visible {
            enc.setVertexBuffer(row.buffer, offset: 0, index: 0)
            var params = SIMD4(Float(viewport.width), Float(viewport.height), metrics.y(index), blinkOpacity)
            enc.setVertexBytes(&params, length: MemoryLayout.size(ofValue: params), index: 1)
            for batch in row.batches {
                enc.setFragmentTexture(batch.texture, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: batch.count, baseInstance: batch.first)
            }
        }
        enc.endEncoding()
        return Prepared(buffer: buffer, rowsPrepared: dirty, glyphUploads: atlas.uploadCount - initialUploads, blinks: blinks)
    }
}
