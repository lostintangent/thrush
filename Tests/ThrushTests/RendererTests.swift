import MetalKit
import SwiftUI
import Testing
import ThrushCore
@testable import Thrush

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
    let width: Int
    let bytes: [UInt8]
    let rowsPrepared: Int
    let uploads: Int
    let blinks: Bool

    subscript(x: Int, y: Int) -> UInt32 {
        // The drawable's .bgra8Unorm layout.
        let i = (y * width + x) * 4
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

    func draw(_ snapshot: Terminal.Snapshot, theme: TerminalTheme, width: Int = Probe.canvasWidth,
              selection: TerminalView.Selection? = nil, blinkOpacity: Float = 1) throws -> Pixels {
        view.theme = theme
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
                                        pass: pass, selection: selection, blinkOpacity: blinkOpacity)

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
        return Pixels(width: width, bytes: Array(UnsafeBufferPointer(start: memory.contents().assumingMemoryBound(to: UInt8.self),
                                                      count: size)), rowsPrepared: frame.rowsPrepared, uploads: frame.glyphUploads,
                      blinks: frame.blinks)
    }
}

private func pack(_ color: Terminal.RGB) -> UInt32 {
    UInt32(color.red) << 16 | UInt32(color.green) << 8 | UInt32(color.blue)
}

private let escape = "\u{1b}["

@MainActor
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func wideningADrawableRevealsTheRestOfACachedRow() async throws {
    let host = try await OffscreenTerminal()
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    _ = terminal.receive((escape + "?25lABCDEFGZ").utf8)
    let snapshot = terminal.snapshot()
    let narrow = try host.draw(snapshot, theme: .slateDark, width: 128)
    #expect(narrow.colors(in: 0..<1).contains(0xe3eaf0))
    let wide = try host.draw(snapshot, theme: .slateDark)
    #expect(wide.colors(in: 7..<8).contains(0xe3eaf0))
    #expect(try host.draw(snapshot, theme: .slateDark).rowsPrepared == 0)
}

@MainActor
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func dimInkMaintainsContrastOnCodexComposerBackgrounds() async throws {
    let host = try await OffscreenTerminal()
    // Foreground and composer background bytes from the two Slate appearances.
    // Expected glyph interiors use 70% foreground and 30% background in the UNORM target.
    let cases: [(TerminalTheme, String, UInt32, UInt32, UInt32)] = [
        (.slateDark, "47;56;64", 0x2f3840, 0xe3eaf0, 0xadb5bb),
        (.slateLight, "240;242;243", 0xf0f2f3, 0x233442, 0x616d77),
    ]
    func channels(_ color: UInt32) -> [Int] {
        [Int(color >> 16), Int(color >> 8 & 255), Int(color & 255)]
    }
    func luminance(_ color: UInt32) -> Double {
        let linear = channels(color).map {
            let value = Double($0) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
    for (theme, sgrBackground, background, foreground, expectedDim) in cases {
        var terminal = Terminal(size: .init(columns: 8, rows: 2))
        _ = terminal.receive((escape + "?25l" + escape + "48;2;" + sgrBackground + "mH").utf8)
        let normal = try host.draw(terminal.snapshot(), theme: theme)
        // Locate a fully covered stem in the undimmed H, then sample the same pixel.
        let stem = try #require((Probe.top..<(Probe.top + Probe.height)).compactMap { y in
            (Probe.edges[0]..<Probe.edges[1]).first { normal[$0, y] == foreground }.map { ($0, y) }
        }.first)
        _ = terminal.receive((escape + "H" + escape + "2mH").utf8)
        let dim = try host.draw(terminal.snapshot(), theme: theme)
        let ink = dim[stem.0, stem.1]
        let fill = dim[Probe.edges[0], Probe.top]
        #expect(fill == background)
        // Fixed-function blend precision can shift a channel by one code value.
        #expect(zip(channels(ink), channels(expectedDim)).allSatisfy { abs($0 - $1) <= 1 })
        let a = luminance(ink), b = luminance(fill)
        let contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        #expect(contrast >= 4.5, "Measured ink \(channels(ink)) on \(channels(fill))")
    }
}

