import SwiftUI
import Thrush

struct ProofOptions {
    enum Scene: String, CaseIterable {
        case shell, editor, log, vim, prompt, glyphs, styles, colors, links
        case spinnerOpening = "spinner-opening", spinnerReconnecting = "spinner-reconnecting"
        case ended = "shell-ended", reconnectTyping = "reconnect-typing"

        var capturesSessionState: Bool {
            switch self {
            case .spinnerOpening, .spinnerReconnecting, .ended, .reconnectTyping: true
            default: false
            }
        }
    }
    enum Appearance: String {
        case system, light, dark

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    /// The sample's endpoint, with the scene as its path for the scripted peers that serve several.
    let endpoint: URL?
    let scene: Scene
    let appearance: Appearance
    let cyclesAppearance: Bool
    let keyboard: Bool
    let benchmarkURL: URL?
    let interactionURL: URL?
    let runsWorkflowDriver: Bool
    let checksToolbar: Bool
    /// The toolbar proof adds the `.ignoresSafeArea()` apps wrote before the view extended under bars itself.
    let hostIgnoresSafeArea: Bool
    /// The Mac toolbar proof puts the terminal view in a split view's detail, beside a sidebar with its own toolbar item.
    let splitsToolbar: Bool
    /// The Mac toolbar proof keeps the window toolbar's background, which a split view draws per column.
    let showsToolbarBackground: Bool
    let frameTraceURL: URL?

    init(_ arguments: [String] = CommandLine.arguments) {
        func value(after key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--") else { return nil }
            return arguments[index + 1]
        }
        checksToolbar = arguments.contains("--toolbar-proof")
        hostIgnoresSafeArea = arguments.contains("--host-ignores-safe-area")
        splitsToolbar = value(after: "--toolbar-proof") == "split"
        showsToolbarBackground = arguments.contains("--toolbar-background")
        runsWorkflowDriver = value(after: "--workflow-driver") != nil && value(after: "--workflow-output") != nil
        frameTraceURL = runsWorkflowDriver && arguments.contains("--trace-lifecycle-frames")
            ? value(after: "--workflow-output").map { URL(fileURLWithPath: $0).appending(path: "native-wire.jsonl") } : nil
        let sceneName = value(after: "--scene")
        scene = sceneName.flatMap(Scene.init(rawValue:)) ?? .shell
        // A scene alone plays from the peer on the sample's default port.
        endpoint = (value(after: "--endpoint") ?? sceneName.map { _ in "http://127.0.0.1:9138" })
            .map { Self.endpoint($0, scene: sceneName) }
        appearance = value(after: "--appearance").flatMap(Appearance.init(rawValue:)) ?? .system
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

    /// The runners pass an HTTP base address like http://127.0.0.1:9138, which the sample reads as a WebSocket origin.
    private static func endpoint(_ address: String, scene: String?) -> URL {
        var components = URLComponents(string: address)
        let schemes = ["http": "ws", "ws": "ws", "https": "wss", "wss": "wss"]
        guard let scheme = components?.scheme.flatMap({ schemes[$0] }), components?.host != nil else {
            FileHandle.standardError.write(Data("Pass an http or ws base address, like http://127.0.0.1:9138.\n".utf8))
            exit(EXIT_FAILURE)
        }
        components?.scheme = scheme
        if let scene { components?.path = "/" + scene }
        return components!.url!
    }
}

/// What the proofs add around the sample's window: their options, the probe they hand its terminal view,
/// and the checks and benchmarks that probe starts. The sample opens every session itself.
@MainActor
final class Proof: ObservableObject {
    static let shared = Proof(options: ProofOptions())

    let view = TerminalMetalView(frame: .zero)
    let options: ProofOptions
    @Published var theme: TerminalTheme?
    /// The workflow driver detaches and resumes the sample's view through the probe.
    @Published private(set) var isDetached = false
    /// The session the sample's view shows.
    private(set) var session: TerminalSession?
    private(set) var hasUsableSession = false
    var onReady: ((Bool) -> Void)?
    var onFirstOutput: (() -> Void)?
    var onFirstUsable: (() -> Void)?
    private let trace: WorkflowFrameTrace?
    private var nextShellTrace: (any WebSocketFrameTrace)?
    private var interaction: InteractionBenchmark?
    private var benchmarkTask: Task<Void, Never>?
    private var benchmarkStarted = false
    private var isRendering = false

