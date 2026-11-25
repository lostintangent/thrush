import Thrush

@MainActor
struct ShellTab {
    let session: TerminalSession

    init(tabID: String, api: ServerAPI) {
        session = TerminalSession { size in
            api.terminalSocket(clientID: tabID, size: size)
        }
    }

    init(openTransport: @escaping @Sendable (Terminal.Size) async throws -> any TerminalTransport) {
        session = TerminalSession(openTransport: openTransport)
    }

    var pane: TerminalPane { TerminalPane(session) }
}
