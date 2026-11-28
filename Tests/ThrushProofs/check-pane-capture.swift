// Independent check that an original framebuffer contains the expected text inside its native control.
import CoreML
import Foundation
import ImageIO
import Vision

func fail(_ reason: String) -> Never {
    FileHandle.standardError.write(Data((reason + "\n").utf8))
    exit(2)
}

// Hosted Mac windows render at 1x, where fast recognition misreads small title text. Read short crops at 4x,
// then at 8x, since each scale misreads different frames.
func enlarged(_ region: CGImage, by factor: Int) -> CGImage {
    guard let context = CGContext(data: nil, width: region.width * factor, height: region.height * factor,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return region }
    context.interpolationQuality = .high
    context.draw(region, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
    return context.makeImage() ?? region
}

let usage = "Usage: check-pane-capture IMAGE [--crop X Y WIDTH HEIGHT] [--exact-line] EXPECTED_VISIBLE_STRINGS…"
var arguments = CommandLine.arguments.dropFirst()
guard let path = arguments.popFirst() else { fail(usage) }
let url = URL(fileURLWithPath: path)
let handlers: [VNImageRequestHandler]
if arguments.first == "--crop" {
    arguments = arguments.dropFirst()
    let coordinates = arguments.prefix(4).compactMap { Int($0) }
    guard coordinates.count == 4 else { fail(usage) }
    arguments = arguments.dropFirst(4)
    let (x, y, width, height) = (coordinates[0], coordinates[1], coordinates[2], coordinates[3])
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Unreadable framebuffer: " + path) }
    // CGImage uses the screenshot's top-left pixel origin. Reject clipping or an ignored crop.
    guard x >= 0, y >= 0, width > 0, height > 0, x <= image.width - width, y <= image.height - height,
          let region = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)),
          region.width == width, region.height == height else { fail("Crop lies outside the framebuffer") }
    handlers = (region.height < 96 ? [4, 8].map { enlarged(region, by: $0) } : [region]).map { VNImageRequestHandler(cgImage: $0) }
} else {
    handlers = [VNImageRequestHandler(url: url)]
}
let exactLine = arguments.first == "--exact-line"
if exactLine { arguments = arguments.dropFirst() }
guard !arguments.isEmpty else { fail(usage) }

func words(_ text: String) -> String {
    text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
}

let expected = arguments.map(words)
var attempts: [String] = []
// Short control labels use CPU recognition so the caller can try its second crop even on a GPU-less VM.
let levels: [VNRequestTextRecognitionLevel] = exactLine ? [.fast] : [.fast, .accurate]
for level in levels {
    for handler in handlers {
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = level
        recognition.recognitionLanguages = ["en-US"]
        recognition.usesLanguageCorrection = false
        do {
            // Hosted Mac VMs can render an iPhone framebuffer without supporting
            // the accelerator selected by Vision's accurate recognition model.
            if level == .fast {
                for (stage, devices) in try recognition.supportedComputeStageDevices {
                    if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                        recognition.setComputeDevice(cpu, for: stage)
                    }
                }
            }
            try handler.perform([recognition])
            let lines = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = words(lines.joined(separator: " "))
            let matched = exactLine ? arguments.allSatisfy { lines.contains($0) } : expected.allSatisfy { text.contains($0) }
            if matched { exit(0) }
            attempts.append("Read " + lines.joined(separator: " | "))
        } catch {
            attempts.append("Vision: " + String(describing: error))
        }
    }
}
FileHandle.standardError.write(Data(("Expected " + expected.joined(separator: " | ") + ". "
                                    + attempts.joined(separator: "\n") + "\n").utf8))
exit(1)
