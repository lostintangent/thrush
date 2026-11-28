import AppKit
import Darwin
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// Desktop-independent captures can still see an obscured native window on a locked Mac.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]), pid > 0 else {
    fail("Usage: capture-window.swift PID OUTPUT.png")
}

// ScreenCaptureKit can block inside either await when the desktop is locked. A process
// alarm can stop the one-shot helper even if the main actor never runs again.
signal(SIGALRM) { _ in _exit(124) }
var alarmSignal = sigset_t()
sigemptyset(&alarmSignal)
sigaddset(&alarmSignal, SIGALRM)
pthread_sigmask(SIG_UNBLOCK, &alarmSignal, nil)
alarm(15)

@MainActor
func capture(pid: Int32, to url: URL) async throws {
    _ = NSApplication.shared
    var target: SCWindow?
    let deadline = ContinuousClock.now + .seconds(6)
    repeat {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        target = content.windows.first { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && !$0.frame.isEmpty }
        if target == nil {
            guard kill(pid, 0) == 0 else { fail("No process \(pid).") }
            try await Task.sleep(for: .milliseconds(150))
        }
    } while target == nil && ContinuousClock.now < deadline
    guard let window = target else { fail("No window for process \(pid).") }

    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    configuration.width = Int((window.frame.width * CGFloat(filter.pointPixelScale)).rounded())
    configuration.height = Int((window.frame.height * CGFloat(filter.pointPixelScale)).rounded())
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    let image: CGImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("Cannot write PNG to \(url.path).") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("Could not finalize \(url.path).") }
}

do {
    try await capture(pid: pid, to: URL(fileURLWithPath: CommandLine.arguments[2]))
} catch {
    fail("Window capture failed: \(error.localizedDescription)")
}
