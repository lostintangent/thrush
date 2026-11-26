import QuartzCore
import SwiftUI
import ThrushCore

/// A view that shows a terminal session while visible.
/// Keep the session in a model that outlives the view's SwiftUI updates.
///
/// Like a SwiftUI background, the view's canvas extends under any bar, toolbar or safe area its frame meets,
/// while its grid stays inside the safe area and above the iPhone keyboard. With the keyboard down, iPhone rows
/// run on under the home indicator.
@MainActor public struct TerminalView: View {
    private let session: TerminalSession
    private let isActive: Bool
    private let theme: TerminalTheme?
    private let fontSize: CGFloat?
    #if os(iOS)
    private var showsKeyRow = true
    #endif

    /// Creates a terminal view for a session, using the system appearance unless a theme is supplied.
    /// The view shows the session and, on iPhone, the key row above the keyboard.
    ///
    /// - Parameters:
    ///   - session: The session whose output and input the view presents.
    ///   - isActive: Pass `false` while hiding a tab that remains in the view hierarchy.
    ///   - theme: A theme override. The default follows the system appearance.
    ///   - fontSize: A size in points, from 6 through 96. The default is 14 on Mac and 13 on iPhone.
    public init(_ session: TerminalSession, isActive: Bool = true, theme: TerminalTheme? = nil,
                fontSize: CGFloat? = nil) {
        self.session = session
        self.isActive = isActive
        self.theme = theme
        self.fontSize = fontSize
    }

    #if os(iOS)
    /// Creates a terminal view that shows or hides the key row of Esc, Ctrl, Tab and arrow keys
    /// above the iPhone software keyboard. The row is shown by default.
    public init(_ session: TerminalSession, isActive: Bool = true, theme: TerminalTheme? = nil,
                fontSize: CGFloat? = nil, showsKeyRow: Bool) {
        self.init(session, isActive: isActive, theme: theme, fontSize: fontSize)
        self.showsKeyRow = showsKeyRow
    }
    #endif

    /// How the sample apps' benchmarks, captures and tests reach inside the view.
    package struct Probe {
        package enum Event {
            /// The shell is ready, or a resumed shell awaits its replay.
            case ready(resumed: Bool)
            /// Output from the wire reached the screen.
            case output(generation: UInt64, receivedAt: CFTimeInterval)
            /// The theme the view resolved from its override and the system appearance.
            case theme(TerminalTheme)
            /// The scheme of the canvas under any bars.
            case canvas(ColorScheme)
        }

        /// A native view to present instead of a new one, so a check can drive it directly.
        package var metalView: TerminalMetalView?
        /// Keeps the session attached when the window can't be seen, as on a headless runner.
        package var assumesVisible = false
        /// Called on the main actor for each event.
        package var observe: ((Event) -> Void)?

        package init(metalView: TerminalMetalView? = nil, assumesVisible: Bool = false,
                     observe: ((Event) -> Void)? = nil) {
            self.metalView = metalView
            self.assumesVisible = assumesVisible
            self.observe = observe
        }
    }

    package var probe = Probe()

    // SwiftUI may retain a tab or navigation destination's native view while it is offscreen.
    // The coordinator combines appearance callbacks with actual window and scene visibility.
    @StateObject private var coordinator = Coordinator()

    /// The terminal surface for this session.
    public var body: some View {
        Representable(view: self, coordinator: coordinator)
            // The canvas insets the grid itself, from the native safe area and keyboard.
            .ignoresSafeArea()
            .onAppear { coordinator.setPresented(true) }
            .onDisappear { coordinator.setPresented(false) }
            #if os(iOS)
            .toolbarColorScheme(coordinator.barScheme, for: .navigationBar)
            #endif
    }

    fileprivate func makeCanvas(_ coordinator: Coordinator) -> CanvasView {
        let canvas = CanvasView(terminal: probe.metalView ?? TerminalMetalView(frame: .zero))
        coordinator.bind(canvas)
        return canvas
    }

