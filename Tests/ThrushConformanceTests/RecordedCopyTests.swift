import Testing
@testable import ThrushConformance
import ThrushCore

/// Neovim and Helix, set to copy through the terminal, yank lines that reach the app's pasteboard.
/// The reference has no pasteboard, so the recordings prove these copies on Thrush alone.
@Test(arguments: [
    ("neovim program", "struct Circle {\n    var radius: Double\n"),
    ("helix program", "let label: Int = \"Area \\(circle.area)\"\n"),
])
func recordedYanksReachTheApp(_ name: String, _ text: String) throws {
    let recording = try #require(bundledCases.first { $0.name == name })
    var terminal = Terminal(size: Terminal.Size(columns: recording.size[0], rows: recording.size[1]))
    _ = terminal.write(recording.input)
    #expect(terminal.copiedText.take() == text)
}
