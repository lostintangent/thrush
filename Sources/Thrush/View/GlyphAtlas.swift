import CoreGraphics
import CoreText
import Foundation
import Metal

/// Thrush supplies the occupied columns. Core Text shapes just this cluster, preserving the grid.
struct GlyphKey: Hashable {
    let text: String
    let width: Int
    let bold: Bool
    let italic: Bool
}

struct GlyphTile {
    let texture: any MTLTexture
    let uv: SIMD4<Float>          // Normalized top-left origin and extent.
    let pixelSize: SIMD2<Float>
    let isColor: Bool
}

enum GlyphAtlasError: Error {
    case invalidDimensions, allocationFailed
}

/// One append-only 4 MiB page under the default configuration. A rollover starts an
/// empty page. Previously issued tiles stay valid for the passes referencing them.
/// The renderer uses pageGeneration to trim row caches that reference retired pages.
final class GlyphAtlas {
    private struct Upload {
        let texture: any MTLTexture
        let origin: MTLOrigin
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private let device: any MTLDevice
    private let metrics: GridMetrics
    private let fonts: [CTFont]
    private let dimension: Int
    private var page: any MTLTexture
    private var nextX = 0
    private var nextY = 0
    private var shelfHeight = 0
    private var entries: [GlyphKey: GlyphTile] = [:]
    private var uploads: [Upload] = []
    private(set) var pageGeneration: UInt64 = 0
    private(set) var uploadCount = 0
    var residentGlyphCount: Int { entries.count }
    var residentBytes: Int { dimension * dimension * 4 }

    init(device: any MTLDevice, metrics: GridMetrics, dimension: Int = 1024) throws {
        guard dimension > 0, dimension <= 16384 else { throw GlyphAtlasError.invalidDimensions }
        self.dimension = dimension
        self.device = device
        self.metrics = metrics
        self.page = try Self.makePage(device: device, dimension: dimension)
        // Attributed strings may include combining marks in a different fallback face.
        // Shape with the Core Text cascade for each variant.
        fonts = [[], [.traitBold], [.traitItalic], [.traitBold, .traitItalic]].map { traits in
            CTFontCreateCopyWithSymbolicTraits(metrics.font, 0, nil, traits, traits) ?? metrics.font
        }
    }

    private static func makePage(device: any MTLDevice, dimension: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: dimension, height: dimension, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw GlyphAtlasError.allocationFailed
        }
        texture.label = "Thrush glyph atlas"
        return texture
    }

    func glyph(for key: GlyphKey) throws -> GlyphTile {
        if let tile = entries[key] { return tile }
        guard (1...2).contains(key.width) else { throw GlyphAtlasError.invalidDimensions }
        let width = max(1, Int(ceil(metrics.advancePixels * CGFloat(key.width))))
        let height = metrics.rowHeightPixels
        guard width <= dimension, height <= dimension else { throw GlyphAtlasError.invalidDimensions }
        let bitmap = try rasterize(key, width: width, height: height)
        if nextX + width > dimension {
            nextX = 0
            nextY += shelfHeight
            shelfHeight = 0
        }
        if nextY + height > dimension {
            page = try Self.makePage(device: device, dimension: dimension)
            pageGeneration &+= 1
            entries.removeAll(keepingCapacity: true)
            nextX = 0
            nextY = 0
            shelfHeight = 0
        }

        let origin = MTLOrigin(x: nextX, y: nextY, z: 0)
        uploads.append(Upload(texture: page, origin: origin, width: width, height: height, pixels: bitmap.pixels))
        let uv = SIMD4(Float(nextX), Float(nextY), Float(width), Float(height)) / Float(dimension)
        let tile = GlyphTile(texture: page, uv: uv, pixelSize: SIMD2(Float(width), Float(height)),
                             isColor: bitmap.isColor)
        entries[key] = tile
        nextX += width
        shelfHeight = max(shelfHeight, height)
        uploadCount += 1
        return tile
    }

    /// Encode before the render encoder, on the queue used by all frames of this view.
    /// The blit and draw share one command buffer, including uploads to overflow pages.
    func encodeUploads(into commandBuffer: any MTLCommandBuffer) throws {
        guard !uploads.isEmpty else { return }
        // A 256-byte pitch supports both discrete Mac GPUs and Apple GPUs.
        let lengths = uploads.map { (($0.width * 4 + 255) / 256 * 256) * $0.height }
        guard let staging = device.makeBuffer(length: lengths.reduce(0, +), options: .storageModeShared),
              let blit = commandBuffer.makeBlitCommandEncoder() else { throw GlyphAtlasError.allocationFailed }
        staging.label = "Thrush glyph upload"
        blit.label = "Upload shaped glyphs"
        var offset = 0
        for (upload, length) in zip(uploads, lengths) {
            let pitch = length / upload.height
            upload.pixels.withUnsafeBytes { bytes in
                for row in 0..<upload.height {
                    staging.contents().advanced(by: offset + row * pitch).copyMemory(
                        from: bytes.baseAddress!.advanced(by: row * upload.width * 4),
                        byteCount: upload.width * 4
                    )
                }
            }
            blit.copy(from: staging, sourceOffset: offset,
                      sourceBytesPerRow: pitch, sourceBytesPerImage: length,
                      sourceSize: MTLSize(width: upload.width, height: upload.height, depth: 1),
                      to: upload.texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: upload.origin)
            offset += length
        }
        blit.endEncoding()
        uploads.removeAll(keepingCapacity: true)
    }

    private func rasterize(_ key: GlyphKey, width: Int, height: Int) throws -> (pixels: [UInt8], isColor: Bool) {
        let font = fonts[(key.bold ? 1 : 0) + (key.italic ? 2 : 0)]
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: key.text, attributes: attributes))
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        let isColor = runs.contains { run in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            return CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: colorSpace, bitmapInfo: format) else {
                throw GlyphAtlasError.allocationFailed
            }
            context.setShouldSmoothFonts(false)
            context.setShouldAntialias(true)
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.textMatrix = .identity
            context.scaleBy(x: metrics.scale, y: metrics.scale)
            let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
            let available = CGFloat(width) / metrics.scale
            let origin = max(0, (available - advance) / 2)
            context.textPosition = CGPoint(x: origin, y: CGFloat(height - metrics.baselinePixels) / metrics.scale)
            CTLineDraw(line, context)
        }
        return (pixels, isColor)
    }
}
