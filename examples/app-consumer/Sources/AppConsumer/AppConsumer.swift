import Foundation
import SwiftUI
import Thrush
#if os(iOS)
import UIKit
#endif

// The host owns its session and terminal endpoint. The standalone demo peer listens here.
struct ServerAPI: Sendable {
    let session: URLSession

    func terminalSocket(clientID: String, size: Terminal.Size) -> URLSessionWebSocketTask {
        let endpoint = URL(string: "ws://127.0.0.1:9138/socket")!
        return session.webSocketTask(with: endpoint.appending(queryItems: [
            .init(name: "service", value: "terminal"),
            .init(name: "clientId", value: clientID),
            .init(name: "cols", value: String(size.columns)),
            .init(name: "rows", value: String(size.rows)),
        ]))
    }
}

@main
struct AppConsumer: App {
    var body: some Scene {
        WindowGroup { ShellWindow() }
    }
}

@MainActor private final class WindowModel: ObservableObject {
    let tab = ShellTab(clientID: UUID().uuidString, api: ServerAPI(session: .shared))
    #if os(iOS)
    let interruptButton = InterruptButton()
    #endif
}

private struct ShellWindow: View {
    @StateObject private var model = WindowModel()

    var body: some View {
        NavigationStack {
            pane.navigationTitle(title)
        }
    }

    private var title: String {
        let shell = model.tab.shell
        let name = shell.title.isEmpty ? "Terminal" : shell.title
        return shell.hasExited ? "\(name) (Ended)" : name
    }

    @ViewBuilder private var pane: some View {
        #if os(iOS)
        TerminalPane(model.tab.shell, theme: .slateDark, keyboardAccessory: .custom(model.interruptButton))
        #else
        model.tab.pane
        #endif
    }
}

#if os(iOS)
/// A host can supply a UIKit control with terminal shortcuts of its own.
private final class InterruptButton: UIButton, TerminalInputAccessory {
    var onKeyPress: ((String, UIKeyModifierFlags) -> Void)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        setTitle("Interrupt (Control-C)", for: .normal)
        setTitleColor(.label, for: .normal)
        addAction(UIAction { [weak self] _ in self?.onKeyPress?("c", .control) }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { nil }
}
#endif
