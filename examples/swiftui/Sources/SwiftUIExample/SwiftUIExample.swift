import SwiftUI

@main
struct SwiftUIExample: App {
    var body: some Scene {
        WindowGroup { ShellWindow() }
            .defaultSize(width: 720, height: 486)
    }
}