@MainActor
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func livePaletteChangesRecolorCachedRows() async throws {
    var terminal = Terminal(size: .init(columns: 8, rows: 3))
    // The first row includes direct RGB and a color-cube index. The next two rows
    // put each customizable ANSI background through the shader and into the readback.
    var transcript = "H" + escape + "41m " + escape + "48;2;22;53;84m " + escape + "48;5;196m "
    for index in 0..<16 {
        if index.isMultiple(of: 8) { transcript += escape + "\(2 + index / 8);1H" }
        transcript += escape + "48;5;\(index)m "
    }
    _ = terminal.receive((transcript + escape + "0m" + escape + "?25l").utf8)
    let screen = terminal.snapshot()
    var custom = TerminalTheme.slateDark
    let ansi = (UInt8(0)..<16).map { Terminal.RGB(red: $0, green: 180, blue: 140) }
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
        for index in 0..<16 {
            let x = Probe.edges[index % 8] + 1
            let y = Probe.top + (1 + index / 8) * Probe.height + 1
            #expect(shot[x, y] == pack(theme.palette.ansi[index]))
        }
    }
}

@MainActor
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func programColorsPaintThePaneWhileItsChromeAndSelectionKeepTheTheme() async throws {
    let host = try await OffscreenTerminal()
    let pane = TerminalPaneContainer(terminal: host.view)
    // A mounted view displays each snapshot as it arrives. On the Mac, a dark title bar overlaps the pane.
    #if os(macOS)
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 402, height: 550), styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = pane
    pane.layoutSubtreeIfNeeded()
    #else
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 550))
    window.addSubview(pane)
    #endif
    defer { withExtendedLifetime(window) {} }
    func paneBackground() -> CGColor? {
        #if os(macOS)
        pane.layer?.backgroundColor
        #else
        pane.backgroundColor?.cgColor
        #endif
    }
    func color(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    _ = terminal.receive((escape + "?25lH" + escape + "41m " + escape + "48;5;196m " + escape + "0m").utf8)
    let theme = TerminalTheme.slateDark
    _ = try host.draw(terminal.snapshot(), theme: theme)
    #if os(macOS)
    #expect(pane.titlebarAppearance == nil)
    #endif

    let osc = "\u{1b}]"
    _ = terminal.receive((osc + "11;#faf0e6\u{7}" + osc + "10;rgb:20/20/20\u{7}" + osc + "4;1;#336699\u{7}").utf8)
    let program = terminal.snapshot()
    host.view.display(program)
    let shot = try host.draw(program, theme: theme)
    // Rows keep color tokens, so the program's colors reach every cell without rebuilding one.
    #expect(shot.rowsPrepared == 0 && shot.uploads == 0)
    #expect(shot[0, 0] == 0xfaf0e6)
    #expect(shot.colors(in: 0..<1).contains(0x202020))
    #expect(shot[Probe.edges[1] + 1, Probe.top + 1] == 0x336699)
    #expect(shot[Probe.edges[2] + 1, Probe.top + 1] == 0xff0000)
    #expect(paneBackground() == color(0xfaf0e6))
    #expect(pane.canvasScheme == .light)
    #if os(macOS)
    // The dark window's title bar takes the light canvas's appearance, so its title stays readable over it.
    #expect(pane.titlebarAppearance == .aqua)
    #expect(pane.toolbarCoverColor == nil)
    #endif

    let selection = TerminalView.Selection(anchorRow: 0, anchorColumn: 0, headRow: 0, headColumn: 0)
    let selected = try host.draw(program, theme: theme, selection: selection)
    #expect(selected[Probe.edges[0], Probe.top + 1] == pack(theme.selection))
    #expect(selected.colors(in: 0..<1).contains(pack(theme.selectionInk)))

    _ = terminal.receive((osc + "111\u{7}").utf8)
    let restored = terminal.snapshot()
    host.view.display(restored)
    let reset = try host.draw(restored, theme: theme)
    #expect(reset[0, 0] == pack(theme.palette.background))
    #expect(reset[Probe.edges[1] + 1, Probe.top + 1] == 0x336699)
    #expect(paneBackground() == color(pack(theme.palette.background)))
    #expect(pane.canvasScheme == .dark)
    #if os(macOS)
    #expect(pane.titlebarAppearance == nil)
    // A hidden pane, or one the title bar no longer overlaps, gives the title bar back to the window.
    _ = terminal.receive((osc + "11;#faf0e6\u{7}").utf8)
    host.view.display(terminal.snapshot())
    #expect(pane.titlebarAppearance == .aqua)
    pane.isHidden = true
    #expect(pane.titlebarAppearance == nil)
    pane.isHidden = false
    #expect(pane.titlebarAppearance == .aqua)
    window.styleMask.remove(.fullSizeContentView)
    pane.layoutSubtreeIfNeeded()
    #expect(pane.titlebarAppearance == nil)
    #expect(pane.toolbarCoverColor == nil)

    // Where AppKit keeps an item over the canvas on the window's appearance, as a split view's visible toolbar
    // background does, the bar goes back to the window and the theme stops the canvas beneath it.
    window.styleMask.insert(.fullSizeContentView)
    pane.layoutSubtreeIfNeeded()
    #expect(pane.titlebarAppearance == .aqua)
    var titlebar = try #require(window.standardWindowButton(.closeButton) as NSView?)
    while let parent = titlebar.superview, parent !== window.contentView?.superview { titlebar = parent }
    let pinned = NSView(frame: CGRect(x: 200, y: 0, width: 40, height: 20))
    pinned.appearance = NSAppearance(named: .darkAqua)
    titlebar.addSubview(pinned)
    pane.needsLayout = true
    pane.layoutSubtreeIfNeeded()
    // The pane checks the bar a moment after AppKit settles it.
    try await Task.sleep(for: .milliseconds(300))
    #expect(pane.titlebarAppearance == nil)
    #expect(pane.toolbarCoverColor == color(pack(theme.palette.background)))
    pane.needsLayout = true
    pane.layoutSubtreeIfNeeded()
    #expect(pane.titlebarAppearance == nil)
    // A canvas the window's appearance already suits needs neither, and the next opposite one asks again.
    pinned.removeFromSuperview()
    _ = terminal.receive((osc + "111\u{7}").utf8)
    host.view.display(terminal.snapshot())
    #expect(pane.toolbarCoverColor == nil)
    _ = terminal.receive((osc + "11;#faf0e6\u{7}").utf8)
    host.view.display(terminal.snapshot())
    try await Task.sleep(for: .milliseconds(300))
    #expect(pane.titlebarAppearance == .aqua)
    #expect(pane.toolbarCoverColor == nil)
    // Window buttons beside the canvas, over a sidebar, that followed it would leave the sidebar's ground.
    pane.additionalSafeAreaInsets.left = 120
    pane.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    #expect(pane.titlebarAppearance == nil)
    #expect(pane.toolbarCoverColor == color(pack(theme.palette.background)))
    #endif
}

