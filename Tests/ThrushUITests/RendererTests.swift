import MetalKit
import Testing
import Thrush
@testable import ThrushUI

// Backing-pixel edges at 2× from Slate's type advance and insets. Keep these
// independent of GridMetrics so translating the whole grid cannot pass this test.
private enum Probe {
    #if os(macOS)
    static let edges = [24, 41, 59, 76, 93, 111, 128, 145, 162]
    static let top = 20
    #else
    static let edges = [20, 36, 52, 68, 84, 100, 116, 133, 149]
    static let top = 16
    #endif
    static let height = 36
    static let canvasWidth = 256
    static let canvasHeight = 160
}

private struct Pixels {
    let bytes: [UInt8]
    let rowsPrepared: Int
    let uploads: Int

    subscript(x: Int, y: Int) -> UInt32 {
        // The drawable's .bgra8Unorm layout.
        let i = (y * Probe.canvasWidth + x) * 4
        return UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i])
    }

    func colors(in columns: Range<Int>, row: Int = 0) -> Set<UInt32> {
        let y = Probe.top + row * Probe.height
        return Set((y..<(y + Probe.height)).flatMap { y in
            (Probe.edges[columns.lowerBound]..<Probe.edges[columns.upperBound]).map { x in self[x, y] }
        })
    }
}

@MainActor
private struct OffscreenTerminal {
    let device: any MTLDevice
    let renderer: MetalRenderer
    let view: TerminalView

    init() async throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        let program = try await ShaderPipelines.shared.pipeline(for: device)
        renderer = try MetalRenderer(device: device, pipeline: program)
        view = TerminalView(frame: .zero, device: device)
    }

    func draw(_ snapshot: Terminal.Snapshot, theme: TerminalTheme,
              selection: TerminalView.Selection? = nil) throws -> Pixels {
        view.theme = theme
        let width = Probe.canvasWidth
        let height = Probe.canvasHeight
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                 height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = .renderTarget
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        let attachment = try #require(pass.colorAttachments[0])
        attachment.texture = target
        attachment.loadAction = .clear
        attachment.storeAction = .store
        attachment.clearColor = view.clearColor
        let frame = try renderer.encode(snapshot: snapshot, metrics: .init(scale: 2), theme: view.resolvedTheme,
                                        pass: pass, viewport: CGSize(width: width, height: height), selection: selection)

        let size = width * height * 4
        let memory = try #require(device.makeBuffer(length: size, options: .storageModeShared))
        let blit = try #require(frame.buffer.makeBlitCommandEncoder())
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: memory, destinationOffset: 0, destinationBytesPerRow: width * 4,
                  destinationBytesPerImage: size)
        blit.endEncoding()
        frame.buffer.commit()
        frame.buffer.waitUntilCompleted()
        try #require(frame.buffer.status == .completed)
        return Pixels(bytes: Array(UnsafeBufferPointer(start: memory.contents().assumingMemoryBound(to: UInt8.self),
                                                      count: size)), rowsPrepared: frame.rowsPrepared, uploads: frame.glyphUploads)
    }
}

private func pack(_ color: Terminal.RGB) -> UInt32 {
    UInt32(color.red) << 16 | UInt32(color.green) << 8 | UInt32(color.blue)
}

private let escape = "\u{1b}["

@MainActor
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func livePaletteChangesRecolorCachedRows() async throws {
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    // Text, normal red background, direct RGB background, xterm color-cube background.
    let transcript = "H" + escape + "41m " + escape + "48;2;22;53;84m " + escape + "48;5;196m "
    _ = terminal.receive((transcript + escape + "0m" + escape + "?25l").utf8)
    let screen = terminal.snapshot()
    var custom = TerminalTheme.slateDark
    var ansi = custom.palette.ansi
    ansi[1] = .init(red: 4, green: 180, blue: 140)
    custom.palette = .init(foreground: .init(red: 255, green: 224, blue: 36),
                           background: .init(red: 10, green: 12, blue: 14), ansi: ansi)
    let host = try await OffscreenTerminal()
    let dark = try host.draw(screen, theme: .slateDark)
    #expect(dark.rowsPrepared > 0 && dark.uploads == 1)
    #expect(dark[0, 0] == 0x131d27)
    #expect(dark.colors(in: 0..<1).contains(0xe3eaf0))
    #expect(dark[Probe.edges[1] + 1, Probe.top + 1] == 0xe28282)

    for theme in [TerminalTheme.slateLight, custom, .slateDark] {
        let shot = try host.draw(screen, theme: theme)
        #expect(shot.rowsPrepared == 0)
        #expect(shot.uploads == 0)
        #expect(shot[0, 0] == pack(theme.palette.background))
        #expect(shot.colors(in: 0..<1).contains(pack(theme.palette.foreground)))
        #expect(shot[Probe.edges[1] + 1, Probe.top + 1] == pack(theme.palette.ansi[1]))
        #expect(shot[Probe.edges[2] + 1, Probe.top + 1] == 0x163554)
        #expect(shot[Probe.edges[3] + 1, Probe.top + 1] == 0xff0000)
    }
}

