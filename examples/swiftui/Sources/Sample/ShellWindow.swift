import Foundation
import SwiftUI
import Thrush

// Command Line Tools lack SwiftUI's @State macro, so the window holds an ObservableObject.
@MainActor final class WindowModel: ObservableObject {
    @Published private(set) var tab = makeTab()

    func newShell() {
        guard tab.session.hasEnded else { return }
        tab = Self.makeTab()
    }

    private static func makeTab() -> ShellTab {
        ShellTab(tabID: UUID().uuidString, api: ServerAPI(session: .shared))
    }
}

struct ShellWindow: View {
    @StateObject private var model = WindowModel()

    var body: some View {
        NavigationStack {
            TerminalView(model.tab.session)
                .navigationTitle(title)
                .toolbar {
                    // The spacer keeps the Mac toolbar while the shell runs, so New Shell doesn't take a row from the grid.
                    ToolbarSpacer(.flexible)
                    if model.tab.session.hasEnded {
                        ToolbarItem { Button("New Shell", action: model.newShell) }
                    }
                }
                #if os(iOS)
                // The terminal fills the screen until the shell ends and the bar offers New Shell.
                .toolbarVisibility(model.tab.session.hasEnded ? .visible : .hidden, for: .navigationBar)
                #endif
        }
    }

    private var title: String {
        let session = model.tab.session
        return session.title.isEmpty ? "Terminal" : session.title
    }
}
