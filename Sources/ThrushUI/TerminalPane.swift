import QuartzCore
import SwiftUI
import Thrush
import ThrushConnection

/// One shell tab. Keep its connection for the tab's lifetime and pass it to this view.
@MainActor public struct TerminalPane: View {
    public let connection: TerminalConnection
    public var isActive: Bool
    public var theme: TerminalTheme?
    public var fontSize: CGFloat?
    public var onExit: (() -> Void)?
    #if os(iOS)
    public var keyboardAccessory: TerminalKeyboardAccessory = .standard
    #endif

    /// Uses the system appearance, native lifecycle and standard iPhone terminal keys.
    /// Pass isActive when the host hides this tab without removing it from the hierarchy.
    public init(_ connection: TerminalConnection, isActive: Bool = true, theme: TerminalTheme? = nil,
                fontSize: CGFloat? = nil, onExit: (() -> Void)? = nil) {
        self.connection = connection
        self.isActive = isActive
        self.theme = theme
        self.fontSize = fontSize
        self.onExit = onExit
    }

    #if os(iOS)
    /// Supply an alternative native accessory for this pane.
    public init(_ connection: TerminalConnection, isActive: Bool = true, theme: TerminalTheme? = nil,
                fontSize: CGFloat? = nil, keyboardAccessory: TerminalKeyboardAccessory, onExit: (() -> Void)? = nil) {
        self.init(connection, isActive: isActive, theme: theme, fontSize: fontSize, onExit: onExit)
        self.keyboardAccessory = keyboardAccessory
    }
    #endif

