import Thrush

@MainActor
struct ShellTab {
    let session: TerminalSession

    init(tabID: String, api: ServerAPI) {
        session = TerminalSession { size in
            api.terminalSocket(clientID: tabID, size: size)
        }
    }

    init<Channel: TerminalTransport>(openChannel: @escaping @Sendable (Terminal.Size) async throws -> Channel) {
        session = TerminalSession(openTransport: { size in try await openChannel(size) })
    }

    var pane: TerminalPane { TerminalPane(session) }
}