@MainActor
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func aBlockKeepsItsGlyphReadableUnderAProgramCursor() async throws {
    let host = try await OffscreenTerminal()
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    // Slate Light's white glyph ink suits its ochre cursor, not a pale one a program sets.
    _ = terminal.receive(("H" + escape + "1;1H" + "\u{1b}]12;#f0f0f0\u{7}").utf8)
    let theme = TerminalTheme.slateLight
    let block = try host.draw(terminal.snapshot(), theme: theme)
    #expect(block[Probe.edges[0], Probe.top] == 0xf0f0f0)
    #expect(block.colors(in: 0..<1).contains(pack(theme.palette.foreground)))
    #expect(!block.colors(in: 0..<1).contains(pack(theme.cursorInk)))
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

@MainActor
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func concealedTextKeepsItsCellsAndCopyButDrawsNoInk() async throws {
    let host = try await OffscreenTerminal()
    var theme = TerminalTheme.slateDark
    theme.cursor = .init(red: 130, green: 32, blue: 48)
    theme.cursorInk = .init(red: 255, green: 224, blue: 0)
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    // Concealed H on red, concealed underlined and struck H, a visible H, then the block cursor on a concealed H.
    _ = terminal.receive((escape + "8;41mH" + escape + "49;4;9mH" + escape + "0mH" + escape + "8mH"
                          + escape + "0m" + escape + "1;4H").utf8)
    let snapshot = terminal.snapshot()
    let shot = try host.draw(snapshot, theme: theme)
    #expect(shot.colors(in: 0..<1) == [0xe28282])
    #expect(shot.colors(in: 1..<2) == [0x131d27])
    #expect(shot.colors(in: 2..<3).contains(0xe3eaf0))
    #expect(shot.colors(in: 3..<4) == [0x822030])

    let selection = TerminalView.Selection(anchorRow: 0, anchorColumn: 0, headRow: 0, headColumn: 1)
    let selected = try host.draw(snapshot, theme: theme, selection: selection)
    #expect(selected.colors(in: 0..<2) == [0x466b85])
    var transcript = TerminalTranscript()
    transcript.display(snapshot)
    #expect(transcript.text(in: selection) == "HH")
}

@MainActor
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func blinkingInkFadesOverSteadyCellsWithoutRebuildingRows() async throws {
    let host = try await OffscreenTerminal()
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    // A blinking underlined H on red, a steady H, then a blinking H under the block cursor.
    _ = terminal.receive((escape + "5;4;41mH" + escape + "0mH" + escape + "5mH" + escape + "0m" + escape + "1;3H").utf8)
    let snapshot = terminal.snapshot()
    let underline = (x: Probe.edges[0] + 2, y: Probe.top + Probe.height - 1)
    let shown = try host.draw(snapshot, theme: .slateDark)
    #expect(shown.blinks)
    #expect(shown.colors(in: 0..<1).contains(0xe3eaf0))
    #expect(shown[underline.x, underline.y] == 0xe3eaf0)

    let hidden = try host.draw(snapshot, theme: .slateDark, blinkOpacity: 0)
    #expect(hidden.rowsPrepared == 0 && hidden.uploads == 0)
    #expect(hidden.colors(in: 0..<1) == [0xe28282])
    #expect(hidden.colors(in: 1..<2) == shown.colors(in: 1..<2))
    // The cursor keeps the cell being edited legible.
    #expect(hidden.colors(in: 2..<3) == shown.colors(in: 2..<3))

    let half = try host.draw(snapshot, theme: .slateDark, blinkOpacity: 0.5)
    let blend = half[underline.x, underline.y]
    let channels = [blend >> 16, blend >> 8 & 255, blend & 255].map(Int.init)
    #expect(zip(channels, [226, 182, 185]).allSatisfy { abs($0 - $1) <= 1 }, "Measured \(channels)")
}

@MainActor
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func onlyVisibleBlinkingInkAsksForBlinkFrames() async throws {
    let host = try await OffscreenTerminal()
    let cases = [("H", false), (escape + "5m ", false), (escape + "5;41m ", false), (escape + "5;8mH", false),
                 (escape + "5;4m ", true), (escape + "5m🐦", true)]
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    for (bytes, blinks) in cases {
        _ = terminal.receive((escape + "2J" + escape + "H" + bytes + escape + "0m").utf8)
        #expect(try host.draw(terminal.snapshot(), theme: .slateDark).blinks == blinks, "\(bytes.debugDescription)")
    }
}

@Test func blinkingTextHoldsSteadyBetweenTwoContinuousFades() {
    // Sample two cycles at one millisecond, starting at an arbitrary media time.
    let start = 86_400.123, step = 0.001
    let samples = (0..<Int(2 * TextBlink.period / step)).map { start + Double($0) * step }
    var previous = TextBlink.opacity(at: start - step)
    var fading = 0, shown = 0, hidden = 0
    for time in samples {
        let opacity = TextBlink.opacity(at: time)
        // No visible step between frames, even across a cycle boundary.
        #expect(abs(opacity - previous) < 0.01, "Jump at \(time)")
        previous = opacity
        let next = TextBlink.nextFade(from: time)
        if next == time {
            fading += 1
            continue
        }
        // Between fades the frame holds, so the view can sleep until `next`.
        #expect(opacity == 0 || opacity == 1)
        #expect(TextBlink.opacity(at: (time + next) / 2) == opacity && TextBlink.opacity(at: next - 1e-6) == opacity)
        if opacity == 1 { shown += 1 } else { hidden += 1 }
    }
    #expect(abs(fading - 800) <= 2 && abs(shown - 1000) <= 2 && abs(hidden - 600) <= 2)
}

@Test func outputDrawsOncePerRefreshAfterItsWritesPause() {
    var schedule = FramePacer.Schedule()
    let interval = 1.0 / 60
    schedule.observe(target: 100, duration: interval)
    schedule.observe(target: 100 + interval, duration: interval)
    let next = 100 + 2 * interval, margin = schedule.margin, deadline = next - margin
    func near(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 1e-9 } ?? false }

    // Output draws for the next refresh once its writes pause, but never past the deadline.
    #expect(near(schedule.refresh(after: 100 + interval + 0.002, past: nil), next))
    #expect(near(schedule.drawTime(for: next, output: 100 + interval + 0.002), 100 + interval + 0.002 + FramePacer.Schedule.quiet))
    #expect(near(schedule.drawTime(for: next, output: deadline - 0.0001), deadline))
    // Output past the deadline waits for the following refresh.
    #expect(near(schedule.refresh(after: deadline + 0.0001, past: nil), next + interval))
    // So does output for a refresh that already has a frame, which draws no earlier than that
    // refresh's deadline, so it can't share it.
    #expect(near(schedule.refresh(after: 100 + interval + 0.002, past: next), next + interval))
    #expect(near(schedule.drawTime(for: next + interval, output: 100 + interval + 0.002), deadline))
}

