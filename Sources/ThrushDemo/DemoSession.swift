import QuartzCore
import Foundation
import Thrush
import ThrushConnection
import ThrushUI

struct DemoOptions {
    enum Scene: String, CaseIterable {
        case shell, editor, log, vim, prompt, glyphs
    }
    enum Appearance: String { case system, light, dark }

    let endpoint: URL
    var scene: Scene
    let appearance: Appearance
    let customTheme: Bool
    let keyboard: Bool
    let benchmarkURL: URL?
    let interactionURL: URL?

    init(_ arguments: [String] = CommandLine.arguments) {
        func value(after key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--") else { return nil }
            return arguments[index + 1]
        }
        let address = value(after: "--endpoint") ?? "http://127.0.0.1:9138"
        // An invalid user-provided address fails through the same visible connection error.
        endpoint = URL(string: address) ?? URL(filePath: address)
        scene = value(after: "--scene").flatMap(Scene.init(rawValue:)) ?? .shell
        appearance = value(after: "--appearance").flatMap(Appearance.init(rawValue:)) ?? .system
        customTheme = value(after: "--theme") == "custom"
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

/// The connection actor owns the mutable terminal. A native layout change and each output
/// notification request one immutable generation. Slow displays can skip intermediate draws.
@MainActor
final class DemoSession {
    let view = TerminalView(frame: .zero)
    private(set) var options: DemoOptions

    var onThemeChange: ((TerminalTheme) -> Void)?
    var onError: ((String) -> Void)?
    var onBenchmarkFinished: ((Bool) -> Void)?
    var onFirstOutput: (() -> Void)?
    private var connection: TerminalConnection?
    private var receiveTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var desiredSize: Terminal.Size?
    private var active = false
    private var ready = false
    private var sessionID = UUID()
    private var benchmarkStarted = false
    private var interaction: InteractionBenchmark?

    init(options: DemoOptions) {
        self.options = options
        view.onInput = { [weak self] in self?.send($0) }
        view.onGridSizeChange = { [weak self] in self?.resize(to: $0) }
        view.onThemeChange = { [weak self] theme in
            guard let self else { return }
            onThemeChange?(theme)
            if let connection { Task { await connection.setPalette(theme.palette) } }
        }
        if options.customTheme { view.theme = Self.customTheme }
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

    func setActive(_ newValue: Bool) {
        guard active != newValue else { return }
        active = newValue
        view.setRenderingActive(newValue)
        if newValue {
            startIfReady()
        } else {
            stopConnection()
        }
    }

    func replay(_ scene: DemoOptions.Scene) {
        stopConnection()
        options.scene = scene
        view.reset()
        startIfReady()
    }

    func send(_ input: Terminal.Input) {
        guard let connection, ready else { return }
        let tracing = interaction
        Task {
            do {
                if let tracing {
                    try await connection.send(input) {
                        let time = CACurrentMediaTime()
                        Task { @MainActor in tracing.writeStarted(at: time) }
                    }
                } else {
                    try await connection.send(input)
                }
            } catch { if self.connection === connection { onError?(String(describing: error)) } }
        }
    }

    private func resize(to size: Terminal.Size) {
        desiredSize = size
        if connection == nil {
            startIfReady()
        } else {
            synchronizeSize()
        }
    }

    private func startIfReady() {
        guard active, connection == nil, let size = desiredSize ?? view.gridSize else { return }
        if let report = options.benchmarkURL {
            guard !benchmarkStarted else { return }
            benchmarkStarted = true
            Task {
                // The scene and its first nonzero view layout supply the benchmark's actual grid.
                guard active, let size = view.gridSize else {
                    benchmarkStarted = false
                    return
                }
                do {
                    try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try await RenderBenchmark.run(on: view, size: size, reportURL: report)
                    onBenchmarkFinished?(true)
                } catch {
                    let message = "Render benchmark failed: \(error)\n"
                    FileHandle.standardError.write(Data(message.utf8))
                    try? message.write(to: report.deletingLastPathComponent().appending(path: "render-error.txt"), atomically: true, encoding: .utf8)
                    onBenchmarkFinished?(false)
                }
            }
            return
        }

        do {
            let id = "thrush-\(options.scene.rawValue)-\(sessionID.uuidString)"
            let connection = try TerminalConnection(baseURL: options.endpoint, clientID: id, size: size,
                                                    palette: view.resolvedTheme.palette)
            self.connection = connection
            receiveTask = Task { await consume(connection) }
        } catch {
            onError?(String(describing: error))
        }
    }

    private func consume(_ current: TerminalConnection) async {
        do {
            while !Task.isCancelled {
                let event = try await current.nextEvent()
                guard connection === current, !Task.isCancelled else { return }
                switch event {
                case .ready:
                    ready = true
                    view.reset()
                    if options.scene == .glyphs {
                        view.selection = .init(anchorRow: 1, anchorColumn: 2, headRow: 1, headColumn: 2)
                    }
                    synchronizeSize()
                case .output, .resynchronized:
                    await display(current, receivedAt: await current.lastReceiptTime, reset: event == .resynchronized)
                    onFirstOutput?()
                    onFirstOutput = nil
                    startInteractionCheckIfRequested()
                case .reconnecting:
                    ready = false
                case .displaced, .exit:
                    ready = false
                    return
                }
            }
        } catch {
            guard connection === current, !Task.isCancelled else { return }
            ready = false
            onError?(error.localizedDescription)
        }
    }

    private func display(_ current: TerminalConnection, receivedAt: TimeInterval? = nil, reset: Bool = false) async {
        let snapshot = await current.snapshot()
        guard connection === current else { return }
        if reset { view.reset() }
        if let receivedAt { interaction?.received(generation: snapshot.generation, at: receivedAt) }
        view.display(snapshot, receivedAt: receivedAt)
    }

    private func startInteractionCheckIfRequested() {
        guard !benchmarkStarted, let url = options.interactionURL else { return }
        benchmarkStarted = true
        let check = InteractionBenchmark(view: view)
        interaction = check
        Task {
            defer { interaction = nil }
            do {
                try await check.run(reportURL: url)
                onBenchmarkFinished?(true)
            } catch {
                let message = "Interaction benchmark failed: \(error)\n"
                FileHandle.standardError.write(Data(message.utf8))
                try? message.write(to: url.deletingLastPathComponent().appending(path: "interaction-error.txt"),
                                   atomically: true, encoding: .utf8)
                onBenchmarkFinished?(false)
            }
        }
    }

    private func synchronizeSize() {
        guard let current = connection, ready, resizeTask == nil else { return }
        resizeTask = Task {
            defer { if connection === current { resizeTask = nil } }
            var applied: Terminal.Size?
            do {
                while connection === current, let next = desiredSize, next != applied {
                    try await current.sendResize(to: next)
                    applied = next
                }
                if connection === current { await display(current) }
            } catch {
                if connection === current, !Task.isCancelled { onError?(error.localizedDescription) }
            }
        }
    }

    private func stopConnection() {
        receiveTask?.cancel()
        receiveTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        if let old = connection { Task { await old.detach() } }
        connection = nil
        ready = false
    }
}
