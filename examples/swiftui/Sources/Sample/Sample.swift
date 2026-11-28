import SwiftUI

@main
struct Sample: App {
    var body: some Scene {
        WindowGroup { ShellWindow() }
            .defaultSize(width: 720, height: 494)
            #if os(macOS)
            .windowToolbarStyle(.unifiedCompact)
            #endif
    }
}
