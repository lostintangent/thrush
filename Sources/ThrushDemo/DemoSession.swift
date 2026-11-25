import SwiftUI
import Thrush
import ThrushConnection
import ThrushUI

struct DemoOptions {
    enum Scene: String, CaseIterable {
        case shell, editor, log, vim, prompt, glyphs
        case noticeConnecting = "notice-connecting"
        case noticeReconnecting = "notice-reconnecting"
        case noticeReplacement = "notice-replacement"
        case noticeDisplaced = "notice-displaced"
        case noticeEnded = "notice-ended"

        var capturesNotice: Bool { rawValue.hasPrefix("notice-") }
    }
    enum Appearance: String { case system, light, dark }

    let endpoint: URL
    var scene: Scene
    let appearance: Appearance
    let customTheme: Bool
    let cyclesAppearance: Bool
    let keyboard: Bool
    let benchmarkURL: URL?
    let interactionURL: URL?
    let runsWorkflowDriver: Bool

    init(_ arguments: [String] = CommandLine.arguments) {
        func value(after key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--") else { return nil }
            return arguments[index + 1]
        }
        runsWorkflowDriver = value(after: "--workflow-driver") != nil && value(after: "--workflow-output") != nil
        let address = value(after: "--endpoint") ?? "http://127.0.0.1:9138"
        // An invalid user-provided address fails through the same visible connection error.
        endpoint = URL(string: address) ?? URL(filePath: address)
        scene = value(after: "--scene").flatMap(Scene.init(rawValue:)) ?? .shell
        appearance = value(after: "--appearance").flatMap(Appearance.init(rawValue:)) ?? .system
        customTheme = value(after: "--theme") == "custom"
        cyclesAppearance = arguments.contains("--cycle-appearance")
        if arguments.contains("--benchmark") {
            benchmarkURL = value(after: "--benchmark").map { URL(fileURLWithPath: $0) }
                ?? URL.documentsDirectory.appending(path: "render.json")
        } else {
            benchmarkURL = nil
        }
        if arguments.contains("--interaction-check") {
            interactionURL = value(after: "--interaction-check").map { URL(fileURLWithPath: $0) }
                ?? URL.documentsDirectory.appending(path: "interactions.json")
        } else {
            interactionURL = nil
        }
        keyboard = arguments.contains("--keyboard") || (!arguments.contains("--hide-keyboard") && benchmarkURL == nil)
    }
}

/// State specific to the demo: replay selection, appearance and optional measurements.
/// TerminalPane owns the socket lifecycle and native interactions in each connected scene.
@MainActor
final class DemoSession: ObservableObject {
    let view = TerminalView(frame: .zero)
    private(set) var options: DemoOptions
    @Published private(set) var isActive = false
    @Published var theme: TerminalTheme?
    @Published private(set) var connection: TerminalConnection?
    private(set) var endpointError: String?

    var onThemeChange: ((TerminalTheme) -> Void)?
    var onBenchmarkFinished: ((Bool) -> Void)?
    var onFirstOutput: (() -> Void)?
    var onFirstUsable: (() -> Void)?
    private(set) var hasUsableShell = false
    var onReady: ((Bool) -> Void)?
    var onOutput: ((UInt64, CFTimeInterval) -> Void)?
    var onExit: (() -> Void)?
    private var interaction: InteractionBenchmark?
    private var benchmarkTask: Task<Void, Never>?
    private var benchmarkStarted = false

    init(options: DemoOptions) {
        self.options = options
        theme = options.customTheme ? Self.customTheme : nil
        if options.benchmarkURL != nil {
            view.theme = theme
            view.onThemeChange = { [weak self] in self?.onThemeChange?($0) }
            view.onGridSizeChange = { [weak self] _ in self?.scheduleRenderBenchmark() }
        } else {
            prepareConnection()
        }
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if options.benchmarkURL != nil {
            view.setRenderingActive(active)
            if active { scheduleRenderBenchmark() }
        }
    }

    func replay(_ scene: DemoOptions.Scene) {
        options.scene = scene
        prepareConnection()
    }

