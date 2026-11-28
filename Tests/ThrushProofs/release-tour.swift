// Lays out the release tour: one labeled contact sheet per platform and appearance, from a directory of
// downloaded capture artifacts. A surface without a capture gets a dashed tile, and tour.json lists both.
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Surface {
    let label: String
    /// A shell pattern under the artifacts directory, where `*` also crosses folders and `{a}` is the appearance.
    let pattern: String
    /// Simulator UI tests save landscape frames in the portrait framebuffer's orientation.
    var turn = false
}

struct Platform {
    let name, title: String
    /// Framebuffer pixels per sheet pixel, and the frame a missing capture stands in for.
    let scale: CGFloat
    let frame: CGSize
    let corner: CGFloat
    let surfaces: [Surface]
}

let interactions = "*thrush-iphone-interactions-*/"
let livePhone = "*thrush-live-simulator-{a}-all-*/"
let liveMac = "*thrush-live-mac-{a}-all-*/"
let lifecycle = [
    ("Shell taken back", "lifecycle/capture-*-restored-the-other-owner-s-output.png"),
    ("Replacement shell", "lifecycle/capture-*-the-replacement-prompt-starts-above-an-empty-grid.png"),
    ("Previous shell above Latest", "lifecycle/capture-*-history-*.png"),
    ("Shell ended", "lifecycle/capture-*-final-output-survives-shell-exit.png"),
]
let platforms = [
    Platform(name: "iphone", title: "iPhone", scale: 0.3, frame: CGSize(width: 1206, height: 2622), corner: 165, surfaces: [
        Surface(label: "Opening", pattern: "*tour-iphone-spinners-{a}/spinner-opening-{a}-portrait-waiting.png"),
        Surface(label: "Opening under a navigation bar", pattern: "*tour-iphone-toolbar-{a}/spinner-opening-{a}-portrait-waiting.png"),
        Surface(label: "Reconnecting", pattern: "*tour-iphone-spinners-{a}/spinner-reconnecting-{a}-portrait-waiting.png"),
        Surface(label: "Live prompt", pattern: interactions + "shell-{a}-portrait.png"),
        Surface(label: "Ctrl armed", pattern: interactions + "control-{a}-armed.png"),
        Surface(label: "Keyboard hidden", pattern: interactions + "keyboard-{a}-hidden.png"),
        Surface(label: "Word and edit menu", pattern: interactions + "word-{a}-menu.png"),
        Surface(label: "Line selected", pattern: interactions + "line-{a}-selected.png"),
        Surface(label: "History above Latest", pattern: interactions + "history-{a}-latest.png"),
        Surface(label: "Landscape", pattern: interactions + "shell-{a}-landscape.png", turn: true),
        Surface(label: "Under a navigation bar", pattern: "*tour-iphone-under-bars/under-bars-{a}-portrait-keyboard-pane.png"),
        Surface(label: "Under a navigation bar in landscape", pattern: "*tour-iphone-under-bars/under-bars-{a}-landscape-keyboard-pane.png"),
        Surface(label: "Copy a wrapped path", pattern: livePhone + "shell/capture-*-copy-soft-wrapped-compiler-path.png"),
        Surface(label: "Vim", pattern: livePhone + "vim/capture-*-edited-scratch-file.png"),
        Surface(label: "Vim after replay", pattern: livePhone + "vim/capture-*-vim-serialized-replay.png"),
        Surface(label: "Codex answer", pattern: livePhone + "codex/capture-*-received-codex-answer.png"),
        Surface(label: "Codex history", pattern: livePhone + "codex/capture-*-earlier-transcript-page.png"),
    ] + lifecycle.map { Surface(label: $0.0, pattern: livePhone + $0.1) } + [
        Surface(label: "Program colors", pattern: "*tour-iphone-colors/colors-{a}.png"),
        Surface(label: "Program colors under a navigation bar", pattern: "*tour-iphone-colors/colors-toolbar-{a}.png"),
    ]),
    Platform(name: "mac", title: "Mac", scale: 1, frame: CGSize(width: 720, height: 486), corner: 0, surfaces: [
        Surface(label: "Opening", pattern: "*thrush-mac-spinners/spinner-opening-{a}-active.png"),
        Surface(label: "Opening, inactive window", pattern: "*thrush-mac-spinners/spinner-opening-{a}-inactive.png"),
        Surface(label: "Reconnecting", pattern: "*thrush-mac-spinners/spinner-reconnecting-{a}-active.png"),
        Surface(label: "Pasted build", pattern: liveMac + "shell/capture-*-pasted-build-command.png"),
        Surface(label: "Copy a wrapped path", pattern: liveMac + "shell/capture-*-copy-soft-wrapped-compiler-path.png"),
        Surface(label: "Vim", pattern: liveMac + "vim/capture-*-edited-scratch-file.png"),
        Surface(label: "Codex answer", pattern: liveMac + "codex/capture-*-received-codex-answer.png"),
        Surface(label: "Codex history", pattern: liveMac + "codex/capture-*-earlier-transcript-page.png"),
    ] + lifecycle.map { Surface(label: $0.0, pattern: liveMac + $0.1) } + [
        Surface(label: "Program colors under the title bar", pattern: "*thrush-mac-program-colors/colors-{a}.png"),
        Surface(label: "Full-size toolbar", pattern: "*thrush-mac-program-colors/colors-toolbar-{a}.png"),
        Surface(label: "Split view", pattern: "*thrush-mac-program-colors/colors-split-{a}.png"),
        Surface(label: "Split view with toolbar background", pattern: "*thrush-mac-program-colors/colors-split-background-{a}.png"),
        Surface(label: "Neovim following the window", pattern: "*thrush-mac-appearance-reports/neovim-{a}.png"),
    ]),
]