@Test func scheduleKeepsTheDisplayCadenceWhileTheLinkPauses() {
    var schedule = FramePacer.Schedule()
    let interval = 1.0 / 120
    // Each tick's own duration jitters. The interval comes from the whole run, across a pause.
    for beat in [0, 1, 2, 50, 51] {
        schedule.observe(target: 5 + Double(beat) * interval, duration: interval * 1.01)
    }
    #expect(abs(schedule.interval - interval) < 1e-9)
    #expect(abs((schedule.refresh(after: 5 + 51 * interval, past: nil) ?? 0) - (5 + 52 * interval)) < 1e-9)
    // A new rate starts over.
    schedule.observe(target: 5 + 51 * interval + 1.0 / 60, duration: 1.0 / 60)
    #expect(abs(schedule.interval - 1.0 / 60) < 1e-9)
}

@Test func outputDeadlineFollowsTheSlowestRecentFrame() {
    var schedule = FramePacer.Schedule()
    schedule.drew(cost: 0.008)
    #expect(abs(schedule.margin - 0.008 - FramePacer.Schedule.slack) < 1e-9)
    for _ in 0..<16 { schedule.drew(cost: 0.001) }
    #expect(schedule.margin < 0.003)
    // A frame slower than a refresh couldn't make one, so the margin stops at three quarters of it.
    schedule.drew(cost: 0.5)
    #expect(abs(schedule.margin - 0.75 / 60) < 1e-9)
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
