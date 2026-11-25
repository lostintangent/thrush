import AppKit
import AVFoundation
import ScreenCaptureKit

func failure(_ message: String) -> NSError {
    NSError(domain: "NativeWindowCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

struct Frame: Encodable {
    let pts: Int64
    let timescale: Int32
    let offset: UInt64
    let rowBytes: Int
    var time: CMTime { CMTime(value: pts, timescale: timescale) }
}

struct Recording: Encodable {
    let width: Int
    let height: Int
    let pixelFormat = "BGRA"
    let frames: [Frame]
    let stopPTS: Int64
    let stopTimescale: Int32
}

/// ScreenCaptureKit owns a small pool of display surfaces. Copy each real frame to disk
/// and return the surface immediately. Encoding happens after capture on the same bytes.
final class WindowFrames: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "thrush.capture.frames")
    let raw: URL
    let handle: FileHandle
    let ready: URL
    private var frames: [Frame] = []
    private var width = 0
    private var height = 0

    init(output: URL, ready: URL) throws {
        self.ready = ready
        raw = output.deletingPathExtension().appendingPathExtension("bgra")
        guard FileManager.default.createFile(atPath: raw.path, contents: nil) else { throw failure("Cannot create frame archive") }
        handle = try FileHandle(forWritingTo: raw)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) { fail(error) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid, CMSampleBufferDataIsReady(sample),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let value = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: value),
              status == .complete || status == .started, let image = sample.imageBuffer else { return }
        do { try store(image, time: sample.presentationTimeStamp) } catch { fail(error) }
    }

    func store(_ image: CVPixelBuffer, time: CMTime) throws {
        guard time.isNumeric, CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA else {
            throw failure("Invalid frame time or pixel format")
        }
        if let last = frames.last, time <= last.time { throw failure("Non-increasing ScreenCaptureKit timestamp") }
        let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
        guard frames.isEmpty || (width == w && height == h) else { throw failure("Window recording dimensions changed") }
        width = w
        height = h
        guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { throw failure("Cannot lock frame") }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { throw failure("Missing frame storage") }
        let stride = CVPixelBufferGetBytesPerRow(image)
        let frame = Frame(pts: time.value, timescale: time.timescale, offset: try handle.offset(), rowBytes: stride)
        try handle.write(contentsOf: Data(bytesNoCopy: base, count: stride * h, deallocator: .none))
        frames.append(frame)
        if frames.count == 1 { try Data().write(to: ready, options: .atomic) }
    }

    func finish(stop: CMTime) throws -> Recording {
        try handle.close()
        guard let last = frames.last, stop.isNumeric, stop >= last.time else { throw failure("No frames or invalid source stop time") }
        return Recording(width: width, height: height, frames: frames, stopPTS: stop.value, stopTimescale: stop.timescale)
    }

    private func fail(_ error: any Error) -> Never {
        FileHandle.standardError.write(Data("Screen capture failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

/// Append each delivered image once at its original timestamp. The last image remains
/// on screen until the source clock reaches stop. No idle frames are interpolated.
func makeMovie(_ recording: Recording, raw: URL, output: URL) async throws {
    let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
    var format: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCVPixelFormatType_32BGRA,
        width: Int32(recording.width), height: Int32(recording.height), extensions: nil, formatDescriptionOut: &format)
    guard status == noErr, let format else { throw failure("Cannot describe raw video frames") }
    // QuickTime accepts native BGRA without a codec. This preserves exact text colors
    // and also works on hosted Macs without a hardware video encoder.
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
    let first = recording.frames[0].time
    input.mediaTimeScale = first.timescale
    writer.movieTimeScale = first.timescale
    guard writer.canAdd(input) else { throw failure("Cannot add QuickTime video input") }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? failure("Cannot start QuickTime writer") }
    writer.startSession(atSourceTime: first)
    let source = try FileHandle(forReadingFrom: raw)
    defer { try? source.close() }
    for frame in recording.frames {
        let deadline = ContinuousClock.now + .seconds(10)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, ContinuousClock.now < deadline else {
                throw writer.error ?? failure("QuickTime writer stalled")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, recording.width, recording.height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, let buffer,
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw failure("Cannot allocate movie frame") }
        do {
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let size = frame.rowBytes * recording.height
            guard let dest = CVPixelBufferGetBaseAddress(buffer), let data = try source.read(upToCount: size),
                  data.count == size else { throw failure("Incomplete raw frame") }
            data.withUnsafeBytes { bytes in
                for row in 0..<recording.height {
                    memcpy(dest + row * CVPixelBufferGetBytesPerRow(buffer), bytes.baseAddress! + row * frame.rowBytes, recording.width * 4)
                }
            }
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: frame.time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample, input.append(sample) else {
            throw writer.error ?? failure("Cannot append raw video frame")
        }
    }
    writer.endSession(atSourceTime: CMTime(value: recording.stopPTS, timescale: recording.stopTimescale))
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? failure("Cannot finalize movie") }
}
guard CommandLine.arguments.count == 5, let pid = Int32(CommandLine.arguments[1]) else {
    fatalError("Usage: record-window PID OUTPUT.mov READY-FILE STOP-FILE")
}
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let ready = URL(fileURLWithPath: CommandLine.arguments[3])
let stop = URL(fileURLWithPath: CommandLine.arguments[4])
_ = NSApplication.shared
let title = ProcessInfo.processInfo.environment["THRUSH_WINDOW_TITLE"]
let searchUntil = ContinuousClock.now + .seconds(12)
var target: SCWindow?
repeat {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    target = content.windows.first { window in
        let matchesTitle = title.map { window.title?.contains($0) == true } ?? true
        return window.owningApplication?.processID == pid && window.windowLayer == 0 &&
            !window.frame.isEmpty && matchesTitle
    }
    if target == nil { try await Task.sleep(for: .milliseconds(150)) }
} while target == nil && ContinuousClock.now < searchUntil
guard let window = target else { fatalError("No matching native window for PID \(pid)") }
let filter = SCContentFilter(desktopIndependentWindow: window)
let configuration = SCStreamConfiguration()
let scale = CGFloat(filter.pointPixelScale)
configuration.width = Int(ceil(window.frame.width * scale / 2)) * 2
configuration.height = Int(ceil(window.frame.height * scale / 2)) * 2
configuration.showsCursor = false
configuration.ignoreShadowsSingleWindow = true
configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
func completed(_ call: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, any Error>) in
        call { error in
            if let error { result.resume(throwing: error) } else { result.resume() }
        }
    }
}
configuration.pixelFormat = kCVPixelFormatType_32BGRA
configuration.queueDepth = 6
let recorder = try WindowFrames(output: output, ready: ready)
let capture = SCStream(filter: filter, configuration: configuration, delegate: recorder)
try capture.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
try await completed { capture.startCapture(completionHandler: $0) }
let deadline = ContinuousClock.now + .seconds(120)
while !FileManager.default.fileExists(atPath: stop.path) {
    if ContinuousClock.now > deadline { throw failure("Timed out waiting for recording stop") }
    try await Task.sleep(for: .milliseconds(35))
}
try await completed { capture.stopCapture(completionHandler: $0) }
let recording = try recorder.queue.sync {
    try recorder.finish(stop: CMClockGetTime(capture.synchronizationClock ?? CMClockGetHostTimeClock()))
}
let times = output.deletingPathExtension().appendingPathExtension("frames.json")
try JSONEncoder().encode(recording).write(to: times, options: .atomic)
try await makeMovie(recording, raw: recorder.raw, output: output)
try FileManager.default.removeItem(at: recorder.raw)
print("Saved \(recording.frames.count) source frames at their native timestamps, \(recording.width)×\(recording.height)")
