import AppKit
import AVFoundation
import ScreenCaptureKit

// Record only the specified native app's window. Native recording callbacks let the
// driver start the command after capture begins and wait for the movie to finalize.
final class Recording: NSObject, SCRecordingOutputDelegate {
    let ready: URL
    let finished: URL
    init(ready: URL, finished: URL) {
        self.ready = ready
        self.finished = finished
    }
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        try? Data().write(to: ready)
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        try? Data().write(to: finished)
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        FileHandle.standardError.write(Data("Screen recording failed: \(error)\n".utf8))
        exit(1)
    }
}

guard CommandLine.arguments.count == 5, let pid = Int32(CommandLine.arguments[1]) else {
    fatalError("Usage: record-window PID OUTPUT.mov READY-FILE STOP-FILE")
}
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let ready = URL(fileURLWithPath: CommandLine.arguments[3])
let stop = URL(fileURLWithPath: CommandLine.arguments[4])
let done = ready.appendingPathExtension("finished")
let delegate = Recording(ready: ready, finished: done)
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
let capture = SCStream(filter: filter, configuration: configuration, delegate: nil)
let settings = SCRecordingOutputConfiguration()
settings.outputURL = output
settings.outputFileType = .mov
settings.videoCodecType = .h264
let recorder = SCRecordingOutput(configuration: settings, delegate: delegate)
try capture.addRecordingOutput(recorder)
func completed(_ call: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, any Error>) in
        call { error in
            if let error { result.resume(throwing: error) } else { result.resume() }
        }
    }
}
try await completed { capture.startCapture(completionHandler: $0) }
let deadline = ContinuousClock.now + .seconds(120)
while !FileManager.default.fileExists(atPath: stop.path) {
    if ContinuousClock.now > deadline { fatalError("Timed out waiting to finish the recording") }
    try await Task.sleep(for: .milliseconds(35))
}
try await completed { capture.stopCapture(completionHandler: $0) }
let finishBy = ContinuousClock.now + .seconds(12)
while !FileManager.default.fileExists(atPath: done.path) {
    if ContinuousClock.now > finishBy { fatalError("Window recording did not finalize") }
    try await Task.sleep(for: .milliseconds(35))
}
