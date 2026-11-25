@testable import ThrushUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The synchronized renderer accepts a generation only while its viewport belongs to a window.
@MainActor func mountTestView(_ view: TerminalView) -> AnyObject {
    #if os(macOS)
    _ = NSApplication.shared
    let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    #else
    let window = UIWindow(frame: view.frame)
    window.addSubview(view)
    #endif
    return window
}
