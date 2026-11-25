// Verify the recorded drawable at the last remotely echoed insertion cell throughout the outage.
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
struct Views: Decodable {
    let reconnecting: CaptureState
    let noticeIntervalSeconds: [Double]
}
let views = try JSONDecoder().decode(Views.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let state = views.reconnecting
// The peer emits eight complete rows, then this prompt. No held character may advance the cursor.
let confirmed = state.cell(row: 8, column: "~/thrush % git".count)
let asset = AVURLAsset(url: URL(fileURLWithPath: arguments[0]))
let duration = try await asset.load(.duration).seconds
guard duration.isFinite && duration > 0 else { fail("The reconnect movie has no playable duration.") }
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
let interval = views.noticeIntervalSeconds
guard interval.count == 2, interval[0] >= 0, interval[1] - interval[0] >= 2 else {
    fail("The native pane did not report a sustained Reconnecting interval while the peer held replay.")
}
let span = interval[1] - interval[0]
var still: CGImage?
var samples: [Double] = []
var minimumCoverage = 1.0
for fraction in [0.25, 0.5, 0.75] {
    let time = interval[0] + fraction * span
    guard time < duration else { fail("Native outage interval exceeds the recorded movie.") }
    let (frame, actual) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
    guard actual.seconds > (samples.last ?? interval[0]), actual.seconds < interval[1],
          frame.width == Int((state.windowPoints.width * state.displayScale).rounded()),
          frame.height == Int((state.windowPoints.height * state.displayScale).rounded()) else {
        fail("The sampled frame does not match the native window or the recorded outage interval.")
    }
    let coverage = fill(in: confirmed, frame: frame, rgb: rgb)
    guard coverage >= 0.9 else {
        fail("The confirmed git cursor cell has \(Int(coverage * 100))% cursor fill at \(actual.seconds)s.")
    }
    samples.append(actual.seconds)
    minimumCoverage = min(minimumCoverage, coverage)
    if fraction == 0.5 { still = frame }
}
guard let still else { fail("Could not extract a frame inside the mounted notice interval.") }
let output = URL(fileURLWithPath: arguments[3])
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("Could not create the verified reconnect still.")
}
CGImageDestinationAddImage(destination, still, nil)
guard CGImageDestinationFinalize(destination) else { fail("Could not write the verified reconnect still.") }
print("Verified the cursor after git at \(samples)s. Minimum cell coverage \(Int(minimumCoverage * 100))%. Cell \(confirmed).")
