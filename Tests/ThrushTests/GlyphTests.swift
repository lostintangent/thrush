import CoreGraphics
import CoreText
import Metal
import Testing
import ThrushCore
@testable import Thrush

@Test func slateGridUsesCumulativePixelEdges() {
    for scale: CGFloat in [1, 2, 3] {
        let metrics = GridMetrics(scale: scale)
        #if os(macOS)
        #expect(metrics.size(in: CGSize(width: 720, height: 454)) == .init(columns: 80, rows: 24))
        #expect(metrics.x(0) == Float(12 * scale))
        #expect(metrics.y(0) == Float(10 * scale))
        #expect(metrics.baselinePixels == Int(14 * scale))
        #else
        #expect(metrics.size(in: CGSize(width: 402, height: 477)) == .init(columns: 47, rows: 25))
        #expect(metrics.x(0) == Float(10 * scale))
        #expect(metrics.y(0) == Float(8 * scale))
        #expect(metrics.baselinePixels == Int(13 * scale))
        #endif
        #expect(metrics.rowHeightPixels == Int(18 * scale))
        let edges = (0...81).map(metrics.x)
        #expect(edges.allSatisfy { $0 == $0.rounded() })
        #expect(abs(CGFloat(edges[80] - edges[0]) - 80 * metrics.advancePixels) <= 0.5)
        #expect(edges[1] > edges[0])
    }
}

private func read(_ tile: GlyphTile, after uploads: GlyphAtlas, device: any MTLDevice) throws -> [UInt8] {
    let queue = try #require(device.makeCommandQueue())
    let command = try #require(queue.makeCommandBuffer())
    try uploads.encodeUploads(into: command)

    let width = Int(tile.pixelSize.x)
    let height = Int(tile.pixelSize.y)
    let rowBytes = (width * 4 + 255) / 256 * 256
    let readback = try #require(device.makeBuffer(length: rowBytes * height, options: .storageModeShared))
    let blit = try #require(command.makeBlitCommandEncoder())
    let origin = MTLOrigin(x: Int((tile.uv.x * Float(tile.texture.width)).rounded()),
                           y: Int((tile.uv.y * Float(tile.texture.height)).rounded()), z: 0)
    blit.copy(from: tile.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin,
              sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback,
              destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    try #require(command.status == .completed)
    let bytes = readback.contents().assumingMemoryBound(to: UInt8.self)
    return (0..<height).flatMap { row in Array(UnsafeBufferPointer(start: bytes + row * rowBytes, count: width * 4)) }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func shapedFallbackColorAndPageRollover() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let metrics = GridMetrics(scale: 2)
    // A 48 px page fits exactly two narrow glyphs or one wide glyph on its only shelf.
    let atlas = try GlyphAtlas(device: device, metrics: metrics, dimension: 48)
    var terminal = Terminal(size: .init(columns: 10, rows: 2))
    _ = terminal.receive("A翼🐦Z".utf8)
    let snapshot = terminal.snapshot()
    let row = snapshot.rows[0]
    #expect(snapshot.cursorColumn == 6)
    #expect((0..<6).map { row[$0].width } == [1, 2, 0, 2, 0, 1])
    var tiles: [GlyphTile] = []
    for column in [0, 1, 3, 5] {
        let cell = row[column]
        let key = GlyphKey(text: cell.text, width: cell.width, bold: false, italic: false)
        let tile = try atlas.glyph(for: key)
        #expect(tile.pixelSize.x == Float(ceil(metrics.advancePixels * CGFloat(cell.width))))
        let before = atlas.uploadCount
        #expect(try atlas.glyph(for: key).uv == tile.uv)
        #expect(atlas.uploadCount == before)
        tiles.append(tile)
    }
    #expect(tiles.map(\.isColor) == [false, false, true, false])
    #expect(atlas.uploadCount == 4)
    #expect(atlas.pageGeneration > 0)
    #expect(atlas.residentGlyphCount <= 2)
    #expect(atlas.residentBytes == 48 * 48 * 4)
    // Read after all rollovers. Drawing an earlier tile must see the original glyph.
    var rasters: [[UInt8]] = []
    for tile in tiles {
        let bytes = try read(tile, after: atlas, device: device)
        let offsets = stride(from: 0, to: bytes.count, by: 4)
        #expect(offsets.contains { bytes[$0 + 3] > 100 })
        let chromatic = offsets.contains { abs(Int(bytes[$0]) - Int(bytes[$0 + 2])) > 20 }
        #expect(chromatic == tile.isColor)
        rasters.append(bytes)
    }
    #expect(rasters[0] != rasters[3])
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func atlasRasterBeginsAtTopOfCell() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let metrics = GridMetrics(scale: 2)
    let atlas = try GlyphAtlas(device: device, metrics: metrics)
    let tile = try atlas.glyph(for: GlyphKey(text: "T", width: 1, bold: false, italic: false))
    let width = Int(tile.pixelSize.x)
    let bytes = try read(tile, after: atlas, device: device)
    let ink = (0..<metrics.rowHeightPixels).map { y in
        (0..<width).filter { x in bytes[(y * width + x) * 4 + 3] > 80 }.count
    }
    let rows = ink.filter { $0 > 0 }
    // The crossbar of a capital T must be at the top of its ink, above the narrow stem.
    try #require(rows.count > 5)
    #expect(rows.prefix(3).max()! > rows.suffix(3).max()!)
    #expect(ink.suffix(from: metrics.baselinePixels + 1).allSatisfy { $0 == 0 })
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func fontRenditionsAndCombiningMarksReachTheAtlas() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let atlas = try GlyphAtlas(device: device, metrics: GridMetrics(scale: 2))
    let keys = [
        GlyphKey(text: "e", width: 1, bold: false, italic: false),
        GlyphKey(text: "e", width: 1, bold: true, italic: false),
        GlyphKey(text: "e", width: 1, bold: false, italic: true),
        GlyphKey(text: "e", width: 1, bold: true, italic: true),
        GlyphKey(text: "e\u{301}", width: 1, bold: false, italic: false),
        GlyphKey(text: "翼", width: 2, bold: false, italic: false),
        GlyphKey(text: "\u{10ffff}", width: 2, bold: false, italic: false)
    ]
    let tiles = try keys.map(atlas.glyph)
    let rasters = try tiles.map { try read($0, after: atlas, device: device) }
    #expect(Set(rasters.prefix(5)).count == 5)
    #expect(rasters[5] != rasters[6]) // The CJK fallback produced a defined glyph.
}