@MainActor
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func wideCellsAndSelectionCoverTheirPhysicalColumns() async throws {
    let host = try await OffscreenTerminal()
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    _ = terminal.receive("A翼🐦Z".utf8)
    let snapshot = terminal.snapshot()
    let dark = try host.draw(snapshot, theme: .slateDark)
    // A at 0, CJK spanning 1–2, color bird spanning 3–4, Z at 5, cursor at 6.
    for span in [0..<1, 1..<3, 5..<6] {
        #expect(dark.colors(in: span).contains(0xe3eaf0))
    }
    let bird = dark.colors(in: 3..<5)
    #expect(bird.contains { color in
        abs(Int(color >> 16) - Int(color & 255)) > 45
    })
    let y = Probe.top + 1
    #expect(dark[Probe.edges[6] - 1, y] == 0x131d27)
    #expect(dark[Probe.edges[6], y] == 0xfd9a01)
    #expect(dark[Probe.edges[7], y] == 0x131d27)

    // Both endpoints lie on the *continuation* of 翼.
    let selection = TerminalView.Selection(anchorRow: 0, anchorColumn: 2, headRow: 0, headColumn: 2)
    let selected = try host.draw(snapshot, theme: .slateDark, selection: selection)
    #expect(selected[Probe.edges[1] - 1, y] == 0x131d27)
    #expect(selected[Probe.edges[1], y] == 0x466b85)
    #expect(selected[Probe.edges[3] - 1, y] == 0x466b85)
    #expect(selected[Probe.edges[3], y] == 0x131d27)
    #expect(selected.colors(in: 1..<3).contains(0xf8fbfe))
    #expect(selected.colors(in: 3..<5) == bird)

    var hostTheme = TerminalTheme.slateLight
    hostTheme.selection = .init(red: 15, green: 86, blue: 65)
    hostTheme.selectionInk = .init(red: 247, green: 230, blue: 200)
    let tinted = try host.draw(snapshot, theme: hostTheme, selection: selection)
    #expect(tinted.rowsPrepared == 0 && tinted.uploads == 0)
    #expect(tinted[Probe.edges[1], y] == 0x0f5641)
    #expect(tinted.colors(in: 1..<3).contains(0xf7e6c8))
}

@MainActor
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func cursorShapeMovesWithItsSnapshot() async throws {
    let host = try await OffscreenTerminal()
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    var theme = TerminalTheme.slateDark
    theme.cursor = .init(red: 130, green: 32, blue: 48)
    theme.cursorInk = .init(red: 255, green: 224, blue: 0)
    _ = terminal.receive(("H" + escape + "1;1H").utf8)
    let first = terminal.snapshot()
    // Change the first row and simultaneously move the cursor to a different row.
    _ = terminal.receive((escape + "42m " + escape + "0m" + escape + "2;3H" + escape + "6 q").utf8)
    let second = terminal.snapshot()
    _ = terminal.receive((escape + "4 q").utf8)
    let third = terminal.snapshot()

    let block = try host.draw(first, theme: theme)
    #expect(block[Probe.edges[0], Probe.top] == 0x822030)
    #expect(block.colors(in: 0..<1).contains(0xffe000))
    let bar = try host.draw(second, theme: theme)
    #expect(bar.rowsPrepared == 1)
    #expect(bar[Probe.edges[0], Probe.top] == 0x93cba2)
    let x = Probe.edges[2]
    let y = Probe.top + Probe.height
    #expect(bar[x, y] == 0x822030)
    #expect(bar[x + 3, y + 12] == 0x822030)
    #expect(bar[x + 4, y + 12] == 0x131d27)

    let underline = try host.draw(third, theme: theme)
    #expect(underline.rowsPrepared == 0 && underline.uploads == 0)
    #expect(underline[x, y + Probe.height - 5] == 0x131d27)
    #expect(underline[x, y + Probe.height - 4] == 0x822030)
    #expect(underline[Probe.edges[3] - 1, y + Probe.height - 1] == 0x822030)

    // Submit the retained old snapshot after the newer one. Its H and block must return together.
    let retained = try host.draw(first, theme: theme)
    #expect(retained.bytes == block.bytes)
}

#if os(macOS)
@MainActor
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func nativeAppearanceYieldsToAHostOverride() async throws {
    let host = try await OffscreenTerminal()
    let light = try #require(NSAppearance(named: .aqua))
    let dark = try #require(NSAppearance(named: .darkAqua))
    #expect(host.view.theme == nil)
    #expect(host.view.isOpaque)
    host.view.backgroundOpacity = 0.75
    let expectedOpacity = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1.0 : 0.75
    #expect(host.view.clearColor.alpha == expectedOpacity)
    #expect(host.view.layer?.isOpaque == (expectedOpacity == 1))
    host.view.backgroundOpacity = 1
    host.view.appearance = light
    #expect(host.view.resolvedTheme == .slateLight)
    host.view.appearance = dark
    #expect(host.view.resolvedTheme == .slateDark)
    host.view.theme = .slateLight
    host.view.appearance = light
    host.view.appearance = dark
    #expect(host.view.resolvedTheme == .slateLight)
    host.view.theme = nil
    #expect(host.view.resolvedTheme == .slateDark)
}
#endif

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func simultaneousViewsShareTheDevicePipeline() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let cache = ShaderPipelines()
    async let first = cache.pipeline(for: device)
    async let next = cache.pipeline(for: device)
    let (a, b) = try await (first, next)
    let warmed = try await cache.pipeline(for: device)
    #expect(a.state === b.state && b.state === warmed.state)
    #expect(a.startedAt == warmed.startedAt)
    #expect(a.compileSeconds > 0)
}
