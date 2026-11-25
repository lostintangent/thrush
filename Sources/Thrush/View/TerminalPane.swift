import QuartzCore
import SwiftUI
import ThrushCore

/// A terminal pane that shows its session while visible.
/// Keep the session in a model that outlives the pane's SwiftUI updates.
@MainActor public struct TerminalPane: View {
    private let session: TerminalSession
    /// Whether the app is showing the pane. Set this to false when hiding a retained tab.
    package var isActive: Bool
    /// Overrides the system's light or dark terminal theme. Pass `nil` to follow appearance changes.
    package var theme: TerminalTheme?
    /// The font size in points, from 6 through 96. The default is 14 on Mac and 13 on iPhone.
    package var fontSize: CGFloat?
    #if os(iOS)
    /// Whether Esc, Ctrl, Tab and the arrow keys sit above the iPhone software keyboard.
    package var showsKeyRow = true
    #endif

    /// Creates a pane for a session, using the system appearance unless a theme is supplied.
    /// The pane shows the session and, on iPhone, the key row above the keyboard.
    ///
    /// - Parameters:
    ///   - session: The session whose output and input the pane presents.
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
    /// Creates a pane that shows or hides the key row of Esc, Ctrl, Tab and arrow keys
    /// above the iPhone software keyboard. The row is shown by default.
    public init(_ session: TerminalSession, isActive: Bool = true, theme: TerminalTheme? = nil,
                fontSize: CGFloat? = nil, showsKeyRow: Bool) {
        self.init(session, isActive: isActive, theme: theme, fontSize: fontSize)
        self.showsKeyRow = showsKeyRow
    }
    #endif

    // Only the standalone demo and its instrumentation need direct observation of the native surface.
    package var preparedView: TerminalView?
    package var assumesVisibleForBenchmark = false
    package var onOutput: ((UInt64, CFTimeInterval) -> Void)?
    package var onReady: ((Bool) -> Void)?
    package var onResolvedTheme: ((TerminalTheme) -> Void)?
    package var onCanvasChange: ((ColorScheme) -> Void)?
    package var onWriteStarted: (@Sendable (CFTimeInterval) -> Void)?

    /// The terminal surface and its session status notices.
    public var body: some View { Presentation(pane: self) }

    // SwiftUI may retain a tab or navigation destination's native view while it is offscreen.
    // Combine its appearance callbacks with actual window/scene visibility.
    @MainActor private struct Presentation: View {
        let pane: TerminalPane
        @StateObject private var coordinator = Coordinator()

        var body: some View {
            NativePane(pane: pane, owner: coordinator)
                .onAppear { coordinator.setPresented(true) }
                .onDisappear { coordinator.setPresented(false) }
                #if os(iOS)
                .toolbarColorScheme(coordinator.barScheme, for: .navigationBar)
                #endif
        }
    }

    fileprivate func makeContainer(_ coordinator: Coordinator) -> TerminalPaneContainer {
        let container = TerminalPaneContainer(terminal: preparedView ?? TerminalView(frame: .zero))
        coordinator.bind(container)
        return container
    }

