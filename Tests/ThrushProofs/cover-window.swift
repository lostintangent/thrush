// A second application covers only the test terminal's window on the active desktop.
import AppKit

@main @MainActor
enum CoverWindow {
    static func main() {
        let coordinates = CommandLine.arguments.dropFirst().compactMap(Double.init)
        guard coordinates.count == 4 else { exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let rect = NSRect(x: coordinates[0], y: coordinates[1], width: coordinates[2], height: coordinates[3])
        let capturesFocus = CommandLine.arguments.contains("--capture-geometry")
        let window = NSWindow(contentRect: rect.insetBy(dx: -12, dy: -12),
                              styleMask: capturesFocus ? .titled : .borderless,
                              backing: .buffered, defer: false)
        window.title = "Thrush lifecycle test"
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.level = .floating
        if capturesFocus { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
        app.activate()
        if let index = CommandLine.arguments.firstIndex(of: "--capture-geometry"),
           index + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            do { try JSONEncoder().encode(window.frame).write(to: url, options: .atomic) }
            catch { exit(2) }
        }
        withExtendedLifetime(window) { app.run() }
    }
}
