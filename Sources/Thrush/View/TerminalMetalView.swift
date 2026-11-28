import MetalKit
import ThrushCore

/// Timing from the monotonic media clock used by CAMetalDrawable.presentedTime.
package struct FrameMeasurement: Sendable, Encodable {
    package let generation: UInt64
    package internal(set) var gpuCompleted = false
    package let cpuPreparationSeconds: Double
    package let shaderCompileSeconds: Double?
    package let firstFrameSeconds: Double?
    package internal(set) var gpuSeconds: Double?
    package internal(set) var presentedTime: Double?
    package let receivedAt: Double?
    package let submittedAt: Double
    package let glyphUploads: Int
    package let rowsPrepared: Int
}

/// Collects one frame's timing until its GPU work and its presentation are both known, then reports the measurement.
@MainActor
private final class FrameTiming {
    var frame: FrameMeasurement
    let report: (FrameMeasurement) -> Void
    var completed = false
    var presentationKnown = false
    var delivered = false

    init(_ frame: FrameMeasurement, report: @escaping (FrameMeasurement) -> Void) {
        self.frame = frame
        self.report = report
    }

    func resolve() {
        guard completed, presentationKnown, !delivered else { return }
        delivered = true
        report(frame)
    }
}

/// The Metal view inside a terminal view. It draws the viewport's terminal snapshots
/// and forwards native input and geometry changes to the terminal view's coordinator.
@MainActor
package final class TerminalMetalView: MTKView, MTKViewDelegate {
    /// Two inclusive cell positions relative to the displayed viewport, with the origin at its top left.
    /// A selection may extend in either direction. Selecting either column of a wide glyph highlights the whole glyph.
    package struct Selection: Equatable, Sendable {
        /// The zero-based row where the selection began.
        package let anchorRow: Int
        /// The zero-based column where the selection began.
        package let anchorColumn: Int
        /// The zero-based row at the moving end of the selection.
        package let headRow: Int
        /// The zero-based column at the moving end of the selection.
        package let headColumn: Int

        /// Creates a selection from its starting cell through its current end cell, inclusive.
        package init(anchorRow: Int, anchorColumn: Int, headRow: Int, headColumn: Int) {
            self.anchorRow = anchorRow
            self.anchorColumn = anchorColumn
            self.headRow = headRow
            self.headColumn = headColumn
        }

        func columns(in row: Int, width: Int) -> Range<Int>? {
            var start = (anchorRow, anchorColumn), end = (headRow, headColumn)
            if end < start { swap(&start, &end) }
            guard (start.0...end.0).contains(row) else { return nil }
            let lo = row == start.0 ? max(0, start.1) : 0
            let hi = row == end.0 ? min(width - 1, end.1) : width - 1
            return lo <= hi ? lo..<(hi + 1) : nil
        }
    }

    /// The selected cells in viewport coordinates. Assign `nil` to clear the selection.
    package var selection: Selection? {
        get { viewport.selection }
        set {
            guard newValue != viewport.selection else { return }
            viewport.selection = newValue
            refreshInteraction()
            invalidateFrame()
        }
    }
    /// Delivers user input in order. Its owner encodes it on the same terminal that receives output.
    package var onInput: ((Terminal.Input) -> Void)?
    /// Opens a link the reader chose. ``TerminalView`` passes SwiftUI's `openURL` action, so an app can
    /// send links to its own browser. Otherwise the system opens them.
    var openURL: @MainActor (URL) -> Void = { url in
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
    /// Reads plain text for URLs, keeping what it found in lines that haven't changed.
    var finder = LinkFinder()
    /// The links found in the displayed snapshot's text, read when something first asks for them.
    var found: [LinkFinder.Found]?
    /// The link the renderer draws engaged. Input sets it while ⌘ is held over a link or one is pressed.
    var engagedLink: EngagedLink? {
        didSet {
            guard engagedLink != oldValue else { return }
            #if os(iOS)
            // A lifted link's cells come back in the transaction that takes its copy away.
            if oldValue?.lifted == true { nextFramePresentsWithTransaction = true }
            #endif
            invalidateFrame()
        }
    }
    /// Reports a new row and column count after layout. Apply the size to the terminal and its PTY.
    package var onGridSizeChange: ((Terminal.Size) -> Void)?
    /// Reports a change to the effective theme. Apply its palette to the terminal for OSC color replies.
    package var onThemeChange: ((TerminalTheme) -> Void)?
    /// Reports that the input gained or lost first responder. Read ``hasInputFocus`` for the result.
    var onInputFocusChange: (() -> Void)?
    /// Reports a change to the background the view draws, from the theme or the program.
    var onBackgroundChange: (() -> Void)?
    /// The measured size in cells, or `nil` until the view lays out nonempty bounds.
    package private(set) var gridSize: Terminal.Size?
    /// The theme the view currently draws, including any explicit override.
    package private(set) var resolvedTheme: TerminalTheme = .dark
    /// A nil override follows the native appearance.
    package var theme: TerminalTheme? { didSet { resolveTheme() } }
    #if os(macOS)
    package override var isOpaque: Bool { true }
    #else
    var beforeViewportResize: ((CGSize) -> Void)?
    /// Called just before this terminal's input asks UIKit to show or hide the keyboard.
    var beforeKeyboardMove: (() -> Void)?

    // The canvas controller coordinates the size change with UIKit's keyboard and orientation transitions.
    var holdsGridGeometry = false {
        didSet {
            guard oldValue != holdsGridGeometry else { return }
            heldGrid = nil
            if !holdsGridGeometry {
                heldRowsAround = 0
                // The new bounds and the first frame drawn for them commit together.
                nextFramePresentsWithTransaction = true
                updateGeometry()
            }
        }
    }
    /// Rows drawn above and below the held grid while a taller viewport brings them into view,
    /// so they're already there before the program answers the resize. The drawable stays
    /// centered on the held rows and keeps its leading edge as a turn widens the view.
    var heldRowsAround = 0 {
        didSet {
            guard oldValue != heldRowsAround, let metrics else { return }
            contentMode = heldRowsAround > 0 ? .left : .topLeft
            let size = CGSize(width: lastViewport.width,
                              height: lastViewport.height + CGFloat(2 * heldRowsAround * metrics.rowHeightPixels))
            if drawableSize != size { drawableSize = size }
            invalidateFrame()
        }
    }
    /// Called when the terminal delivers its first frame at the grid published while holding.
    var onHeldGridReady: (() -> Void)?
    private var heldGrid: Terminal.Size?

    /// Publishes the grid for the canvas's destination viewport while the held frame stays on
    /// screen. Returns false when no resized frame is coming, so the canvas can release now.
    func publishHeldGrid(for viewport: CGSize) -> Bool {
        guard holdsGridGeometry, let metrics, snapshot != nil, viewport.width > 0, viewport.height > 0 else { return false }
        let next = metrics.size(in: viewport)
        guard next != gridSize else { return false }
        gridSize = next
        heldGrid = next
        onGridSizeChange?(next)
        return true
    }
    /// Whether the next frame presents in the Core Animation transaction that changed the layout or took a
    /// lifted link's copy away, so the two show together.
    private var nextFramePresentsWithTransaction = false
    #endif

    /// The terminal font size in points, from 6 through 96. A nil value uses 14 on Mac or 13 on iPhone.
    package var fontSize: CGFloat? {
        didSet {
            if let fontSize { precondition((6...96).contains(fontSize) && fontSize.isFinite) }
            updateGeometry()
        }
    }
    var beforeOutputDraw: (() -> Void)?
    private var takingOutput = false
    package var onFrame: ((FrameMeasurement) -> Void)?
    /// Capture the native layout at submission and match the GPU result using submittedAt.
    package var onFrameSubmitted: ((Double, Terminal.Size?, CGRect) -> Void)?
    /// Command-buffer completion can precede or outlive the drawable's presentation callback.
    package var onFrameCompleted: (@MainActor (FrameMeasurement) -> Void)?
    package private(set) var submissionCount = 0
    /// Blinking text holds steady while this is true. It follows the system's Reduce Motion setting.
    package var reducesMotion = false {
        didSet {
            guard oldValue != reducesMotion else { return }
            textBlink.stop()
            updateCursorSpinner()
            if showsBlinkingText { invalidateFrame() }
        }
    }
    private lazy var textBlink: TextBlink = TextBlink(redraw: { [weak self] in self?.invalidateFrame() },
                                                      fading: { [weak self] in self?.framePacer.isFading = $0 })
    private lazy var framePacer: FramePacer = FramePacer(view: self, drawOutput: { [weak self] in self?.draw() },
                                                         fadeTick: { [weak self] in self?.textBlink.tick(target: $0) })
    private var showsBlinkingText = false
    private var renderer: MetalRenderer?
    private var preparingDeviceID: UInt64?
    private var prepareTask: Task<Void, Never>?
    private var firstContentStart = CACurrentMediaTime()
    private var firstCompilation: Double?
    private var hasSubmittedContent = false
    private lazy var synchronizedOutput: SynchronizedOutputGate = {
        let gate = SynchronizedOutputGate { [weak self] snapshot, receivedAt in
            self?.accept(snapshot, receivedAt: receivedAt)
        }
        gate.setActive(active && window != nil)
        return gate
    }()
    private(set) var metrics: GridMetrics?
    var viewport = Viewport()
    package private(set) var snapshot: Terminal.Snapshot? {
        didSet {
            found = nil
            let colors = snapshot?.programColors ?? .init()
            guard colors != programColors else { return }
            let background = color(.background)
            programColors = colors
            if color(.background) != background { backgroundChanged() }
        }
    }
    /// The colors the displayed program set over the theme.
    private(set) var programColors = Terminal.ProgramColors()
    enum InputAvailability {
        case live, holdingKeys, blocked
    }

    private(set) var inputAvailability: InputAvailability = .live
    var acceptsTerminalInput: Bool { inputAvailability != .blocked }
    private var cursorSpinner: CursorSpinner?
    var onDisplacedTap: (() -> Void)? {
        didSet {
            #if os(macOS)
            macInput.cancelDisplacedClick()
            #endif
            if (oldValue == nil) != (onDisplacedTap == nil) { refreshInteraction() }
        }
    }
    private var finalFrameRevision: UInt64 = 0
    private var finalFrameWaiter: CheckedContinuation<Void, Never>?
    private var lastPointer: Terminal.Input.Pointer?
    private var capturedButtons: Set<Terminal.Input.Pointer.Button> = []
    #if os(macOS)
    private lazy var macInput = MacTerminalInput(terminal: self)
    #else
    package var showsKeyRow: Bool {
        get { phoneInput.showsKeyRow }
        set { phoneInput.showsKeyRow = newValue }
    }
    lazy var phoneInput = PhoneTerminalInput(terminal: self)
    private lazy var historyScrollView = PhoneHistoryScrollView(terminal: self)
    /// UIKit's measure of the last swipe as it lifted, which captures check each glide against.
    package var lastScrollRelease: (time: Double, travel: CGFloat, velocity: CGFloat)? { historyScrollView.lastRelease }
    #endif
    private var received: Double?
    private var active = true
    private var dirty = true
    private var inFlight = 0
    private var lastViewport = CGSize.zero

    /// Creates a terminal view using the system's default Metal device.
    package convenience init(frame: CGRect) { self.init(frame: frame, device: MTLCreateSystemDefaultDevice()) }
    /// Creates a terminal view for the specified Metal device.
    package override init(frame: CGRect, device: (any MTLDevice)?) {
        super.init(frame: frame, device: device)
        configure()
    }
    /// Restores a terminal view from an archive, using the default Metal device if needed.
    package required init(coder: NSCoder) {
        super.init(coder: coder)
        if device == nil { device = MTLCreateSystemDefaultDevice() }
        configure()
    }

    private func configure() {
        isPaused = true
        enableSetNeedsDisplay = true
        colorPixelFormat = .bgra8Unorm
        #if os(macOS)
        wantsLayer = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(followReduceMotion), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        layer?.isOpaque = true
        #else
        isOpaque = true
        // Keep the last drawable at its native scale while UIKit animates the new bounds.
        contentMode = .topLeft
        autoResizeDrawable = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TerminalMetalView, _: UITraitCollection) in
            view.resolveTheme()
        }
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: TerminalMetalView, _: UITraitCollection) in
            view.updateGeometry()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(trimMemory),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(followReduceMotion),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        #endif
        followReduceMotion()
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        #if os(macOS)
        macInput.frame = bounds
        macInput.autoresizingMask = [.width, .height]
        addSubview(macInput)
        #else
        historyScrollView.frame = bounds
        historyScrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(historyScrollView)
        addSubview(phoneInput)
        #endif
        delegate = self
        prepareRenderer()
        resolveTheme()
        applyClearColor()
    }

    private func prepareRenderer() {
        guard let device, preparingDeviceID != device.registryID else { return }
        prepareTask?.cancel()
        preparingDeviceID = device.registryID
        renderer = nil
        hasSubmittedContent = false
        firstContentStart = CACurrentMediaTime()
        prepareTask = Task { [weak self] in
            do {
                let program = try await ShaderPipelines.shared.pipeline(for: device)
                guard let self, !Task.isCancelled, self.device?.registryID == device.registryID else { return }
                self.renderer = try MetalRenderer(device: device, pipeline: program)
                self.firstCompilation = program.startedAt >= self.firstContentStart ? program.compileSeconds : nil
                self.invalidateFrame()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.preparingDeviceID = nil
                NSLog("Thrush Metal setup failed: %@", String(describing: error))
            }
        }
    }

    @objc private func followReduceMotion() {
        #if os(macOS)
        reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        reducesMotion = UIAccessibility.isReduceMotionEnabled
        #endif
    }

    @objc private func trimMemory() {
        renderer?.discardResources()
        releaseDrawables()
        invalidateFrame()
    }

    #if os(macOS)
    /// Updates the terminal grid to fit the view's bounds.
    package override func layout() { super.layout(); updateGeometry() }
    /// Recalculates cell geometry when the window's backing scale changes.
    package override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateGeometry() }
    /// Updates rendering and grid geometry when the view moves into or out of a window.
    package override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAttachment() }
    /// Resolves the terminal theme when AppKit changes the effective appearance.
    package override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); resolveTheme() }
    #else
    /// Updates the terminal grid to fit the view's bounds.
    package override func layoutSubviews() { super.layoutSubviews(); updateGeometry() }
    /// Updates rendering and grid geometry when the view moves into or out of a window.
    package override func didMoveToWindow() {
        super.didMoveToWindow()
        // A program can ask for the background as soon as the view shows, so adopt the window's appearance
        // now rather than at the next layout.
        if window != nil { updateTraitsIfNeeded() }
        updateAttachment()
    }
    #endif

    private func updateAttachment() {
        if window == nil {
            finishFinalFrame()
            textBlink.stop()
            framePacer.stop()
        } else {
            framePacer.reattach()
        }
        synchronizedOutput.setActive(active && window != nil)
        updateGeometry()
        updateCursorSpinner()
        invalidateFrame()
    }

    private func resolveTheme() {
        #if os(macOS)
        let isDark = effectiveAppearance.isDark
        #else
        let isDark = traitCollection.userInterfaceStyle == .dark
        #endif
        let next = theme ?? (isDark ? .dark : .light)
        guard next != resolvedTheme else { return }
        resolvedTheme = next
        onThemeChange?(next)
        // An active program background can stay the same while an overlapping Mac toolbar changes theme.
        backgroundChanged()
        refreshInteraction()
        invalidateFrame()
    }

    /// The color the view draws for a slot: the program's when it set one, otherwise the theme's.
    func color(_ slot: Terminal.ColorSlot) -> Terminal.RGB {
        programColors.resolve(slot, palette: resolvedTheme.palette, cursor: resolvedTheme.cursor)
    }

    private func backgroundChanged() {
        applyClearColor()
        onBackgroundChange?()
    }

    private func applyClearColor() {
        let background = color(.background)
        (layer as? CAMetalLayer)?.backgroundColor = background.cgColor
        let c = background.vector
        clearColor = MTLClearColor(red: Double(c.x), green: Double(c.y), blue: Double(c.z), alpha: 1)
    }

    private func updateGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        #if os(macOS)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        #else
        guard !holdsGridGeometry else { return }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : contentScaleFactor
        #endif
        let pixelSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        #if os(iOS)
        if lastViewport != pixelSize, let metrics {
            beforeViewportResize?(CGSize(width: lastViewport.width / metrics.scale, height: lastViewport.height / metrics.scale))
            guard !holdsGridGeometry else { return }
        }
        #endif
        let nextSize = fontSize ?? GridMetrics.defaultPointSize
        var needsGeometry = false
        if metrics?.scale != scale || metrics?.pointSize != nextSize {
            metrics = GridMetrics(scale: scale, pointSize: nextSize)
            renderer?.discardResources()
            needsGeometry = true
        }
        if lastViewport != pixelSize {
            lastViewport = pixelSize
            if drawableSize != pixelSize { drawableSize = pixelSize }
            renderer?.discardGeometry()
            needsGeometry = true
        }
        guard let metrics else { return }
        let next = metrics.size(in: bounds.size)
        if next != gridSize {
            gridSize = next
            onGridSizeChange?(next)
        }
        if needsGeometry {
            refreshInteraction()
            invalidateFrame()
        }
    }

    /// Displays the latest state of the terminal, preserving the viewport's selection and scroll position when possible.
    package func display(_ terminal: Terminal, receivedAt: CFTimeInterval? = nil) {
        display(terminal.snapshot(), receivedAt: receivedAt)
    }

    /// A draw can pick up another ordinary snapshot after the first wakeup invalidated the view.
    /// Its latency still starts at the first receipt. A successful submission clears that receipt.
    func displayOutput(_ frame: OutputMailbox.Frame) -> Double? {
        let firstReceipt = received ?? frame.receipt
        display(frame.screen, receivedAt: firstReceipt)
        return firstReceipt
    }

    package func display(_ next: Terminal.Snapshot, receivedAt: CFTimeInterval? = nil) {
        synchronizedOutput.submit(next, receivedAt: receivedAt, synchronizedOutputID: next.synchronizedOutputID)
    }

    private func accept(_ next: Terminal.Snapshot, receivedAt: CFTimeInterval?) {
        if let last = snapshot, last.generation == next.generation { return }
        let oldTracking = snapshot?.modes.mouseTracking
        viewport.display(next)
        snapshot = next.viewport(rowsFromBottom: viewport.offset)
        if oldTracking != next.modes.mouseTracking {
            lastPointer = nil
            capturedButtons.removeAll()
        }
        updateDisplayedFrame(receivedAt: receivedAt)
    }

    /// Install a replay, retained screen, or new shell without disturbing its native responder.
    package func replaceDisplayedSnapshot(_ next: Terminal.Snapshot, receivedAt: CFTimeInterval?,
                                          archivingMainScreen: Bool = false) {
        synchronizedOutput.reset()
        #if os(macOS)
        macInput.invalidateAccessibleText()
        #endif
        viewport.replace(next, archivingMainScreen: archivingMainScreen)
        snapshot = next.viewport(rowsFromBottom: viewport.offset)
        renderer?.discardGeometry()
        lastPointer = nil
        capturedButtons.removeAll()
        updateDisplayedFrame(receivedAt: receivedAt)
    }

    private func updateDisplayedFrame(receivedAt: CFTimeInterval?) {
        refreshInteraction()
        received = receivedAt
        #if os(iOS)
        if let heldGrid, snapshot?.size == heldGrid {
            self.heldGrid = nil
            onHeldGridReady?()
        }
        #endif
        invalidateOutput()
    }

    /// Flush synchronized output and publish the final drawable before dismissing input.
    /// Simulator provides the GPU completion callback in place of a drawable presentation handler.
    func presentFinal(_ next: Terminal.Snapshot) async {
        synchronizedOutput.reset()
        accept(next, receivedAt: received)
        guard window != nil, device != nil else { return }
        finishFinalFrame()
        await withCheckedContinuation { continuation in
            finalFrameWaiter = continuation
            invalidateFrame()
        }
    }

    func finishFinalFrame() {
        finalFrameRevision &+= 1
        finalFrameWaiter?.resume()
        finalFrameWaiter = nil
    }

    func setInputAvailability(_ availability: InputAvailability, dismissKeyboard: Bool) {
        if inputAvailability != availability {
            let acceptedKeys = acceptsTerminalInput
            inputAvailability = availability
            lastPointer = nil
            capturedButtons.removeAll()
            refreshInteraction()
            if acceptedKeys != acceptsTerminalInput { invalidateFrame() }
        }
        if dismissKeyboard {
            cancelPendingInput()
            #if os(iOS)
            _ = phoneInput.resignFirstResponder()
            #endif
        }
    }

    /// Clears the displayed screen, selection, scroll position and pending input before displaying a different terminal.
    package func reset() {
        finishFinalFrame()
        synchronizedOutput.reset()
        snapshot = nil
        #if os(macOS)
        macInput.invalidateAccessibleText()
        #endif
        viewport = Viewport()
        cancelPendingInput()
        refreshInteraction()
        received = nil
        renderer?.discardGeometry()
        invalidateFrame()
    }

    /// A covered Mac window keeps its shell and composition. Only the latest generation
    /// reaches Metal when the surface becomes visible again.
    package func setDrawingVisible(_ visible: Bool) {
        guard active != visible else { return }
        active = visible
        updateCursorSpinner()
        synchronizedOutput.setActive(visible && window != nil)
        if visible {
            invalidateFrame()
        } else {
            textBlink.stop()
            framePacer.stop()
            releaseDrawables()
        }
    }

    func setWaiting(_ label: String?) {
        if let label {
            let spinner = cursorSpinner ?? CursorSpinner()
            #if os(macOS)
            if spinner.accessibilityLabel() != label { spinner.setAccessibilityLabel(label) }
            #else
            if spinner.accessibilityLabel != label { spinner.accessibilityLabel = label }
            #endif
            guard cursorSpinner == nil else { return }
            cursorSpinner = spinner
            addSubview(spinner)
            updateCursorSpinner()
        } else {
            guard let spinner = cursorSpinner else { return }
            spinner.removeFromSuperview()
            cursorSpinner = nil
        }
        invalidateFrame()
    }

    /// Observes everything the view asks VoiceOver to speak.
    var onAccessibilityAnnouncement: ((String) -> Void)?

    /// Queue speech without redirecting accessibility focus away from the viewport.
    func announce(_ text: String) {
        guard window != nil else { return }
        #if os(macOS)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.low.rawValue])
        #else
        let speech = NSAttributedString(string: text, attributes: [
            .accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.low.rawValue
        ])
        UIAccessibility.post(notification: .announcement, argument: speech)
        #endif
        onAccessibilityAnnouncement?(text)
    }

    private var spinnerPosition: (row: Int, column: Int) {
        let cursor = cursorRect
        guard let snapshot, snapshot.cursorVisible, !cursor.isEmpty, bounds.contains(cursor) else { return (0, 0) }
        return (snapshot.cursorRow, min(snapshot.cursorColumn, snapshot.size.columns - 1))
    }

    private var visibleCursorCell: CGRect {
        let position = spinnerPosition
        let cell = cellRect(row: position.row, column: position.column)
        // Grid coordinates start at the top left. AppKit's Metal view may be unflipped.
        #if os(macOS)
        return macInput.convert(cell, to: self)
        #else
        return cell
        #endif
    }

    private func updateCursorSpinner() {
        guard let spinner = cursorSpinner else { return }
        let cell = visibleCursorCell
        let side = min(16, cell.width, cell.height)
        guard side > 0, bounds.contains(cell), active, window != nil else {
            spinner.setAnimating(false)
            spinner.isHidden = true
            return
        }
        let rect = CGRect(x: cell.midX - side / 2, y: cell.midY - side / 2, width: side, height: side)
        #if os(macOS)
        spinner.ink = spinnerInk.cgColor
        #else
        spinner.color = UIColor(terminal: spinnerInk)
        #endif
        spinner.place(in: rect)
        spinner.isHidden = false
        spinner.setAnimating(!reducesMotion)
    }

    /// Match the painted cursor, allowing contrast headroom for antialiasing at small cell sizes.
    private var spinnerInk: Terminal.RGB {
        let program = snapshot?.programColors ?? .init()
        func color(_ slot: Terminal.ColorSlot) -> Terminal.RGB {
            program.resolve(slot, palette: resolvedTheme.palette, cursor: resolvedTheme.cursor)
        }
        var ink = color(.cursor)
        var paper = color(.background)
        if let snapshot {
            let (y, x) = spinnerPosition
            let row = snapshot.rows[y]
            let start = x > 0 && row[x].width == 0 && row[x - 1].width == 2 ? x - 1 : x
            let cell = row[start]
            if selection?.columns(in: y, width: snapshot.size.columns)?.overlaps(start..<(start + max(1, cell.width))) == true {
                ink = resolvedTheme.selectionInk
                paper = resolvedTheme.selection
            } else {
                let style = cell.style
                paper = switch style.inverse ? style.foreground : style.background {
                case .default: style.inverse ? color(.foreground) : paper
                case .indexed(let index): color(.indexed(index))
                case let .rgb(r, g, b): .init(red: r, green: g, blue: b)
                }
            }
        }
        guard ink.contrast(with: paper) < 4.5 else { return ink }
        return paper.isDark ? .white : .init(red: 0, green: 0, blue: 0)
    }

    /// Top-left window coordinates, measured independently from the grid and its native indicator.
    package var cursorCellFrameInWindow: CGRect? { frameInWindow(visibleCursorCell, from: self) }

    package func cellFrameInWindow(row: Int, column: Int) -> CGRect? {
        guard let gridSize, (0..<gridSize.rows).contains(row), (0..<gridSize.columns).contains(column) else { return nil }
        let cell = cellRect(row: row, column: column)
        #if os(macOS)
        return frameInWindow(cell, from: macInput)
        #else
        return frameInWindow(cell, from: self)
        #endif
    }

    package var cursorSpinnerFrameInWindow: CGRect? {
        guard let spinner = cursorSpinner, !spinner.isHidden else { return nil }
        return frameInWindow(spinner.bounds, from: spinner)
    }

    private func frameInWindow(_ rect: CGRect, from view: PlatformView) -> CGRect? {
        guard let window, !rect.isEmpty else { return nil }
        #if os(macOS)
        let frame = view.convert(rect, to: nil)
        return CGRect(x: frame.minX, y: window.frame.height - frame.maxY, width: frame.width, height: frame.height)
        #else
        return view.convert(rect, to: window)
        #endif
    }

    /// A deliberate primary tap may reclaim a displaced session. It sends no terminal input.
    @discardableResult package func tapDisplacedGrid() -> Bool {
        guard let action = onDisplacedTap else { return false }
        onDisplacedTap = nil
        action()
        return true
    }

    /// Requests native keyboard focus for this viewport and returns whether it was granted.
    @discardableResult package func focusInput() -> Bool {
        guard acceptsTerminalInput else { return false }
        #if os(macOS)
        return window?.makeFirstResponder(macInput) ?? false
        #else
        return phoneInput.becomeFirstResponder()
        #endif
    }

    /// Whether the terminal's input is first responder, so keystrokes reach it while its window has focus.
    var hasInputFocus: Bool {
        #if os(macOS)
        window?.firstResponder === macInput
        #else
        phoneInput.isFirstResponder
        #endif
    }

    // The responder chain finishes updating after become and resign return.
    func inputFocusDidChange() {
        Task { @MainActor [weak self] in self?.onInputFocusChange?() }
    }

    /// Discard local composition and latched modifiers when the session detaches from the PTY.
    package func cancelPendingInput() {
        lastPointer = nil
        capturedButtons.removeAll()
        engagedLink = nil
        #if os(macOS)
        macInput.resetInteraction()
        #else
        phoneInput.cancelPendingInput()
        #endif
    }

    func refreshInteraction() {
        #if os(macOS)
        macInput.refresh()
        #else
        phoneInput.synchronize(cursorRect: cursorRect, pointSize: metrics?.pointSize ?? GridMetrics.defaultPointSize, theme: resolvedTheme,
                               ink: color(.foreground), paper: color(.background))
        historyScrollView.synchronize()
        #endif
        if cursorSpinner != nil { updateCursorSpinner() }
    }

    package func setHistoryOffset(_ rows: Int) {
        let old = viewport.offset
        viewport.scroll(rows)
        guard old != viewport.offset else { return }
        snapshot = viewport.source?.viewport(rowsFromBottom: viewport.offset)
        refreshInteraction()
        invalidateFrame()
    }

    func reportPointer(_ action: Terminal.Input.Pointer.Action, button: Terminal.Input.Pointer.Button,
                       row: Int, column: Int, modifiers: Terminal.Input.Modifiers = []) -> Bool {
        guard isPointerReporting, !modifiers.contains(.shift) || capturedButtons.contains(button) else { return false }
        switch action {
        case .press where button == .left || button == .middle || button == .right: capturedButtons.insert(button)
        case .release: capturedButtons.remove(button)
        default: break
        }
        let pointer = Terminal.Input.Pointer(action, button: button, row: row, column: column, modifiers: modifiers)
        if action != .move || pointer != lastPointer {
            onInput?(.pointer(pointer))
            lastPointer = pointer
        }
        return true
    }

    /// Sends rows of scrolling to the program, toward earlier output for positive rows. The core
    /// encodes each row as a wheel report, or as an arrow key on the alternate screen without reporting.
    func scrollProgram(rows: Int, row: Int, column: Int, modifiers: Terminal.Input.Modifiers = []) {
        guard programTakesScrolling, !modifiers.contains(.shift), rows != 0 else { return }
        let pointer = Terminal.Input.Pointer(.press, button: rows > 0 ? .wheelUp : .wheelDown, row: row, column: column,
                                             modifiers: modifiers)
        for _ in 0..<min(64, abs(rows)) { onInput?(.pointer(pointer)) }
    }

    func updateSelection(_ update: (inout Viewport) -> Void) {
        let previous = selection
        update(&viewport)
        if selection != previous {
            refreshInteraction()
            invalidateFrame()
        }
    }

    /// Program output draws at the frame pacer's deadline, so a burst of writes shares one frame.
    /// Output taken by the frame being drawn needs no other.
    private func invalidateOutput() {
        dirty = true
        guard active, window != nil, !takingOutput else { return }
        if !framePacer.outputChanged() { invalidateFrame() }
    }

    private func invalidateFrame() {
        dirty = true
        guard active, inFlight < 3, window != nil else { return }
        #if os(macOS)
        needsDisplay = true
        #else
        setNeedsDisplay()
        #endif
    }

    /// Schedules a new frame when MetalKit changes the drawable size.
    package func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { invalidateFrame() }

    /// The rows and selection the next frame draws, including any rows held around the grid.
    var drawnContent: (Terminal.Snapshot?, Selection?) {
        #if os(iOS)
        let around = heldRowsAround
        if around > 0, let source = viewport.source {
            return (source.viewport(rowsFromBottom: viewport.offset, extendedBy: around), selection.map {
                Selection(anchorRow: $0.anchorRow + around, anchorColumn: $0.anchorColumn,
                          headRow: $0.headRow + around, headColumn: $0.headColumn)
            })
        }
        #endif
        return (snapshot, selection)
    }

    /// Submits the pending terminal frame when MetalKit asks the view to draw.
    package func draw(in view: MTKView) {
        guard active, dirty, inFlight < 3, window != nil else { return }
        // A frame's cost runs from when the pacer scheduled it until its GPU work ends.
        let due = framePacer.due ?? CACurrentMediaTime()
        // The frame takes waiting output before it measures anything, so a held grid that the
        // output completes releases, and its layout presents with this frame.
        takingOutput = true
        beforeOutputDraw?()
        takingOutput = false
        updateGeometry()
        #if os(iOS)
        if presentsWithTransaction != nextFramePresentsWithTransaction { presentsWithTransaction = nextFramePresentsWithTransaction }
        nextFramePresentsWithTransaction = false
        #endif
        prepareRenderer()
        guard let renderer, let metrics, drawableSize.width > 0, drawableSize.height > 0,
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable else { return }
        let started = CACurrentMediaTime()
        let (drawn, drawnSelection) = drawnContent
        do {
            let frame = try renderer.encode(snapshot: drawn, metrics: metrics, theme: resolvedTheme,
                                            pass: pass, selection: drawnSelection, links: drawn.map(drawnLinks) ?? [],
                                            showsCursor: acceptsTerminalInput && cursorSpinner == nil,
                                            blinkOpacity: reducesMotion ? 1 : textBlink.opacity)
            let submitted = CACurrentMediaTime()
            let first = snapshot != nil && !hasSubmittedContent
            if first { hasSubmittedContent = true }
            let finalRevision = finalFrameWaiter == nil ? nil : finalFrameRevision
            let report = onFrame
            let reportCompletion = onFrameCompleted
            let observesPresentation = report != nil || finalRevision != nil
            let timing: FrameTiming? = (observesPresentation || reportCompletion != nil) ?
                FrameTiming(.init(generation: snapshot?.generation ?? 0, cpuPreparationSeconds: submitted - started,
                                  shaderCompileSeconds: first ? firstCompilation : nil,
                                  firstFrameSeconds: first ? submitted - firstContentStart : nil, receivedAt: received,
                                  submittedAt: submitted, glyphUploads: frame.glyphUploads,
                                  rowsPrepared: frame.rowsPrepared)) { [weak self] frame in
                    report?(frame)
                    if let self, let finalRevision, self.finalFrameRevision == finalRevision {
                        if frame.gpuCompleted { self.finishFinalFrame() }
                        else { self.invalidateFrame() }
                    }
                } : nil
            #if targetEnvironment(simulator)
            // The Simulator SDK exposes no drawable presentation handler or timestamp.
            timing?.presentationKnown = true
            #else
            if observesPresentation, let timing {
                drawable.addPresentedHandler { output in
                    let time = output.presentedTime
                    Task { @MainActor in
                        timing.frame.presentedTime = time > 0 ? time : nil
                        timing.presentationKnown = true
                        timing.resolve()
                    }
                }
            }
            #endif
            frame.buffer.addCompletedHandler { [weak self] command in
                let gpu = command.gpuEndTime - command.gpuStartTime
                let completed = command.status == .completed
                let ready = command.gpuEndTime > 0 ? command.gpuEndTime : CACurrentMediaTime()
                Task { @MainActor in
                    if let timing {
                        timing.frame.gpuSeconds = gpu > 0 ? gpu : nil
                        timing.frame.gpuCompleted = completed
                        timing.completed = true
                        reportCompletion?(timing.frame)
                        if !completed { timing.presentationKnown = true }
                        timing.resolve()
                    }
                    if let self {
                        if completed { self.framePacer.record(cost: ready - due) }
                        self.inFlight -= 1
                        if self.dirty { self.invalidateFrame() }
                    }
                }
            }
            dirty = false
            framePacer.drew()
            received = nil
            inFlight += 1
            submissionCount += 1
            if let onFrameSubmitted {
                let size = snapshot?.size
                let grid = CGRect(x: CGFloat(metrics.x(0)), y: CGFloat(metrics.y(0)),
                                  width: CGFloat(metrics.x(size?.columns ?? 0) - metrics.x(0)),
                                  height: CGFloat(metrics.y(size?.rows ?? 0) - metrics.y(0)))
                onFrameSubmitted(submitted, size, grid)
            }
            if presentsWithTransaction {
                frame.buffer.commit()
                frame.buffer.waitUntilScheduled()
                drawable.present()
            } else {
                frame.buffer.present(drawable)
                frame.buffer.commit()
            }
            showsBlinkingText = frame.blinks
            textBlink.frameDrawn(blinking: frame.blinks && !reducesMotion)
        } catch {
            renderer.discardResources()
            NSLog("Thrush Metal frame failed: %@", String(describing: error))
        }
    }
}