    @MainActor fileprivate final class Coordinator: ObservableObject {
        private enum Phase: Equatable {
            case initial, connecting, reconnecting, live, displaced, exited
        }
        private weak var container: TerminalPaneContainer?
        private var view: TerminalView? { container?.terminal }
        #if os(iOS)
        /// A navigation bar over the pane takes the scheme of the background it draws, so its title stays readable.
        @Published private(set) var barScheme: ColorScheme?
        #endif
        private var pane: TerminalPane?
        private var active = false
        private var reportedFocus = false
        private var isPresented = false
        private var drawingVisible = false
        private var epoch: UInt64 = 0
        private var reader: Task<Void, Never>?
        private var actions: Task<Void, Never>?
        private var noticeTimer: Task<Void, Never>?
        private var phase = Phase.initial
        private var hasScreen = false
        private var size: Terminal.Size?
        private var scheduledNotice: PaneNotice?
        private var notice: PaneNotice?
        private var readingNotice = false
        private var replacementSawInput = false
        private var replacement: PaneNotice?
        private var replacementRemaining = Duration.zero
        private var replacementVisibleSince: ContinuousClock.Instant?
        private var replacementTimer: Task<Void, Never>?
        private var deliveredExit = false
        private var finishingExitStamp: UInt64?

        fileprivate func bind(_ container: TerminalPaneContainer) {
            self.container = container
            container.onVisibility = { [weak self] in self?.updateActivity() }
            container.onAction = { [weak self] in self?.activateButton() }
            container.onCanvasChange = { [weak self] in
                // Layout reports the schemes, and SwiftUI can't observe a change during its own update.
                Task { @MainActor in
                    guard let self, let container = self.container else { return }
                    #if os(iOS)
                    self.barScheme = container.barScheme
                    #endif
                    if let canvas = container.canvasScheme { self.pane?.onCanvasChange?(canvas) }
                }
            }
            container.onNoticeReadChange = { [weak self] reading in
                self?.readingNotice = reading
                self?.dismissReplacementIfReady()
            }
            container.terminal.onGridSizeChange = { [weak self] in self?.resize($0) }
            container.terminal.onThemeChange = { [weak self] theme in
                guard let self else { return }
                pane?.onResolvedTheme?(theme)
                self.container?.show(notice)
                perform { session, _ in await session.setTheme(theme) }
            }
            container.terminal.onInput = { [weak self] in self?.input($0) }
            container.terminal.onInputFocusChange = { [weak self] in self?.updateFocus() }
        }

        fileprivate func apply(_ next: TerminalPane) {
            let sessionChanged = pane?.session !== next.session
            if sessionChanged {
                stop()
                phase = .initial
                hasScreen = false
                deliveredExit = false
                clearReplacement()
                view?.setInputAvailability(.blocked, dismissKeyboard: false)
                view?.reset()
                show(nil)
            }
            pane = next
            guard let view else { return }
            let previousTheme = view.resolvedTheme
            if view.theme != next.theme { view.theme = next.theme }
            if sessionChanged && previousTheme == view.resolvedTheme { next.onResolvedTheme?(view.resolvedTheme) }
            if view.fontSize != next.fontSize { view.fontSize = next.fontSize }
            #if os(iOS)
            view.showsKeyRow = next.showsKeyRow
            #endif
            updateActivity()
        }

        fileprivate func setPresented(_ value: Bool) {
            isPresented = value
            updateActivity()
        }

        private func updateActivity() {
            guard let pane, let container else { return }
            let shouldShow = isPresented && pane.isActive && (container.isShellPresented || pane.assumesVisibleForBenchmark)
            guard shouldShow else {
                if active { stop() }
                return
            }
            let visible = container.isDrawingVisible || pane.assumesVisibleForBenchmark
            if drawingVisible != visible {
                drawingVisible = visible
                view?.setDrawingVisible(visible)
                if visible { resumeReplacementTimer() } else { pauseReplacementTimer() }
            }
            let starting = !active
            active = true
            // The session records focus before it opens, so its first DECSET 1004 reply is current.
            updateFocus()
            if starting, let measured = view?.gridSize { resize(measured) }
        }

        /// Programs that set mode 1004 hear whether keystrokes reach this pane.
        private func updateFocus() {
            let focused = active && container?.hasKeyboardFocus == true
            guard focused != reportedFocus, let session = pane?.session else { return }
            reportedFocus = focused
            // A detached or reconnecting shell hears the current focus from its replay instead.
            enqueue { try? await session.setFocused(focused) }
        }

        fileprivate func dismantle(_ surface: AnyObject) {
            guard container === surface else { return }
            stop()
            view?.onInput = nil
            view?.onThemeChange = nil
            view?.onGridSizeChange = nil
            pane = nil
            container = nil
        }

        private func stop() {
            epoch &+= 1
            reader?.cancel()
            reader = nil
            noticeTimer?.cancel()
            noticeTimer = nil
            scheduledNotice = nil
            size = nil
            pauseReplacementTimer()
            let previouslyActive = active
            active = false
            updateFocus()
            drawingVisible = false
            view?.setInputAvailability(.blocked, dismissKeyboard: false)
            view?.setRenderingActive(false)
            if previouslyActive, let session = pane?.session {
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
            guard let session = pane?.session else { return }
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
                if reader == nil, phase != .displaced, phase != .exited {
                    await start(session, userInitiated: false, stamp: stamp)
                } else if phase == .live, let screen {
                    view?.display(screen)
                }
            }
        }

        private func input(_ input: Terminal.Input) {
            guard active, phase == .live || phase == .reconnecting else { return }
            // Pointer coordinates describe the currently displayed generation. Only committed
            // text, paste and keys are meaningful for an attachment that may be restored.
            if case .pointer = input, phase == .reconnecting { return }
            let onWrite = pane?.onWriteStarted
            perform { session, _ in
                if let onWrite { try await session.send(input) { onWrite(CACurrentMediaTime()) } }
                else { try await session.send(input) }
            }
            if case .replacement = notice, case .pointer = input { return }
            if case .replacement = notice {
                replacementSawInput = true
                dismissReplacementIfReady()
            }
        }

        private func activateButton() {
            guard active, phase == .displaced || phase == .exited else { return }
            phase = .connecting
            delay(.connecting(retainingTranscript: hasScreen))
            perform { [weak self] session, stamp in
                await self?.start(session, userInitiated: true, stamp: stamp)
            }
        }

        private func start(_ session: TerminalSession, userInitiated: Bool, stamp: UInt64) async {
            guard epoch == stamp, active, reader == nil, let view else { return }
            let (retainedScreen, status) = await session.show(userInitiated: userInitiated, theme: view.resolvedTheme,
                                                              needsRetainedScreen: !hasScreen)
            guard epoch == stamp else { return }
            if let retainedScreen {
                view.replaceDisplayedSnapshot(retainedScreen, receivedAt: nil)
                hasScreen = true
            }
            if let status {
                await apply(status, stamp: stamp)
                return
            }
            phase = .connecting
            view.setInputAvailability(.blocked, dismissKeyboard: false)
            delay(.connecting(retainingTranscript: hasScreen))

            // Only the read operation survives the wait. The app can release the pane and its session.
            reader = Task { [weak self, read = session.readUpdate] in
                defer { if self?.epoch == stamp { self?.reader = nil } }
                do {
                    while !Task.isCancelled, self?.epoch == stamp {
                        let update = try await read()
                        guard !Task.isCancelled, self?.epoch == stamp else { return }
                        guard await self?.apply(update, stamp: stamp) == true else { return }
                    }
                } catch {
                    if !Task.isCancelled { await self?.handleError(stamp: stamp) }
                }
            }
        }

        @discardableResult
        private func apply(_ update: TerminalSession.Update, stamp: UInt64) async -> Bool {
            switch update {
            case .fresh(let screen):
                openedShell(screen)
            case .replacedShell(let screen, let discardedInput):
                openedShell(screen, discardedOnReplacement: discardedInput)
            case .awaitingReplay:
                pane?.onReady?(true)
            case .screen(let screen):
                view?.replaceDisplayedSnapshot(screen, receivedAt: nil)
                hasScreen = true
                becomeLive()
            case .output(let screen, let time):
                view?.display(screen, receivedAt: time)
                hasScreen = true
                if let time { pane?.onOutput?(screen.generation, time) }
            case .replay(let screen, let time):
                view?.replaceDisplayedSnapshot(screen, receivedAt: time)
                hasScreen = true
                if phase != .live { becomeLive() }
                if let time { pane?.onOutput?(screen.generation, time) }
            case .reconnecting:
                phase = .reconnecting
                view?.setInputAvailability(hasScreen ? .holdingKeys : .blocked, dismissKeyboard: false)
                delay(hasScreen ? .reconnecting : .connecting(retainingTranscript: false))
            case .displaced:
                blockInput(.displaced)
                return false
            case .ended(let final, let canRestart):
                await finishExit(final, canRestart: canRestart, stamp: stamp)
                return false
            }
            return true
        }

        private func openedShell(_ screen: Terminal.Snapshot, discardedOnReplacement: Bool? = nil) {
            deliveredExit = false
            clearReplacement()
            view?.reset()
            view?.display(screen)
            becomeLive()
            if let discardedOnReplacement { announceReplacement(discarded: discardedOnReplacement) }
            pane?.onReady?(false)
        }

        private func handleError(stamp: UInt64) async {
            guard epoch == stamp, active, let status = await pane?.session.statusAfterError() else { return }
            guard epoch == stamp, active else { return }
            await apply(status, stamp: stamp)
        }

        private func finishExit(_ final: Terminal.Snapshot, canRestart: Bool, stamp: UInt64) async {
            guard epoch == stamp, active, !deliveredExit, finishingExitStamp != stamp else { return }
            finishingExitStamp = stamp
            defer { if finishingExitStamp == stamp { finishingExitStamp = nil } }
            // Present the final bytes at the pre-dismissal keyboard size, including synchronized output.
            view?.setInputAvailability(.blocked, dismissKeyboard: false)
            await view?.presentFinal(final)
            guard epoch == stamp, active, !deliveredExit else { return }
            deliveredExit = true
            hasScreen = true
            blockInput(.exited, notice: canRestart ? .exited : .closed)
        }

        private func becomeLive() {
            phase = .live
            view?.setInputAvailability(.live, dismissKeyboard: false)
            show(replacement)
        }

        private func blockInput(_ state: Phase, notice: PaneNotice? = nil) {
            phase = state
            clearReplacement()
            view?.setInputAvailability(.blocked, dismissKeyboard: true)
            show(notice ?? (state == .displaced ? .displaced : .exited))
        }

        private func show(_ next: PaneNotice?) {
            noticeTimer?.cancel()
            noticeTimer = nil
            scheduledNotice = nil
            if notice != next { pauseReplacementTimer() }
            notice = next
            container?.show(next)
            resumeReplacementTimer()
        }

        private func delay(_ next: PaneNotice) {
            if notice == next || scheduledNotice == next { return }
            show(nil)
            scheduledNotice = next
            noticeTimer = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                self?.show(next)
            }
        }

