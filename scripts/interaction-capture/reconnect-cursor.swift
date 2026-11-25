// Verify the recorded drawable at the last remotely echoed insertion cell throughout the outage.
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct CaptureState: Decodable {
    let windowPoints, gridFrame, cellGridPixels: CGRect
    let columns, rows: Int
    let displayScale: CGFloat

    func cell(row: Int, column: Int) -> CGRect {
        let width = cellGridPixels.width / CGFloat(columns)
        let height = cellGridPixels.height / CGFloat(rows)
        return CGRect(x: (gridFrame.minX - windowPoints.minX) * displayScale + cellGridPixels.minX + CGFloat(column) * width,
                      y: (gridFrame.minY - windowPoints.minY) * displayScale + cellGridPixels.minY + CGFloat(row) * height,
                      width: width, height: height)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func hasReconnectNotice(_ frame: CGImage) throws -> Bool {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: frame).perform([request])
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string.lowercased() }.joined(separator: " ")
    return text.contains("reconnecting") && text.contains("typing waits for this shell to resume")
}

func fill(in cell: CGRect, frame: CGImage, rgb: [Int]) -> Double {
    // The probe types into a blank cell. Sample its interior in sRGB, excluding H.264 edge ringing.
    let interior = cell.insetBy(dx: cell.width * 0.2, dy: cell.height * 0.2).integral
    guard let crop = frame.cropping(to: interior) else { fail("Cursor cell falls outside the native recording.") }
    let side = 8
    var rgba = [UInt8](repeating: 0, count: side * side * 4)
    rgba.withUnsafeMutableBytes { pixels in
        guard let context = CGContext(data: pixels.baseAddress, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fail("Could not sample the recorded cursor cell.")
        }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
    }
    let matches = stride(from: 0, to: rgba.count, by: 4).filter { i in
        (0..<3).allSatisfy { abs(Int(rgba[i + $0]) - rgb[$0]) <= 30 }
    }.count
    return Double(matches) / Double(side * side)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 4, let color = UInt32(arguments[2], radix: 16) else {
    fail("Usage: reconnect-cursor MOVIE VIEW-JSON CURSOR-RRGGBB STILL.png")
}
let rgb = [Int(color >> 16), Int((color >> 8) & 255), Int(color & 255)]
struct Views: Decodable { let reconnecting: CaptureState }
let state = try JSONDecoder().decode(Views.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1]))).reconnecting
// The peer emits eight complete rows, then this prompt. No held character may advance the cursor.
let confirmed = state.cell(row: 8, column: "~/thrush % git".count)
let asset = AVURLAsset(url: URL(fileURLWithPath: arguments[0]))
let duration = try await asset.load(.duration).seconds
guard duration.isFinite && duration > 0 else { fail("The reconnect movie has no playable duration.") }
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
var checked = 0
var first: Double?
var last = 0.0
var still: CGImage?
for time in stride(from: 0.5, to: duration, by: 1.5) {
    let (frame, actual) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
    guard frame.width == Int((state.windowPoints.width * state.displayScale).rounded()),
          frame.height == Int((state.windowPoints.height * state.displayScale).rounded()) else {
        fail("Movie size differs from the submitted native window.")
    }
    guard try hasReconnectNotice(frame) else { continue }
    let coverage = fill(in: confirmed, frame: frame, rgb: rgb)
    guard coverage >= 0.9 else {
        fail("The confirmed git cursor cell has \(Int(coverage * 100))% cursor fill at \(actual.seconds)s.")
    }
    if first == nil { first = actual.seconds }
    last = actual.seconds
    checked += 1
    if still == nil || checked == 2 { still = frame }
}
guard checked >= 2, let first, last - first >= 1, let still else {
    fail("The recording did not show two distinct frames of the sustained Reconnecting notice.")
}
let output = URL(fileURLWithPath: arguments[3])
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("Could not create the verified reconnect still.")
}
CGImageDestinationAddImage(destination, still, nil)
guard CGImageDestinationFinalize(destination) else { fail("Could not write the verified reconnect still.") }
print("Verified the cursor after git in \(checked) outage frames from \(first)s through \(last)s. Cell \(confirmed).")