    private func prepareConnection() {
        let id = options.runsWorkflowDriver ? PaneWorkflowDriver.clientID : "thrush-\(options.scene.rawValue)-\(UUID().uuidString)"
        do {
            endpointError = nil
            let next = try TerminalConnection(baseURL: options.endpoint, clientID: id)
            connection = next
            if options.runsWorkflowDriver {
                PaneWorkflowDriver.startIfRequested(view: view, connection: next, setActive: setActive,
                                                    activateAction: view.activatePaneAction(named:))
            }
        } catch {
            endpointError = String(describing: error)
            connection = nil
        }
    }

    func pane(_ connection: TerminalConnection) -> TerminalPane {
        var pane = TerminalPane(connection, isActive: isActive, theme: theme, onExit: { [weak self] in self?.onExit?() })
        pane.preparedView = view
        pane.assumesVisibleForBenchmark = options.interactionURL != nil || options.runsWorkflowDriver || options.cyclesAppearance
        pane.onResolvedTheme = { [weak self] in self?.onThemeChange?($0) }
        pane.onReady = { [weak self] resumed in
            guard let self else { return }
            if options.scene == .glyphs {
                view.selection = .init(anchorRow: 1, anchorColumn: 2, headRow: 1, headColumn: 2)
            }
            if !resumed { markShellUsable() }
            onReady?(resumed)
        }
        pane.onOutput = { [weak self] generation, receivedAt in
            guard let self else { return }
            markShellUsable()
            interaction?.received(generation: generation, at: receivedAt)
            onOutput?(generation, receivedAt)
            let first = onFirstOutput
            onFirstOutput = nil
            first?()
            startInteractionCheck()
        }
        if options.interactionURL != nil {
            pane.onWriteStarted = { [weak self] time in
                Task { @MainActor in self?.interaction?.writeStarted(at: time) }
            }
        }
        return pane
    }

    private func markShellUsable() {
        guard !hasUsableShell else { return }
        hasUsableShell = true
        onFirstUsable?()
        onFirstUsable = nil
    }

    private func startInteractionCheck() {
        guard !benchmarkStarted, let url = options.interactionURL else { return }
        benchmarkStarted = true
        let probe = InteractionBenchmark(view: view)
        interaction = probe
        benchmarkTask = Task {
            defer { interaction = nil }
            await runBenchmark(at: url, errorFile: "interaction-error.txt") { try await probe.run(reportURL: url) }
        }
    }

    private func scheduleRenderBenchmark() {
        guard !benchmarkStarted, isActive, let url = options.benchmarkURL, view.gridSize != nil else { return }
        benchmarkStarted = true
        benchmarkTask = Task {
            guard isActive, let size = view.gridSize else {
                benchmarkStarted = false
                return
            }
            await runBenchmark(at: url, errorFile: "render-error.txt") {
                try await RenderBenchmark.run(on: view, size: size, reportURL: url)
            }
        }
    }

    private func runBenchmark(at url: URL, errorFile: String, run: () async throws -> Void) async {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await run()
            onBenchmarkFinished?(true)
        } catch {
            let message = "Thrush benchmark failed: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            try? message.write(to: url.deletingLastPathComponent().appending(path: errorFile),
                               atomically: true, encoding: .utf8)
            onBenchmarkFinished?(false)
        }
    }

    static var customTheme: TerminalTheme {
        func rgb(_ hex: UInt32) -> Terminal.RGB {
            .init(red: UInt8(hex >> 16), green: UInt8(truncatingIfNeeded: hex >> 8), blue: UInt8(truncatingIfNeeded: hex))
        }
        // The host supplies Ember's color study. Metrics and the underlying grid stay Slate's.
        return TerminalTheme(palette: .init(foreground: rgb(0xEEE4D6), background: rgb(0x1C1A18), ansi: [
            0x12110F, 0xDE8676, 0xA6BD89, 0xDDB278, 0x98ABD0, 0xC99DAF, 0x88B9B0, 0xCFC2AD,
            0x978C80, 0xF0A493, 0xBFDAA1, 0xF4CF93, 0xB5C9E8, 0xE3B9C9, 0xA6D4CB, 0xF8EEDD,
        ].map(rgb)), cursor: rgb(0xF0D9B4), cursorInk: rgb(0x1C1A18), selection: rgb(0x78634E),
        selectionInk: rgb(0xFFF4E1))
    }

}