    init(options: ProofOptions) {
        self.options = options
        if let endpoint = options.endpoint {
            // The sample reads its endpoint from user defaults, as `-endpoint URL` on its command line would set it.
            let defaults = UserDefaults.standard
            var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["endpoint"] = endpoint.absoluteString
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        do {
            trace = try options.frameTraceURL.map(WorkflowFrameTrace.init)
        } catch {
            FileHandle.standardError.write(Data("Could not open the frame trace: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
        nextShellTrace = trace
        if options.benchmarkURL != nil {
            view.onGridSizeChange = { [weak self] _ in self?.scheduleRenderBenchmark() }
        }
    }

    var probe: TerminalView.Probe {
        let assumesVisible = options.interactionURL != nil || options.runsWorkflowDriver || options.cyclesAppearance
        return TerminalView.Probe(metalView: view, isVisible: isDetached ? false : assumesVisible ? true : nil,
                                  observe: { [weak self] in self?.observe($0) },
                                  prepare: { [weak self] in await self?.prepare($0) })
    }

    /// The render benchmark draws while the app is in front, and its Mac app pauses while hidden.
    func setRendering(_ rendering: Bool) {
        guard options.benchmarkURL != nil, isRendering != rendering else { return }
        isRendering = rendering
        view.setDrawingVisible(rendering)
        if rendering { scheduleRenderBenchmark() }
    }

    /// Runs beside the window while it shows: the render benchmark's focus on the Mac, and the iPhone's
    /// orientation, keyboard and capture state.
    func attend() async {
        #if os(macOS)
        guard options.benchmarkURL != nil else { return }
        while view.window == nil {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
        }
        view.focusInput()
        #else
        var capture: (() -> Void)?
        var oriented = false
        var focused = !options.keyboard
        while true {
            if let root = view.window?.rootViewController?.view, let scene = root.window?.windowScene {
                if capture == nil { capture = PhoneCapture.observe(self, view: view, in: root) ?? {} }
                capture?()
                if scene.activationState == .foregroundActive {
                    if !oriented { PhoneCapture.orient(scene) }
                    oriented = true
                    if !focused, options.checksToolbar || hasUsableSession || options.benchmarkURL != nil {
                        focused = view.focusInput()
                    }
                }
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        #endif
    }

    #if os(iOS)
    func sceneChanged(to phase: ScenePhase) { setRendering(phase != .background) }
    #endif

    /// Runs before the sample's view first shows each session, so a trace hears its first attachment.
    private func prepare(_ next: TerminalSession) async {
        if let trace = nextShellTrace {
            nextShellTrace = nil
            await next.actor.trace(with: trace)
        }
        let first = session == nil
        session = next
        hasUsableSession = false
        #if os(macOS)
        onFirstUsable = { [weak self] in self?.view.focusInput() }
        #endif
        guard first else { return }
        if options.runsWorkflowDriver { startWorkflowDriver(next) }
        #if os(macOS)
        while view.window == nil { try? await Task.sleep(for: .milliseconds(10)) }
        if let window = view.window {
            MacSpinnerCapture.startIfRequested(proof: self, window: window)
            MacWindowLifecycleCheck.startIfRequested(proof: self, window: window)
        }
        #endif
    }

    private func startWorkflowDriver(_ first: TerminalSession) {
        WorkflowDriver.startIfRequested(view: view, session: first, trace: trace, setActive: { [weak self] in
            self?.isDetached = !$0
        }) { sockets, received, activate in
            let previous = self.session
            self.nextShellTrace = self.trace?.continuing(after: sockets, received: received)
            defer { self.nextShellTrace = nil }
            try activate()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while self.session === previous, .now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let next = self.session, next !== previous else {
                throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "The app’s New Shell button did not open a new session."])
            }
            return next
        }
    }

    private func observe(_ event: TerminalView.Probe.Event) {
        guard let session else { return }
        switch event {
        case .ready(let resumed):
            if options.scene == .glyphs {
                view.selection = .init(anchorRow: 1, anchorColumn: 2, headRow: 1, headColumn: 2)
            }
            if !resumed { markSessionUsable(session) }
            onReady?(resumed)
        case .output(let generation, let receivedAt):
            markSessionUsable(session)
            interaction?.received(generation: generation, at: receivedAt)
            let first = onFirstOutput
            onFirstOutput = nil
            first?()
            startInteractionCheck(session)
        }
    }

    private func markSessionUsable(_ session: TerminalSession) {
        guard !session.hasEnded, !hasUsableSession else { return }
        hasUsableSession = true
        onFirstUsable?()
        onFirstUsable = nil
    }

    private func startInteractionCheck(_ session: TerminalSession) {
        guard !benchmarkStarted, let url = options.interactionURL else { return }
        benchmarkStarted = true
        let probe = InteractionBenchmark(view: view, session: session)
        interaction = probe
        benchmarkTask = Task {
            defer { interaction = nil }
            await runBenchmark(at: url, errorFile: "interaction-error.txt") { try await probe.run(reportURL: url) }
        }
    }

    private func scheduleRenderBenchmark() {
        guard !benchmarkStarted, isRendering, let url = options.benchmarkURL, view.gridSize != nil else { return }
        benchmarkStarted = true
        benchmarkTask = Task {
            guard isRendering, let size = view.gridSize else {
                benchmarkStarted = false
                return
            }
            await runBenchmark(at: url, errorFile: "render-error.txt") {
                try await RenderBenchmark.run(on: view, size: size, reportURL: url)
            }
        }
    }

    private func runBenchmark(at url: URL, errorFile: String, run: () async throws -> Void) async {
        var success = true
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await run()
        } catch {
            success = false
            let message = "Thrush benchmark failed: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            try? message.write(to: url.deletingLastPathComponent().appending(path: errorFile),
                               atomically: true, encoding: .utf8)
        }
        #if os(macOS)
        if success { NSApp.terminate(nil) } else { exit(EXIT_FAILURE) }
        #endif
    }

    static var customTheme: TerminalTheme {
        func rgb(_ hex: UInt32) -> Terminal.RGB {
            .init(red: UInt8(hex >> 16), green: UInt8(truncatingIfNeeded: hex >> 8), blue: UInt8(truncatingIfNeeded: hex))
        }
        // The proofs supply the Ember palette from the design doc. The font and grid metrics stay the same.
        return TerminalTheme(palette: .init(foreground: rgb(0xEEE4D6), background: rgb(0x1C1A18), ansi: [
            0x12110F, 0xDE8676, 0xA6BD89, 0xDDB278, 0x98ABD0, 0xC99DAF, 0x88B9B0, 0xCFC2AD,
            0x978C80, 0xF0A493, 0xBFDAA1, 0xF4CF93, 0xB5C9E8, 0xE3B9C9, 0xA6D4CB, 0xF8EEDD,
        ].map(rgb)), cursor: rgb(0xF0D9B4), cursorInk: rgb(0x1C1A18), selection: rgb(0x78634E),
        selectionInk: rgb(0xFFF4E1))
    }

}
