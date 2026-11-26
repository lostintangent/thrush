import AppKit
import AVFoundation
import ScreenCaptureKit

func failure(_ message: String) -> NSError {
    NSError(domain: "NativeWindowCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func log(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

struct Frame: Encodable {
    let source: String
    let screenshotRequestedPTS: Int64?
    let screenshotRequestedTimescale: Int32?
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
    private var sawCallback = false
    private var streamUpdates = 0
    private var lastStreamUpdate = ContinuousClock.now
    private var screenshotPending = false
    private var loggedScreenshot = false
    private var finished = false
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
        receive(sample, type: type)
    }

    func receive(_ sample: CMSampleBuffer, type: SCStreamOutputType) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        let info = (attachments as? [[SCStreamFrameInfo: Any]])?.first
        let status = (info?[.status] as? NSNumber).flatMap { SCFrameStatus(rawValue: $0.intValue) }
        let time = sample.presentationTimeStamp
        if !sawCallback {
            sawCallback = true
            log("First callback type=\(type.rawValue) status=\(String(describing: status?.rawValue)) " +
                "pts=\(time.value)/\(time.timescale) valid=\(sample.isValid) dataReady=\(CMSampleBufferDataIsReady(sample)) " +
                "image=\(sample.imageBuffer != nil) attachments=\(String(describing: attachments))")
        }
        guard !finished, type == .screen, sample.isValid, time.isNumeric, let image = sample.imageBuffer,
              status != .stopped && status != .suspended && status != .blank else { return }
        // An idle first buffer can still contain the current WindowServer image.
        guard frames.isEmpty || status == .complete || status == .started else { return }
        do {
            try store(image, time: time, source: "stream")
            if status == .complete || status == .started {
                streamUpdates += 1
                lastStreamUpdate = .now
            }
        } catch { fail(error) }
    }

    /// A static or occluded window can deliver no stream samples. During a quiet period,
    /// independently observe that same window, one request at a time. A stream update
    /// received during the request takes priority. Screenshot PTS is observation completion.
    func captureIfQuiet(filter: SCContentFilter, configuration: SCStreamConfiguration, clock: CMClock) {
        queue.async {
            guard !self.finished, !self.screenshotPending, self.lastStreamUpdate.duration(to: .now) >= .milliseconds(250) else { return }
            self.screenshotPending = true
            let revision = self.streamUpdates
            let requested = CMClockGetTime(clock)
            if !self.loggedScreenshot {
                log("Requesting independent window screenshots after 250 ms without a new stream image")
                self.loggedScreenshot = true
            }
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                let received = CMClockGetTime(clock)
                self.queue.async {
                    self.screenshotPending = false
                    guard !self.finished, revision == self.streamUpdates else { return }
                    guard let image else {
                        log("Independent window screenshot failed: \(String(describing: error))")
                        return
                    }
                    do {
                        let pixels = try Self.bgra(image)
                        try self.store(pixels, time: received, source: "windowScreenshot", requested: requested)
                    } catch { self.fail(error) }
                }
            }
        }
    }

    static func bgra(_ image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw failure("Cannot allocate screenshot") }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: address, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { throw failure("Cannot read window screenshot") }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    func store(_ image: CVPixelBuffer, time: CMTime, source: String, requested: CMTime? = nil) throws {
        guard time.isNumeric, CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA else {
            throw failure("Invalid frame time or pixel format")
        }
        // A delayed stream callback can arrive after a screenshot of the same instant.
        // Preserve the native callback; the movie is ordered by its source timestamps below.
        if frames.last?.time == time { return }
        let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
        guard frames.isEmpty || (width == w && height == h) else { throw failure("Window recording dimensions changed") }
        width = w
        height = h
        guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { throw failure("Cannot lock frame") }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { throw failure("Missing frame storage") }
        let stride = CVPixelBufferGetBytesPerRow(image)
        let frame = Frame(source: source, screenshotRequestedPTS: requested?.value, screenshotRequestedTimescale: requested?.timescale,
                          pts: time.value, timescale: time.timescale, offset: try handle.offset(), rowBytes: stride)
        try handle.write(contentsOf: Data(bytesNoCopy: base, count: stride * h, deallocator: .none))
        frames.append(frame)
        if frames.count == 1 {
            log("First saved image source=\(source) pts=\(time.value)/\(time.timescale) size=\(w)x\(h)")
            try Data().write(to: ready, options: .atomic)
        }
    }

    func finish(stop: CMTime) throws -> Recording {
        finished = true
        try handle.close()
        frames.sort { $0.time == $1.time ? $0.source == "stream" && $1.source != "stream" : $0.time < $1.time }
        var seen: CMTime?
        frames.removeAll { frame in
            if frame.time == seen { return true }
            seen = frame.time
            return false
        }
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
            try source.seek(toOffset: frame.offset)
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
guard (5...6).contains(CommandLine.arguments.count), let pid = Int32(CommandLine.arguments[1]) else {
    fatalError("Usage: record-window PID OUTPUT.mov READY-FILE STOP-FILE [WINDOW-ID]")
}
let expectedID: CGWindowID?
if CommandLine.arguments.count == 6 {
    guard let id = CGWindowID(CommandLine.arguments[5]), id > 0 else { throw failure("Invalid window ID") }
    expectedID = id
} else {
    expectedID = nil
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
        let matchesID = expectedID.map { window.windowID == $0 } ?? true
        return window.owningApplication?.processID == pid && window.windowLayer == 0 &&
            !window.frame.isEmpty && matchesTitle && matchesID
    }
    if target == nil { try await Task.sleep(for: .milliseconds(150)) }
} while target == nil && ContinuousClock.now < searchUntil
guard let window = target else { fatalError("No matching native window for PID \(pid), requested ID \(String(describing: expectedID))") }
log("Selected PID \(pid), window \(window.windowID), title=\(window.title ?? "") frame=\(window.frame) onScreen=\(window.isOnScreen)")
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
let clock = capture.synchronizationClock ?? CMClockGetHostTimeClock()
try Data().write(to: ready.appendingPathExtension("armed"), options: .atomic)
log("Window capture armed; waiting for its first image")
let deadline = ContinuousClock.now + .seconds(120)
while !FileManager.default.fileExists(atPath: stop.path) {
    if ContinuousClock.now > deadline { throw failure("Timed out waiting for recording stop") }
    recorder.captureIfQuiet(filter: filter, configuration: configuration, clock: clock)
    try await Task.sleep(for: .milliseconds(16))
}
try await completed { capture.stopCapture(completionHandler: $0) }
let recording = try recorder.queue.sync {
    try recorder.finish(stop: CMClockGetTime(clock))
}
let times = output.deletingPathExtension().appendingPathExtension("frames.json")
try JSONEncoder().encode(recording).write(to: times, options: .atomic)
try await makeMovie(recording, raw: recorder.raw, output: output)
try FileManager.default.removeItem(at: recorder.raw)
print("Saved \(recording.frames.count) source frames at their native timestamps, \(recording.width)×\(recording.height)")