    @MainActor fileprivate final class Coordinator: ObservableObject {
        private enum Phase: Equatable {
            case initial, connecting, reconnecting, live, displaced, exited
        }
        private weak var canvas: CanvasView?
        private var metalView: TerminalMetalView? { canvas?.terminal }
        #if os(iOS)
        /// A navigation bar over the view takes the scheme of the background it draws, so its title stays readable.
        @Published private(set) var barScheme: ColorScheme?
        #endif
        private var view: TerminalView?
        private var active = false
        private var reportedFocus = false
        private var isPresented = false
        private var drawingVisible = false
        private var epoch: UInt64 = 0
        private var shellRevision: UInt64 = 0
        private var output: OutputMailbox?
        private var reader: Task<Void, Never>?
        private var actions: Task<Void, Never>?
        private var spinnerDelay: Task<Void, Never>?
        private var announcedReconnect = false
        private var phase = Phase.initial {
            didSet {
                guard phase != oldValue else { return }
                if phase != .reconnecting { announcedReconnect = false }
                updateSpinner()
            }
        }
        private var hasScreen = false
        private var size: Terminal.Size?
        private var deliveredExit = false
        private var finishingExitStamp: UInt64?

        fileprivate func bind(_ canvas: CanvasView) {
            self.canvas = canvas
            canvas.onVisibility = { [weak self] in self?.updateActivity() }
            canvas.onCanvasChange = { [weak self] in
                // Layout reports the schemes, and SwiftUI can't observe a change during its own update.
                Task { @MainActor in
                    guard let self, let canvas = self.canvas else { return }
                    #if os(iOS)
                    self.barScheme = canvas.barScheme
                    #endif
                    if let scheme = canvas.canvasScheme { self.view?.probe.observe?(.canvas(scheme)) }
                }
            }
            canvas.terminal.onGridSizeChange = { [weak self] in self?.resize($0) }
            canvas.terminal.onThemeChange = { [weak self] theme in
                guard let self else { return }
                view?.probe.observe?(.theme(theme))
                perform { session, _ in await session.setTheme(theme) }
            }
            canvas.terminal.beforeOutputDraw = { [weak self] in self?.presentOutput() }
            canvas.terminal.onInput = { [weak self] in self?.input($0) }
            canvas.terminal.onInputFocusChange = { [weak self] in self?.updateFocus() }
        }

        fileprivate func apply(_ next: TerminalView) {
            let sessionChanged = view?.session !== next.session
            if sessionChanged {
                stop()
                phase = .initial
                hasScreen = false
                deliveredExit = false
                metalView?.setInputAvailability(.blocked, dismissKeyboard: false)
                metalView?.reset()
            }
            view = next
            guard let metalView else { return }
            let previousTheme = metalView.resolvedTheme
            if metalView.theme != next.theme { metalView.theme = next.theme }
            if sessionChanged && previousTheme == metalView.resolvedTheme { next.probe.observe?(.theme(metalView.resolvedTheme)) }
            if metalView.fontSize != next.fontSize { metalView.fontSize = next.fontSize }
            #if os(iOS)
            metalView.showsKeyRow = next.showsKeyRow
            #endif
            updateActivity()
        }

        fileprivate func setPresented(_ value: Bool) {
            isPresented = value
            updateActivity()
        }

        private func updateActivity() {
            guard let view, let canvas else { return }
            let shouldShow = isPresented && view.isActive && (canvas.isShellPresented || view.probe.assumesVisible)
            guard shouldShow else {
                if active { stop() }
                return
            }
            let visible = canvas.isDrawingVisible || view.probe.assumesVisible
            if drawingVisible != visible {
                drawingVisible = visible
                metalView?.setDrawingVisible(visible)
                updateSpinner()
            }
            let starting = !active
            active = true
            // The session records focus before it opens, so its first DECSET 1004 reply is current.
            updateFocus()
            if starting, let measured = metalView?.gridSize { resize(measured) }
        }

        /// Programs that set mode 1004 hear whether keystrokes reach this view.
        private func updateFocus() {
            let focused = active && canvas?.hasKeyboardFocus == true
            guard focused != reportedFocus, let session = view?.session else { return }
            reportedFocus = focused
            // A detached or reconnecting shell hears the current focus from its replay instead.
            enqueue { try? await session.setFocused(focused) }
        }

        fileprivate func dismantle(_ surface: AnyObject) {
            guard canvas === surface else { return }
            stop()
            metalView?.beforeOutputDraw = nil
            metalView?.onInput = nil
            metalView?.onThemeChange = nil
            metalView?.onGridSizeChange = nil
            view = nil
            canvas = nil
        }

        private func stop() {
            presentOutput()
            output = nil
            epoch &+= 1
            reader?.cancel()
            reader = nil
            size = nil
            let previouslyActive = active
            active = false
            updateFocus()
            drawingVisible = false
            updateSpinner()
            metalView?.onDisplacedTap = nil
            metalView?.setInputAvailability(.blocked, dismissKeyboard: false)
            metalView?.setRenderingActive(false)
            if previouslyActive, let session = view?.session {
                enqueue { await session.hide() }
            }
        }

        /// Keep native actions ordered across actor hops and SwiftUI visibility changes. The
        /// event reader suspends separately, so waiting for output never holds up a keystroke.
        private func enqueue(_ body: @escaping @MainActor () async -> Void) {
            let previous = actions
            actions = Task {
                await previous?.value
                await body()
            }
        }

        private func perform(_ operation: @escaping @MainActor (TerminalSession, UInt64) async throws -> Void) {
            guard let session = view?.session else { return }
            let stamp = epoch
            enqueue { [weak self] in
                guard let self, epoch == stamp, active else { return }
                do { try await operation(session, stamp) }
                catch { await handleError(stamp: stamp) }
            }
        }

        private func resize(_ measured: Terminal.Size) {
            guard active, measured != size else { return }
            size = measured
            perform { [weak self] session, stamp in
                guard let self else { return }
                let screen = try await session.resize(to: measured, needsScreen: reader != nil && phase == .live)
                guard epoch == stamp else { return }
                if reader == nil {
                    await start(session, userInitiated: false, stamp: stamp)
                } else if phase == .live, let screen {
                    if let frame = output?.take() {
                        present(frame)
                        if frame.screen.generation >= screen.generation { return }
                    }
                    metalView?.display(screen)
                }
            }
        }

        private func input(_ input: Terminal.Input) {
            guard active else { return }
            if phase == .displaced {
                switch input {
                case .text, .paste, .key: reclaim()
                default: return
                }
            }
            guard phase == .live || phase == .reconnecting else { return }
            // A pointer position belongs to the screen that was under the pointer.
            if case .pointer = input, phase != .live { return }
            // A queued keystroke belongs to the shell that was on screen when it was typed.
            let revision = shellRevision
            perform { session, _ in try await session.send(input, forShell: revision) }
        }

        private func reclaim() {
            guard active, phase == .displaced else { return }
            phase = .reconnecting
            metalView?.onDisplacedTap = nil
            perform { [weak self] session, stamp in
                // Let the read that reported displacement finish before starting another.
                await self?.reader?.value
                await self?.start(session, userInitiated: true, stamp: stamp)
            }
        }

        private func start(_ session: TerminalSession, userInitiated: Bool, stamp: UInt64) async {
            guard epoch == stamp, active, reader == nil, let metalView else { return }
            let attachment = await session.show(userInitiated: userInitiated, theme: metalView.resolvedTheme,
                                                needsRetainedScreen: !hasScreen)
            guard epoch == stamp else { return }
            shellRevision = attachment.shellRevision
            if let retainedScreen = attachment.retainedScreen {
                metalView.replaceDisplayedSnapshot(retainedScreen, receivedAt: nil)
                hasScreen = true
            }
            if let status = attachment.status {
                await apply(status, stamp: stamp)
                return
            }
            phase = hasScreen ? .reconnecting : .connecting
            metalView.setInputAvailability(hasScreen ? .holdingKeys : .blocked, dismissKeyboard: false)

            let mailbox = OutputMailbox()
            output = mailbox
            // The producer keeps only the session actor and this attachment's mailbox while waiting.
            reader = Task { [weak self, actor = session.actor] in
                defer { if self?.epoch == stamp { self?.reader = nil } }
                do {
                    try await actor.readUpdates(into: mailbox) { [weak self] in
                        guard let self, epoch == stamp, output === mailbox else { return }
                        presentOutput(notification: true)
                    } deliver: { [weak self] update in
                        guard let self, epoch == stamp, output === mailbox else { return false }
                        presentOutput()
                        return await apply(update, stamp: stamp)
                    }
                } catch {
                    guard let self, !Task.isCancelled, epoch == stamp else { return }
                    presentOutput()
                    await handleError(stamp: stamp)
                }
            }
        }

        private func presentOutput(notification: Bool = false) {
            if let frame = output?.take(notification: notification) { present(frame) }
        }

        private func present(_ frame: OutputMailbox.Frame) {
            let firstReceipt = metalView?.displayOutput(frame)
            hasScreen = true
            if let receipt = firstReceipt { view?.probe.observe?(.output(generation: frame.screen.generation, receivedAt: receipt)) }
        }

        @discardableResult
        private func apply(_ update: TerminalSession.Update, stamp: UInt64) async -> Bool {
            switch update {
            case .fresh(let screen):
                metalView?.reset()
                metalView?.display(screen)
                hasScreen = true
                becomeLive()
                view?.probe.observe?(.ready(resumed: false))
            case .replaced(let screen, let revision):
                shellRevision = revision
                metalView?.cancelPendingInput()
                metalView?.replaceDisplayedSnapshot(screen, receivedAt: nil, archivingMainScreen: true)
                hasScreen = true
                becomeLive()
                view?.probe.observe?(.ready(resumed: false))
                metalView?.announce("New shell")
            case .awaitingReplay:
                view?.probe.observe?(.ready(resumed: true))
            case .screen(let screen):
                metalView?.replaceDisplayedSnapshot(screen, receivedAt: nil)
                hasScreen = true
                becomeLive()
            case .output(let screen, let time):
                metalView?.display(screen, receivedAt: time)
                hasScreen = true
                if let time { view?.probe.observe?(.output(generation: screen.generation, receivedAt: time)) }
            case .replay(let screen, let time):
                metalView?.replaceDisplayedSnapshot(screen, receivedAt: time)
                hasScreen = true
                if phase != .live { becomeLive() }
                if let time { view?.probe.observe?(.output(generation: screen.generation, receivedAt: time)) }
            case .reconnecting:
                phase = hasScreen ? .reconnecting : .connecting
                metalView?.setInputAvailability(hasScreen ? .holdingKeys : .blocked, dismissKeyboard: false)
            case .displaced:
                phase = .displaced
                metalView?.setInputAvailability(.holdingKeys, dismissKeyboard: false)
                metalView?.onDisplacedTap = { [weak self] in self?.reclaim() }
                return false
            case .ended(let final):
                await finishExit(final, stamp: stamp)
                return false
            }
            return true
        }

        private func handleError(stamp: UInt64) async {
            guard epoch == stamp, active, let status = await view?.session.statusAfterError() else { return }
            guard epoch == stamp, active else { return }
            await apply(status, stamp: stamp)
        }

        private func finishExit(_ final: Terminal.Snapshot, stamp: UInt64) async {
            guard epoch == stamp, active, !deliveredExit, finishingExitStamp != stamp else { return }
            finishingExitStamp = stamp
            let announceEnd = phase != .initial && phase != .exited
            phase = .exited
            metalView?.onDisplacedTap = nil
            defer { if finishingExitStamp == stamp { finishingExitStamp = nil } }
            // Present the final bytes at the pre-dismissal keyboard size, including synchronized output.
            metalView?.setInputAvailability(.blocked, dismissKeyboard: false)
            await metalView?.presentFinal(final)
            guard epoch == stamp, active, !deliveredExit else { return }
            deliveredExit = true
            hasScreen = true
            metalView?.setInputAvailability(.blocked, dismissKeyboard: true)
            if announceEnd { metalView?.announce("Shell ended") }
        }

        private func becomeLive() {
            phase = .live
            metalView?.setInputAvailability(.live, dismissKeyboard: false)
            metalView?.onDisplacedTap = nil
        }

        private func updateSpinner() {
            spinnerDelay?.cancel()
            spinnerDelay = nil
            guard drawingVisible, phase == .connecting || phase == .reconnecting else {
                metalView?.setWaiting(nil)
                return
            }
            // Most attachments finish before an indicator or announcement would be useful.
            spinnerDelay = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                // A transition can cancel the wait after the sleep ends but before this resumes.
                guard !Task.isCancelled, let self else { return }
                let reconnecting = phase == .reconnecting
                metalView?.setWaiting(reconnecting ? "Reconnecting" : "Connecting")
                if reconnecting, !announcedReconnect {
                    announcedReconnect = true
                    metalView?.announce("Reconnecting")
                }
            }
        }
    }
}

extension TerminalView {
    @MainActor fileprivate struct Representable {
        let view: TerminalView
        let coordinator: Coordinator
        func makeCoordinator() -> Coordinator { coordinator }
    }
}

#if os(macOS)
extension TerminalView.Representable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { view.makeCanvas(coordinator) }
    func updateNSView(_ canvas: NSView, context: Context) { coordinator.apply(view) }
    static func dismantleNSView(_ canvas: NSView, coordinator: TerminalView.Coordinator) { coordinator.dismantle(canvas) }
}
#else
extension TerminalView.Representable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PhoneCanvasController {
        PhoneCanvasController(view.makeCanvas(coordinator))
    }
    func updateUIViewController(_ controller: PhoneCanvasController, context: Context) { coordinator.apply(view) }
    static func dismantleUIViewController(_ controller: PhoneCanvasController, coordinator: TerminalView.Coordinator) {
        coordinator.dismantle(controller.view)
        controller.releaseHold()
    }
}
#endif
