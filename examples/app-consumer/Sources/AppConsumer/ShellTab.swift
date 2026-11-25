import Thrush

@MainActor
struct ShellTab {
    let session: TerminalSession

    init(tabID: String, api: ServerAPI) {
        session = TerminalSession { size in
            api.terminalSocket(clientID: tabID, size: size)
        }
    }

    var pane: TerminalPane { TerminalPane(session) }
}