        private func announceReplacement(discarded: Bool) {
            clearReplacement()
            replacement = .replacement(discardedInput: discarded)
            replacementRemaining = .seconds(3)
            show(replacement)
        }

        private func clearReplacement() {
            pauseReplacementTimer()
            replacementSawInput = false
            replacement = nil
        }

        private func pauseReplacementTimer() {
            if let since = replacementVisibleSince {
                replacementRemaining = max(.zero, replacementRemaining - since.duration(to: .now))
            }
            replacementVisibleSince = nil
            replacementTimer?.cancel()
            replacementTimer = nil
        }

        private func resumeReplacementTimer() {
            guard drawingVisible, let replacement, notice == replacement, replacementRemaining > .zero,
                  replacementVisibleSince == nil else { return }
            replacementVisibleSince = .now
            let remaining = replacementRemaining
            replacementTimer = Task { [weak self] in
                do { try await Task.sleep(for: remaining) } catch { return }
                self?.replacementVisibleSince = nil
                self?.replacementRemaining = .zero
                self?.dismissReplacementIfReady()
            }
        }

        private func dismissReplacementIfReady() {
            if let replacement, notice == replacement, replacementRemaining == .zero, replacementSawInput, !readingNotice {
                clearReplacement()
                show(nil)
            }
        }
    }
}

@MainActor private struct NativePane {
    let pane: TerminalPane
    let owner: TerminalPane.Coordinator
    func makeCoordinator() -> TerminalPane.Coordinator { owner }
}

#if os(macOS)
extension NativePane: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { pane.makeContainer(owner) }
    func updateNSView(_ view: NSView, context: Context) { owner.apply(pane) }
    static func dismantleNSView(_ view: NSView, coordinator: TerminalPane.Coordinator) { coordinator.dismantle(view) }
}
#else
extension NativePane: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PhonePaneController {
        PhonePaneController(pane.makeContainer(owner))
    }
    func updateUIViewController(_ controller: PhonePaneController, context: Context) { owner.apply(pane) }
    static func dismantleUIViewController(_ controller: PhonePaneController, coordinator: TerminalPane.Coordinator) {
        coordinator.dismantle(controller.view)
        controller.finishRotation()
    }
}
#endif
