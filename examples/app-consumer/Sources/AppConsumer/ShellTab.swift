import Thrush

@MainActor
struct ShellTab {
    let terminal: TerminalConnection

    init(clientID: String, api: ServerAPI) {
        terminal = TerminalConnection(clientID: clientID) { id, size in
            api.terminalSocket(clientID: id, size: size)
        }
    }

    var pane: TerminalPane { TerminalPane(terminal) }
}
