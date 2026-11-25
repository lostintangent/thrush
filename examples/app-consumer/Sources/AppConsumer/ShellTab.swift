import Thrush

@MainActor
struct ShellTab {
    let shell: TerminalShell

    init(clientID: String, api: ServerAPI) {
        shell = TerminalShell(clientID: clientID) { id, size in
            api.terminalSocket(clientID: id, size: size)
        }
    }

    var pane: TerminalPane { TerminalPane(shell) }
}
