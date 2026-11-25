import QuartzCore
import SwiftUI
import ThrushCore

/// A terminal pane that attaches its session while visible.
/// Keep the session in a model that outlives the pane's SwiftUI updates.
@MainActor public struct TerminalPane: View {
    private let session: TerminalSession
    private var worker: TerminalWorker { session.worker }
    /// Whether the host is showing the pane. Set this to false when hiding a retained tab.
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
    /// The pane manages attachment and, on iPhone, shows the key row above the keyboard.
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
        private var pane: TerminalPane?
        private var active = false
        private var isPresented = false
        private var drawingVisible = false
        private var epoch: UInt64 = 0
        private var reader: Task<Void, Never>?
        private var actions: Task<Void, Never>?
        private var noticeTimer: Task<Void, Never>?
        private var phase = Phase.initial
        private var hasTranscript = false
        private var awaitingReplay = false
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
            container.onNoticeReadChange = { [weak self] reading in
                self?.readingNotice = reading
                self?.dismissReplacementIfReady()
            }
            container.terminal.onGridSizeChange = { [weak self] in self?.resize($0) }
            container.terminal.onThemeChange = { [weak self] theme in
                guard let self else { return }
                pane?.onResolvedTheme?(theme)
                self.container?.show(notice)
                perform { worker, _ in await worker.setPalette(theme.palette, cursor: theme.cursor) }
            }
            container.terminal.onInput = { [weak self] in self?.input($0) }
        }

        fileprivate func apply(_ next: TerminalPane) {
            let workerChanged = pane?.worker !== next.worker
            if workerChanged {
                stop()
                phase = .initial
                hasTranscript = false
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
            if workerChanged && previousTheme == view.resolvedTheme { next.onResolvedTheme?(view.resolvedTheme) }
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
            let shouldAttach = isPresented && pane.isActive && (container.isShellPresented || pane.assumesVisibleForBenchmark)
            guard shouldAttach else {
                if active { stop() }
                return
            }
            let visible = container.isDrawingVisible || pane.assumesVisibleForBenchmark
            if drawingVisible != visible {
                drawingVisible = visible
                view?.setDrawingVisible(visible)
                if visible { resumeReplacementTimer() } else { pauseReplacementTimer() }
            }
            if !active {
                active = true
                if let measured = view?.gridSize { resize(measured) }
            }
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
            awaitingReplay = false
            pauseReplacementTimer()
            let previouslyActive = active
            active = false
            drawingVisible = false
            view?.setInputAvailability(.blocked, dismissKeyboard: false)
            view?.setRenderingActive(false)
            if previouslyActive, let worker = pane?.worker {
                enqueue { await worker.detach() }
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

        private func perform(_ operation: @escaping @MainActor (TerminalWorker, UInt64) async throws -> Void) {
            guard let worker = pane?.worker else { return }
            let stamp = epoch
            enqueue { [weak self] in
                guard let self, epoch == stamp, active else { return }
                do { try await operation(worker, stamp) }
                catch { await handleError(from: worker, stamp: stamp) }
            }
        }

        private func resize(_ measured: Terminal.Size) {
            guard active, measured != size else { return }
            size = measured
            perform { [weak self] worker, stamp in
                try await worker.sendResize(to: measured)
                guard let self, epoch == stamp else { return }
                if reader == nil, phase != .displaced, phase != .exited {
                    try await start(worker, userInitiated: false, stamp: stamp)
                } else if phase == .live, !awaitingReplay {
                    let snapshot = await worker.snapshot()
                    if epoch == stamp { view?.display(snapshot) }
                }
            }
        }

        private func input(_ input: Terminal.Input) {
            guard active, phase == .live || phase == .reconnecting else { return }
            // Pointer coordinates describe the currently displayed generation. Only committed
            // text, paste and keys are meaningful for an attachment that may be restored.
            if case .pointer = input, phase == .reconnecting { return }
            let onWrite = pane?.onWriteStarted
            perform { worker, _ in
                if let onWrite { try await worker.send(input) { onWrite(CACurrentMediaTime()) } }
                else { try await worker.send(input) }
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
            delay(.connecting(retainingTranscript: hasTranscript))
            perform { [weak self] worker, stamp in
                try await self?.start(worker, userInitiated: true, stamp: stamp)
            }
        }

        private func start(_ worker: TerminalWorker, userInitiated: Bool, stamp: UInt64) async throws {
            guard epoch == stamp, active, reader == nil, let view else { return }
            let theme = view.resolvedTheme
            await worker.setPalette(theme.palette, cursor: theme.cursor)
            guard epoch == stamp else { return }
            if !hasTranscript, await worker.hasSeenReady {
                let retained = await worker.snapshot()
                guard epoch == stamp else { return }
                view.replaceDisplayedSnapshot(retained, receivedAt: nil)
                hasTranscript = true
            }
            _ = await worker.attach(userInitiated: userInitiated)
            let state = await worker.state
            guard epoch == stamp else { return }
            switch state {
            case .displaced: blockInput(.displaced)
            case .ended: await finishExit(worker, stamp: stamp)
            default:
                phase = .connecting
                view.setInputAvailability(.blocked, dismissKeyboard: false)
                delay(.connecting(retainingTranscript: hasTranscript))
                reader = Task { [weak self] in await self?.consume(worker, stamp: stamp) }
            }
        }

        private func consume(_ worker: TerminalWorker, stamp: UInt64) async {
            defer { if epoch == stamp { reader = nil } }
            do {
                while !Task.isCancelled, epoch == stamp {
                    let event = try await worker.nextEvent()
                    guard epoch == stamp, !Task.isCancelled else { return }
                    switch event {
                    case .ready(let resumed):
                        if resumed {
                            awaitingReplay = true
                        } else {
                            let replacement = await worker.replacedPreviousShell
                            let discarded = await worker.discardedHeldInputOnLastReady
                            guard epoch == stamp else { return }
                            deliveredExit = false
                            clearReplacement()
                            view?.reset()
                            let snapshot = await worker.snapshot()
                            guard epoch == stamp else { return }
                            view?.display(snapshot)
                            becomeLive()
                            if replacement { announceReplacement(discarded: discarded) }
                        }
                        pane?.onReady?(resumed)
                    case .output, .resynchronized:
                        let time = await worker.lastReceiptTime
                        let snapshot = await worker.snapshot()
                        guard epoch == stamp else { return }
                        if event == .resynchronized || awaitingReplay {
                            view?.replaceDisplayedSnapshot(snapshot, receivedAt: time)
                            if awaitingReplay { becomeLive() }
                            awaitingReplay = false
                        } else {
                            view?.display(snapshot, receivedAt: time)
                        }
                        hasTranscript = true
                        if let time { pane?.onOutput?(snapshot.generation, time) }
                    case .reconnecting:
                        awaitingReplay = false
                        phase = .reconnecting
                        view?.setInputAvailability(hasTranscript ? .holdingKeys : .blocked, dismissKeyboard: false)
                        delay(hasTranscript ? .reconnecting : .connecting(retainingTranscript: false))
                    case .displaced:
                        blockInput(.displaced)
                        return
                    case .exit:
                        // A final PTY write may still be inside synchronized output. Flush it
                        // before the native notice changes what a reader sees.
                        await finishExit(worker, stamp: stamp)
                        return
                    }
                }
            } catch {
                guard epoch == stamp, !Task.isCancelled else { return }
                await handleError(from: worker, stamp: stamp)
            }
        }

        private func handleError(from worker: TerminalWorker, stamp: UInt64) async {
            let state = await worker.state
            guard epoch == stamp, active else { return }
            switch state {
            case .displaced: blockInput(.displaced)
            case .ended: await finishExit(worker, stamp: stamp)
            case .reconnecting, .connecting, .replaying:
                phase = .reconnecting
                view?.setInputAvailability(hasTranscript ? .holdingKeys : .blocked, dismissKeyboard: false)
                delay(hasTranscript ? .reconnecting : .connecting(retainingTranscript: false))
            case .detached, .closing, .active: break
            }
        }

        private func finishExit(_ worker: TerminalWorker, stamp: UInt64) async {
            guard epoch == stamp, !deliveredExit, finishingExitStamp != stamp else { return }
            finishingExitStamp = stamp
            defer { if finishingExitStamp == stamp { finishingExitStamp = nil } }
            let final = await worker.snapshot()
            let natural = await worker.exitedNaturally
            guard epoch == stamp, active else { return }
            // Prevent new commits while keeping the final frame at its pre-dismissal keyboard size.
            view?.setInputAvailability(.blocked, dismissKeyboard: false)
            await view?.presentFinal(final)
            guard epoch == stamp, active, !deliveredExit else { return }
            deliveredExit = true
            hasTranscript = true
            blockInput(.exited, notice: natural ? .exited : .closed)
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
extension NativePane: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { pane.makeContainer(owner) }
    func updateUIView(_ view: UIView, context: Context) { owner.apply(pane) }
    static func dismantleUIView(_ view: UIView, coordinator: TerminalPane.Coordinator) { coordinator.dismantle(view) }
}
#endif
