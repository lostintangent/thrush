import AppKit
import AVFoundation
import ScreenCaptureKit

// Keep a small gray copy of every distinct window or movie frame, so the analyzer can judge
// each third of the grid. Mac frames carry their WindowServer display time on the host clock.
//
//   burst-frames record PID WINDOW-ID OUTPUT-DIR STOP-FILE
//   burst-frames movie MOVIE OUTPUT-DIR

func failure(_ message: String) -> NSError {
    NSError(domain: "BurstFrames", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

struct Frame: Encodable {
    let time: Double
    let displayAt: Double?
}

struct Report: Encodable {
    let sourceWidth: Int
    let sourceHeight: Int
    let factor: Int
    let width: Int
    let height: Int
    let frames: [Frame]
}

final class GrayFrames {
    let pixels: FileHandle
    let directory: URL
    var frames = [Frame]()
    var size: (width: Int, height: Int)?

    init(_ directory: URL) throws {
        self.directory = directory
        let path = directory.appending(path: "window.gray")
        guard FileManager.default.createFile(atPath: path.path, contents: nil) else { throw failure("Cannot create gray frames") }
        pixels = try FileHandle(forWritingTo: path)
    }

    static func factor(_ width: Int) -> Int { max(1, width / 240) }

    func append(_ image: CVPixelBuffer, time: Double, displayAt: Double?) throws {
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        guard CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA else { throw failure("Expected BGRA frames") }
        guard size == nil || size! == (width, height) else { throw failure("Frame size changed") }
        size = (width, height)
        guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) else { throw failure("Cannot read frame") }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(image), f = Self.factor(width)
        let w = width / f, h = height / f
        var gray = Data(count: w * h)
        gray.withUnsafeMutableBytes { bytes in
            let out = bytes.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<h {
                let row = base + (y * f + f / 2) * stride
                for x in 0..<w {
                    let p = row + (x * f + f / 2) * 4
                    out[y * w + x] = UInt8((Int(p[0]) + 2 * Int(p[1]) + Int(p[2])) / 4)
                }
            }
        }
        try pixels.write(contentsOf: gray)
        frames.append(Frame(time: time, displayAt: displayAt))
    }

    func finish() throws {
        try pixels.close()
        guard let size, !frames.isEmpty else { throw failure("No frames") }
        let f = Self.factor(size.width)
        let report = Report(sourceWidth: size.width, sourceHeight: size.height, factor: f,
                            width: size.width / f, height: size.height / f, frames: frames)
        try JSONEncoder().encode(report).write(to: directory.appending(path: "window.json"), options: .atomic)
        print("Saved \(frames.count) frames at \(size.width / f)×\(size.height / f)")
    }
}

final class WindowStream: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "thrush.burst.frames")
    let gray: GrayFrames
    var lastTicks: UInt64 = 0
    var timebase = mach_timebase_info_data_t()

    init(_ gray: GrayFrames) {
        self.gray = gray
        mach_timebase_info(&timebase)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        FileHandle.standardError.write(Data("Screen capture stopped: \(error)\n".utf8))
        exit(1)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid, let image = sample.imageBuffer,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
              let status = (info[.status] as? NSNumber).flatMap({ SCFrameStatus(rawValue: $0.intValue) }),
              status == .complete || status == .started,
              let ticks = (info[.displayTime] as? NSNumber)?.uint64Value, ticks > lastTicks else { return }
        lastTicks = ticks
        let seconds = Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        do {
            try gray.append(image, time: sample.presentationTimeStamp.seconds, displayAt: seconds)
        } catch {
            FileHandle.standardError.write(Data("Frame failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

func completed(_ call: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, any Error>) in
        call { error in
            if let error { result.resume(throwing: error) } else { result.resume() }
        }
    }
}

func record(pid: Int32, windowID: CGWindowID, directory: URL, stop: URL) async throws {
    let until = ContinuousClock.now + .seconds(12)
    var target: SCWindow?
    repeat {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        target = content.windows.first { $0.owningApplication?.processID == pid && $0.windowID == windowID }
        if target == nil { try await Task.sleep(for: .milliseconds(150)) }
    } while target == nil && ContinuousClock.now < until
    guard let window = target else { throw failure("No window \(windowID) for PID \(pid)") }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    configuration.width = Int(ceil(window.frame.width * scale))
    configuration.height = Int(ceil(window.frame.height * scale))
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    // Ask for more than the display rate, so the stream never throttles a displayed frame.
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 240)
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.queueDepth = 8
    let gray = try GrayFrames(directory)
    let output = WindowStream(gray)
    let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
    try await completed { stream.startCapture(completionHandler: $0) }
    // A static window delivers no frames, so the stream is ready once it starts.
    // The peer's first output after this changes the window.
    try Data().write(to: directory.appending(path: "recording-start"), options: .atomic)
    let deadline = ContinuousClock.now + .seconds(180)
    while !FileManager.default.fileExists(atPath: stop.path) {
        if ContinuousClock.now > deadline { throw failure("Timed out waiting for the stop file") }
        try await Task.sleep(for: .milliseconds(20))
    }
    try await completed { stream.stopCapture(completionHandler: $0) }
    try output.queue.sync { try gray.finish() }
}

func decode(movie: URL, directory: URL) async throws {
    let asset = AVURLAsset(url: movie)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw failure("No video track") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? failure("Cannot read movie") }
    let gray = try GrayFrames(directory)
    while let sample = output.copyNextSampleBuffer() {
        let time = sample.presentationTimeStamp.seconds
        guard time.isFinite, let image = sample.imageBuffer else { continue }
        try gray.append(image, time: time, displayAt: nil)
    }
    guard reader.status == .completed else { throw reader.error ?? failure("Movie ended early") }
    try gray.finish()
}

let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "record" where arguments.count == 6:
    _ = NSApplication.shared
    guard let pid = Int32(arguments[2]), let id = CGWindowID(arguments[3]) else { throw failure("Invalid PID or window") }
    try await record(pid: pid, windowID: id, directory: URL(fileURLWithPath: arguments[4]), stop: URL(fileURLWithPath: arguments[5]))
case "movie" where arguments.count == 4:
    try await decode(movie: URL(fileURLWithPath: arguments[2]), directory: URL(fileURLWithPath: arguments[3]))
default:
    fatalError("Usage: burst-frames record PID WINDOW-ID OUTPUT-DIR STOP-FILE | movie MOVIE OUTPUT-DIR")
}