    // Only the standalone demo and its instrumentation need direct observation of the native surface.
    package var preparedView: TerminalView?
    package var assumesVisibleForBenchmark = false
    package var onOutput: ((UInt64, CFTimeInterval) -> Void)?
    package var onReady: ((Bool) -> Void)?
    package var onResolvedTheme: ((TerminalTheme) -> Void)?
    package var onWriteStarted: (@Sendable (CFTimeInterval) -> Void)?

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
        private var nativeVisible = false
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
            nativeVisible = container.visibleAndActive
            container.onVisibility = { [weak self] visible in
                self?.nativeVisible = visible
                self?.updateActivity()
            }
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
                perform { connection, _ in await connection.setPalette(theme.palette) }
            }
            container.terminal.onInput = { [weak self] in self?.input($0) }
        }

        fileprivate func apply(_ next: TerminalPane) {
            if pane?.connection !== next.connection {
                stop()
                phase = .initial
                hasTranscript = false
                deliveredExit = false
                clearReplacement()
                view?.setInputAvailability(acceptsKeys: false, showsCursor: false, dismissKeyboard: false)
                view?.reset()
                show(nil)
            }
            pane = next
            guard let view else { return }
            if view.theme != next.theme { view.theme = next.theme }
            if view.fontSize != next.fontSize { view.fontSize = next.fontSize }
            #if os(iOS)
            if view.keyboardAccessory != next.keyboardAccessory { view.keyboardAccessory = next.keyboardAccessory }
            #endif
            updateActivity()
        }

        fileprivate func setPresented(_ value: Bool) {
            isPresented = value
            updateActivity()
        }

        private func updateActivity() {
            guard let pane, container != nil else { return }
            let next = isPresented && pane.isActive && (nativeVisible || pane.assumesVisibleForBenchmark)
            guard active != next else { return }
            if next {
                active = true
                view?.setRenderingActive(true)
                if let measured = view?.gridSize { resize(measured) }
            } else {
                stop()
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
            view?.setInputAvailability(acceptsKeys: false, showsCursor: false, dismissKeyboard: false)
            view?.setRenderingActive(false)
            if previouslyActive, let connection = pane?.connection {
                enqueue { await connection.detach() }
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

        private func perform(_ operation: @escaping @MainActor (TerminalConnection, UInt64) async throws -> Void) {
            guard let connection = pane?.connection else { return }
            let stamp = epoch
            enqueue { [weak self] in
                guard let self, epoch == stamp, active else { return }
                do { try await operation(connection, stamp) }
                catch { await handleError(from: connection, stamp: stamp) }
            }
        }

        private func resize(_ measured: Terminal.Size) {
            guard active, measured != size else { return }
            size = measured
            perform { [weak self] connection, stamp in
                try await connection.sendResize(to: measured)
                guard let self, epoch == stamp else { return }
                if reader == nil, phase != .displaced, phase != .exited {
                    try await start(connection, userInitiated: false, stamp: stamp)
                } else if phase == .live, !awaitingReplay {
                    let snapshot = await connection.snapshot()
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
            perform { connection, _ in
                if let onWrite { try await connection.send(input) { onWrite(CACurrentMediaTime()) } }
                else { try await connection.send(input) }
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
            perform { [weak self] connection, stamp in
                try await self?.start(connection, userInitiated: true, stamp: stamp)
            }
        }

        private func start(_ connection: TerminalConnection, userInitiated: Bool, stamp: UInt64) async throws {
            guard epoch == stamp, active, reader == nil, let view else { return }
            await connection.setPalette(view.resolvedTheme.palette)
            guard epoch == stamp else { return }
            if !hasTranscript, await connection.hasSeenReady {
                let retained = await connection.snapshot()
                guard epoch == stamp else { return }
                view.replaceDisplayedSnapshot(retained, receivedAt: nil)
                hasTranscript = true
            }
            _ = await connection.attach(userInitiated: userInitiated)
            let state = await connection.state
            guard epoch == stamp else { return }
            switch state {
            case .displaced: blockInput(.displaced)
            case .ended: await finishExit(connection, stamp: stamp)
            default:
                phase = .connecting
                view.setInputAvailability(acceptsKeys: false, showsCursor: false, dismissKeyboard: false)
                delay(.connecting(retainingTranscript: hasTranscript))
                reader = Task { [weak self] in await self?.consume(connection, stamp: stamp) }
            }
        }

        private func consume(_ connection: TerminalConnection, stamp: UInt64) async {
            defer { if epoch == stamp { reader = nil } }
            do {
                while !Task.isCancelled, epoch == stamp {
                    let event = try await connection.nextEvent()
                    guard epoch == stamp, !Task.isCancelled else { return }
                    switch event {
                    case .ready(let resumed):
                        if resumed {
                            awaitingReplay = true
                        } else {
                            let replacement = await connection.replacedPreviousShell
                            let discarded = await connection.discardedHeldInputOnLastReady
                            guard epoch == stamp else { return }
                            deliveredExit = false
                            clearReplacement()
                            view?.reset()
                            let snapshot = await connection.snapshot()
                            guard epoch == stamp else { return }
                            view?.display(snapshot)
                            becomeLive()
                            if replacement { announceReplacement(discarded: discarded) }
                        }
                        pane?.onReady?(resumed)
                    case .output, .resynchronized:
                        let time = await connection.lastReceiptTime
                        let snapshot = await connection.snapshot()
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
                        view?.setInputAvailability(acceptsKeys: hasTranscript, showsCursor: false, dismissKeyboard: false)
                        delay(hasTranscript ? .reconnecting : .connecting(retainingTranscript: false))
                    case .displaced:
                        blockInput(.displaced)
                        return
                    case .exit:
                        // A final PTY write may still be inside synchronized output. Flush it
                        // before the native notice changes what a reader sees.
                        await finishExit(connection, stamp: stamp)
                        return
                    }
                }
            } catch {
                guard epoch == stamp, !Task.isCancelled else { return }
                await handleError(from: connection, stamp: stamp)
            }
        }

        private func handleError(from connection: TerminalConnection, stamp: UInt64) async {
            let state = await connection.state
            guard epoch == stamp, active else { return }
            switch state {
            case .displaced: blockInput(.displaced)
            case .ended: await finishExit(connection, stamp: stamp)
            case .reconnecting, .connecting, .replaying:
                phase = .reconnecting
                view?.setInputAvailability(acceptsKeys: hasTranscript, showsCursor: false, dismissKeyboard: false)
                delay(hasTranscript ? .reconnecting : .connecting(retainingTranscript: false))
            case .detached, .closing, .active: break
            }
        }

        private func finishExit(_ connection: TerminalConnection, stamp: UInt64) async {
            guard epoch == stamp, !deliveredExit, finishingExitStamp != stamp else { return }
            finishingExitStamp = stamp
            defer { if finishingExitStamp == stamp { finishingExitStamp = nil } }
            let final = await connection.snapshot()
            let natural = await connection.exitedNaturally
            guard epoch == stamp, active else { return }
            // Prevent new commits while keeping the final frame at its pre-dismissal keyboard size.
            view?.setInputAvailability(acceptsKeys: false, showsCursor: false, dismissKeyboard: false)
            await view?.presentFinal(final)
            guard epoch == stamp, active, !deliveredExit else { return }
            deliveredExit = true
            hasTranscript = true
            blockInput(.exited, notice: natural ? .exited : .closed)
            pane?.onExit?()
        }

        private func becomeLive() {
            phase = .live
            view?.setInputAvailability(acceptsKeys: true, showsCursor: true, dismissKeyboard: false)
            show(replacement)
        }

        private func blockInput(_ state: Phase, notice: PaneNotice? = nil) {
            phase = state
            clearReplacement()
            view?.setInputAvailability(acceptsKeys: false, showsCursor: false, dismissKeyboard: true)
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
            guard active, let replacement, notice == replacement, replacementRemaining > .zero,
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
