import AppKit
import CoreMedia
import QuartzCore
import ScreenCaptureKit

// Capture only WindowServer-delivered native window frames. Keep the green channel, losslessly,
// in source row order; anti-aliased glyph edges remain distinguishable from the dark background.
struct SourceFrame: Encodable {
    let displayTicks: UInt64
    let displayAt: Double
    let callbackAt: Double
    let samplePTS: Double
}

struct Coverage: Encodable {
    let pid: Int32
    let window: UInt32
    let title: String
    let width: Int
    let height: Int
    let timebaseNumerator: UInt32
    let timebaseDenominator: UInt32
    let hostClockErrorSeconds: Double
    let windowStreamEnded: String?
    let frames: [SourceFrame]
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "thrush.echo.capture")
    let directory: URL
    let pixels: FileHandle
    let base: mach_timebase_info_data_t
    let width: Int
    let height: Int
    var frames = [SourceFrame]()
    var ended: String?

    init(_ directory: URL, width: Int, height: Int) throws {
        self.directory = directory
        self.width = width
        self.height = height
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        self.base = base
        let path = directory.appendingPathComponent("window.gray")
        guard FileManager.default.createFile(atPath: path.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        pixels = try FileHandle(forWritingTo: path)
    }

    func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(base.numer) / Double(base.denom) / 1_000_000_000
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        // A macOS benchmark closes its own source window when its report is ready.
        // Keep already displayed frames and record the termination; the analyzer requires
        // independent coverage across all its timing and calibration landmarks.
        queue.async { self.ended = error.localizedDescription }
        FileHandle.standardError.write(Data("ScreenCaptureKit stopped: \(error)\n".utf8))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        let callback = CACurrentMediaTime()
        guard type == .screen, sample.isValid, let image = sample.imageBuffer,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
              let status = (info[.status] as? NSNumber).flatMap({ SCFrameStatus(rawValue: $0.intValue) }),
              status == .complete || status == .started,
              let ticks = (info[.displayTime] as? NSNumber)?.uint64Value, ticks > 0,
              ticks > (frames.last?.displayTicks ?? 0),
              CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height,
              CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let pointer = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) else { return }
        let stride = CVPixelBufferGetBytesPerRow(image)
        var gray = Data(count: width * height)
        gray.withUnsafeMutableBytes { bytes in
            let output = bytes.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<height {
                let source = pointer + y * stride + 1
                let row = output + y * width
                for x in 0..<width { row[x] = source[x * 4] }
            }
        }
        do {
            try pixels.write(contentsOf: gray)
            frames.append(.init(displayTicks: ticks, displayAt: seconds(ticks), callbackAt: callback,
                                samplePTS: sample.presentationTimeStamp.seconds))
            if frames.count == 1 { try Data().write(to: directory.appendingPathComponent("ready"), options: .atomic) }
        } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
}

let args = CommandLine.arguments
guard args.count == 4 else { fatalError("echo-pixels PID|simulator TITLE DIRECTORY") }
let pid = Int32(args[1]), title = args[2]
let directory = URL(fileURLWithPath: args[3], isDirectory: true)
_ = NSApplication.shared
let until = ContinuousClock.now + .seconds(18)
var target: SCWindow?
repeat {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    let windows = content.windows.filter {
        let owner = $0.owningApplication
        return (pid.map { id in owner?.processID == id } ?? (owner?.bundleIdentifier == "com.apple.iphonesimulator")) &&
            $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 200 &&
            (title.isEmpty || $0.title?.contains(title) == true)
    }
    if windows.count == 1 { target = windows[0] }
    if target == nil { try await Task.sleep(for: .milliseconds(60)) }
} while target == nil && ContinuousClock.now < until
guard let window = target else { fatalError("No unique on-screen native window for \(args[1]) title \(title)") }
let filter = SCContentFilter(desktopIndependentWindow: window)
let config = SCStreamConfiguration()
config.width = Int(ceil(window.frame.width * CGFloat(filter.pointPixelScale) / 2)) * 2
config.height = Int(ceil(window.frame.height * CGFloat(filter.pointPixelScale) / 2)) * 2
config.pixelFormat = kCVPixelFormatType_32BGRA
config.showsCursor = false
config.ignoreShadowsSingleWindow = true
config.queueDepth = 5
config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
let capture = try Capture(directory, width: config.width, height: config.height)
let stream = SCStream(filter: filter, configuration: config, delegate: capture)
try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
func completed(_ operation: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, any Error>) in
        operation { error in
            if let error { result.resume(throwing: error) } else { result.resume() }
        }
    }
}
try await completed { stream.startCapture(completionHandler: $0) }
try Data().write(to: directory.appendingPathComponent("armed"), options: .atomic)
let timeout = ContinuousClock.now + .seconds(110)
while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) {
    if ContinuousClock.now >= timeout { fatalError("Pixel observer timed out") }
    try await Task.sleep(for: .milliseconds(20))
}
do {
    try await completed { stream.stopCapture(completionHandler: $0) }
} catch {
    capture.queue.sync { capture.ended = error.localizedDescription }
}
let clock = CACurrentMediaTime()
let clockError = abs(capture.seconds(mach_absolute_time()) - clock)
try capture.queue.sync {
    try capture.pixels.close()
    let output = Coverage(pid: window.owningApplication?.processID ?? 0, window: window.windowID,
        title: window.title ?? "", width: config.width, height: config.height, timebaseNumerator: capture.base.numer,
        timebaseDenominator: capture.base.denom, hostClockErrorSeconds: clockError, windowStreamEnded: capture.ended, frames: capture.frames)
    try JSONEncoder().encode(output).write(to: directory.appendingPathComponent("frames.json"), options: .atomic)
}