func fail(_ reason: String) -> Never {
    FileHandle.standardError.write(Data((reason + "\n").utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { fail("Usage: release-tour.swift ARTIFACTS OUTPUT [CAPTION]") }
let artifacts = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let output = URL(fileURLWithPath: arguments[2])
let caption = arguments.count > 3 ? arguments[3] : ""
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let files = (FileManager.default.enumerator(atPath: artifacts.path)?.allObjects as? [String] ?? []).sorted()

func find(_ pattern: String) -> String? {
    // The last match is the newest attempt or checkpoint.
    files.last { fnmatch(pattern, $0, 0) == 0 }
}

func load(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(artifacts.appendingPathComponent(path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

let sheetWidth: CGFloat = 3200, margin: CGFloat = 96, gap: CGFloat = 48, labelHeight: CGFloat = 104
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: sRGB, components: [r / 255, g / 255, b / 255, 1])!
}
let paper = color(244, 243, 239), ink = color(34, 37, 34), muted = color(89, 96, 89), rule = color(205, 208, 200)

func font(_ size: CGFloat, bold: Bool = false) -> CTFont {
    let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
    return bold ? CTFontCreateCopyWithSymbolicTraits(base, size, nil, .boldTrait, .boldTrait) ?? base : base
}

/// Draws one line of text with its baseline at `y`, measured from the sheet's top, and returns its width.
@discardableResult
func text(_ string: String, _ context: CGContext, x: CGFloat, y: CGFloat, height: CGFloat, font: CTFont, color: CGColor,
          width: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
    let attributed = NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
    var line = CTLineCreateWithAttributedString(attributed)
    if CTLineGetTypographicBounds(line, nil, nil, nil) > width {
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributed.attributes(at: 0, effectiveRange: nil)))
        line = CTLineCreateTruncatedLine(line, Double(width), .end, ellipsis) ?? line
    }
    context.textPosition = CGPoint(x: x, y: height - y)
    CTLineDraw(line, context)
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

/// Wraps a label into at most two lines below a tile whose bottom edge is `top`, measured from the sheet's top.
func label(_ string: String, _ context: CGContext, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat, color: CGColor) {
    let attributed = NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font(30, bold: true),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
    let box = CGRect(x: x, y: height - top - labelHeight, width: width, height: labelHeight - 14)
    let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(), CGPath(rect: box, transform: nil), nil)
    CTFrameDraw(frame, context)
}

struct Placed { let surface: Surface; let path: String?; let image: CGImage?; let size: CGSize; var origin = CGPoint.zero }

var gaps: [[String: String]] = []
var sources: [[String: String]] = []

for platform in platforms {
    for appearance in ["dark", "light"] {
        var tiles: [Placed] = platform.surfaces.map { surface in
            let pattern = surface.pattern.replacingOccurrences(of: "{a}", with: appearance)
            let path = find(pattern)
            let image = path.flatMap(load)
            var frame = image.map { CGSize(width: $0.width, height: $0.height) } ?? platform.frame
            if surface.turn { frame = CGSize(width: frame.height, height: frame.width) }
            let entry = ["platform": platform.name, "appearance": appearance, "surface": surface.label, "pattern": pattern]
            if let path, image != nil { sources.append(entry.merging(["capture": path]) { $1 }) } else { gaps.append(entry) }
            return Placed(surface: surface, path: path, image: image,
                          size: CGSize(width: (frame.width * platform.scale).rounded(), height: (frame.height * platform.scale).rounded()))
        }

        // Flow the tiles into rows, each as tall as its tallest tile plus a label.
        var rows: [[Int]] = [[]]
        var x = margin
        for index in tiles.indices {
            if x + tiles[index].size.width > sheetWidth - margin, !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = margin
            }
            rows[rows.count - 1].append(index)
            x += tiles[index].size.width + gap
        }
        let header: CGFloat = 300
        var y = header
        for row in rows {
            let tallest = row.map { tiles[$0].size.height }.max() ?? 0
            var x = margin
            for index in row {
                tiles[index].origin = CGPoint(x: x, y: y + tallest - tiles[index].size.height)
                x += tiles[index].size.width + gap
            }
            y += tallest + labelHeight + gap
        }
        let height = y + margin - gap

        guard let context = CGContext(data: nil, width: Int(sheetWidth), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("No sheet context") }
        context.interpolationQuality = .high
        context.textMatrix = .identity
        context.setFillColor(paper)
        context.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: height))

        let name = appearance == "dark" ? "Dark" : "Light"
        text("Thrush release tour", context, x: margin, y: 150, height: height, font: font(86, bold: true), color: ink)
        let missing = tiles.filter { $0.image == nil }.count
        let summary = "\(platform.title) in \(name). \(tiles.count - missing) of \(tiles.count) surfaces captured"
            + (missing == 0 ? "." : ", \(missing) missing.") + (caption.isEmpty ? "" : " " + caption)
        text(summary, context, x: margin, y: 212, height: height, font: font(36), color: muted)
        context.setFillColor(rule)
        context.fill(CGRect(x: margin, y: height - 250, width: sheetWidth - margin * 2, height: 2))

        for tile in tiles {
            let rect = CGRect(x: tile.origin.x, y: height - tile.origin.y - tile.size.height,
                              width: tile.size.width, height: tile.size.height)
            let radius = platform.corner * platform.scale
            if let image = tile.image {
                context.saveGState()
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.clip()
                if tile.surface.turn {
                    // Undo the framebuffer's portrait orientation by turning it a quarter counterclockwise.
                    context.translateBy(x: rect.maxX, y: rect.minY)
                    context.rotate(by: .pi / 2)
                    context.draw(image, in: CGRect(x: 0, y: 0, width: rect.height, height: rect.width))
                } else {
                    context.draw(image, in: rect)
                }
                context.restoreGState()
            } else {
                context.saveGState()
                context.setStrokeColor(muted)
                context.setLineWidth(3)
                context.setLineDash(phase: 0, lengths: [18, 12])
                context.addPath(CGPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: max(radius, 12),
                                       cornerHeight: max(radius, 12), transform: nil))
                context.strokePath()
                context.restoreGState()
                text("Missing", context, x: rect.minX + 28, y: tile.origin.y + tile.size.height / 2, height: height,
                     font: font(34, bold: true), color: muted, width: rect.width - 56)
            }
            label(tile.surface.label, context, x: rect.minX, top: tile.origin.y + tile.size.height + 14, width: tile.size.width,
                  height: height, color: tile.image == nil ? muted : ink)
        }

        guard let sheet = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  output.appendingPathComponent("release-tour-\(platform.name)-\(appearance).png") as CFURL,
                  UTType.png.identifier as CFString, 1, nil) else { fail("Could not write the \(platform.title) sheet") }
        CGImageDestinationAddImage(destination, sheet, nil)
        guard CGImageDestinationFinalize(destination) else { fail("Could not write the \(platform.title) sheet") }
        print("\(platform.title) \(name): \(tiles.count - missing) of \(tiles.count) surfaces")
    }
}

let report = try JSONSerialization.data(withJSONObject: ["captured": sources, "missing": gaps],
                                        options: [.prettyPrinted, .sortedKeys])
try report.write(to: output.appendingPathComponent("tour.json"))
for gap in gaps { print("Missing: \(gap["platform"]!) \(gap["appearance"]!) \(gap["surface"]!) (\(gap["pattern"]!))") }
