import MetalKit
import Thrush

/// Timing from the monotonic media clock used by CAMetalDrawable.presentedTime.
package struct FrameMeasurement: Sendable {
    package let generation: UInt64
    package let gpuCompleted: Bool
    package let cpuPreparationSeconds: Double
    package let shaderCompileSeconds: Double?
    package let firstFrameSeconds: Double?
    package let gpuSeconds: Double?
    package let presentedTime: Double?
    package let receivedAt: Double?
    package let submittedAt: Double
    package let glyphUploads: Int
    package let rowsPrepared: Int
}

@MainActor
private final class Presentation {
    let cpu: Double, submitted: Double
    let shaderCompile: Double?, firstFrame: Double?
    let received: Double?
    let generation: UInt64
    let uploads: Int, rows: Int
    let report: (FrameMeasurement) -> Void
    var gpu: Double?
    var presented: Double?
    var completed = false
    var gpuCompleted = false
    var presentationKnown = false
    var delivered = false

    init(cpu: Double, shaderCompile: Double?, firstFrame: Double?, submitted: Double, received: Double?, generation: UInt64, uploads: Int, rows: Int,
         report: @escaping (FrameMeasurement) -> Void) {
        self.shaderCompile = shaderCompile
        self.firstFrame = firstFrame
        self.cpu = cpu
        self.submitted = submitted
        self.received = received
        self.generation = generation
        self.uploads = uploads
        self.rows = rows
        self.report = report
    }

    var measurement: FrameMeasurement {
        .init(generation: generation, gpuCompleted: gpuCompleted, cpuPreparationSeconds: cpu, shaderCompileSeconds: shaderCompile,
              firstFrameSeconds: firstFrame, gpuSeconds: gpu, presentedTime: presented, receivedAt: received,
              submittedAt: submitted, glyphUploads: uploads, rowsPrepared: rows)
    }

    func resolve() {
        guard completed, presentationKnown, !delivered else { return }
        delivered = true
        report(measurement)
    }
}

/// Embed this view in AppKit or UIKit when your host manages its own terminal and transport.
/// For a SwiftUI host with a `TerminalConnection`, `TerminalPane` manages the view and its connection.
/// Keep one native view per viewport. After applying output to the terminal, pass it to `display(_:)`.
/// Use `onInput` and `onGridSizeChange` to forward user input and resize the terminal and its PTY.
@MainActor
public final class TerminalView: MTKView, MTKViewDelegate {
    /// Two inclusive cell positions relative to the displayed viewport, with the origin at its top left.
    /// A selection may extend in either direction. Selecting either column of a wide glyph highlights the whole glyph.
    public struct Selection: Equatable, Sendable {
        /// The zero-based row where the selection began.
        public let anchorRow: Int
        /// The zero-based column where the selection began.
        public let anchorColumn: Int
        /// The zero-based row at the moving end of the selection.
        public let headRow: Int
        /// The zero-based column at the moving end of the selection.
        public let headColumn: Int

        /// Creates a selection from its starting cell through its current end cell, inclusive.
        public init(anchorRow: Int, anchorColumn: Int, headRow: Int, headColumn: Int) {
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
    public var selection: Selection? {
        get { transcript.selection }
        set {
            guard newValue != transcript.selection else { return }
            transcript.selection = newValue
            refreshInteraction()
            invalidateFrame()
        }
    }
    /// Delivers user input in order. Its owner encodes it on the same terminal that receives output.
    public var onInput: ((Terminal.Input) -> Void)?
    /// Reports a new row and column count after layout. Apply the size to the terminal and its PTY.
    public var onGridSizeChange: ((Terminal.Size) -> Void)?
    /// Reports a change to the effective theme. Apply its palette to the terminal for OSC color replies.
    public var onThemeChange: ((TerminalTheme) -> Void)?
    /// The measured size in cells, or `nil` until the view lays out nonempty bounds.
    public private(set) var gridSize: Terminal.Size?
    /// The theme the view currently draws, including any explicit override.
    public private(set) var resolvedTheme: TerminalTheme = .slateDark
    /// A nil override follows the native appearance.
    public var theme: TerminalTheme? { didSet { resolveTheme() } }
    #if os(macOS)
    /// Opacity of the terminal background over a native Mac backdrop, clamped to 0 through 1.
    /// The default is 1. Reduce Transparency and nonfinite values draw an opaque background.
    public var backgroundOpacity: Double = 1 {
        didSet { updateBackgroundCompositing() }
    }
    private var effectiveOpacity: Double {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
              backgroundOpacity.isFinite else { return 1 }
        return min(1, max(0, backgroundOpacity))
    }
    /// Whether the terminal background is opaque after applying accessibility preferences.
    public override var isOpaque: Bool { effectiveOpacity == 1 }

    @objc private func updateBackgroundCompositing() {
        layer?.isOpaque = isOpaque
        applyClearColor()
        invalidateFrame()
    }
    #endif

    /// The terminal font size in points, from 6 through 96. A nil value uses 14 on Mac or 13 on iPhone.
    public var fontSize: CGFloat? {
        didSet {
            if let fontSize { precondition((6...96).contains(fontSize) && fontSize.isFinite) }
            updateGeometry()
        }
    }
    package var onFrame: ((FrameMeasurement) -> Void)?
    /// Capture the native layout at submission and match the GPU result using submittedAt.
    package var onFrameSubmitted: ((Double, Terminal.Size?, CGRect) -> Void)?
    /// Command-buffer completion can precede or outlive the drawable's presentation callback.
    package var onFrameCompleted: (@MainActor (FrameMeasurement) -> Void)?
    package private(set) var submissionCount = 0
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
    var transcript = TerminalTranscript()
    package private(set) var snapshot: Terminal.Snapshot?
    enum InputAvailability {
        case live, holdingKeys, blocked
    }

    private(set) var inputAvailability: InputAvailability = .live
    var acceptsTerminalInput: Bool { inputAvailability != .blocked }
    var noticeBottomInset: CGFloat = 0 {
        didSet { if oldValue != noticeBottomInset { refreshInteraction() } }
    }
    var onViewportInteractionChange: (() -> Void)?
    private var finalFrameRevision: UInt64 = 0
    private var finalFrameWaiter: CheckedContinuation<Void, Never>?
    private var lastPointer: Terminal.Input.Pointer?
    private var capturedButtons: Set<Terminal.Input.Pointer.Button> = []
    #if os(macOS)
    private lazy var macInput = MacTerminalInput(terminal: self)
    #else
    /// Choose the standard terminal keys, hide the accessory, or supply native controls.
    public var keyboardAccessory: TerminalKeyboardAccessory = .standard {
        didSet { if oldValue != keyboardAccessory { phoneInput.setAccessory(keyboardAccessory) } }
    }
    lazy var phoneInput = PhoneTerminalInput(terminalView: self)
    private lazy var phoneTranscript = PhoneTranscriptView(terminal: self)
    #endif
    private var received: Double?
    private var active = true
    private var dirty = true
    private var inFlight = 0
    private var lastViewport = CGSize.zero

    /// Creates a terminal view using the system's default Metal device.
    public convenience init(frame: CGRect) { self.init(frame: frame, device: MTLCreateSystemDefaultDevice()) }
    /// Creates a terminal view for the specified Metal device.
    public override init(frame: CGRect, device: (any MTLDevice)?) {
        super.init(frame: frame, device: device)
        configure()
    }
    /// Restores a terminal view from an archive, using the default Metal device if needed.
    public required init(coder: NSCoder) {
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
            self, selector: #selector(updateBackgroundCompositing),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        layer?.isOpaque = isOpaque
        #else
        isOpaque = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TerminalView, _: UITraitCollection) in
            view.resolveTheme()
        }
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: TerminalView, _: UITraitCollection) in
            view.updateGeometry()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(trimMemory),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #endif
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        #if os(macOS)
        macInput.frame = bounds
        macInput.autoresizingMask = [.width, .height]
        addSubview(macInput)
        #else
        phoneTranscript.frame = bounds
        phoneTranscript.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(phoneTranscript)
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

    @objc private func trimMemory() {
        renderer?.discardResources()
        releaseDrawables()
        invalidateFrame()
    }

    #if os(macOS)
    /// Updates the terminal grid to fit the view's bounds.
    public override func layout() { super.layout(); updateGeometry() }
    /// Recalculates cell geometry when the window's backing scale changes.
    public override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateGeometry() }
    /// Updates rendering and grid geometry when the view moves into or out of a window.
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAttachment() }
    /// Resolves the terminal theme when AppKit changes the effective appearance.
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); resolveTheme() }
    #else
    /// Updates the terminal grid to fit the view's bounds.
    public override func layoutSubviews() { super.layoutSubviews(); updateGeometry() }
    /// Updates rendering and grid geometry when the view moves into or out of a window.
    public override func didMoveToWindow() { super.didMoveToWindow(); updateAttachment() }
    #endif

    private func updateAttachment() {
        if window == nil { finishFinalFrame() }
        synchronizedOutput.setActive(active && window != nil)
        updateGeometry()
        invalidateFrame()
    }

    private func resolveTheme() {
        #if os(macOS)
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        #else
        let isDark = traitCollection.userInterfaceStyle == .dark
        #endif
        let next = theme ?? (isDark ? .slateDark : .slateLight)
        guard next != resolvedTheme else { return }
        resolvedTheme = next
        applyClearColor()
        onThemeChange?(next)
        refreshInteraction()
        invalidateFrame()
    }

    private func applyClearColor() {
        let c = resolvedTheme.palette.background.vector
        let background = CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        #if os(macOS)
        let alpha = effectiveOpacity
        (layer as? CAMetalLayer)?.backgroundColor = alpha == 1 ? background : nil
        #else
        let alpha = 1.0
        (layer as? CAMetalLayer)?.backgroundColor = background
        #endif
        // Core Animation composites the drawable as premultiplied RGBA.
        clearColor = MTLClearColor(red: Double(c.x) * alpha, green: Double(c.y) * alpha,
                                   blue: Double(c.z) * alpha, alpha: alpha)
    }

    private func updateGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        #if os(macOS)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        #else
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : contentScaleFactor
        #endif
        let pixelSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let nextSize: CGFloat = fontSize ?? {
            #if os(macOS)
            14
            #else
            13
            #endif
        }()
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
    public func display(_ terminal: Terminal) {
        display(terminal, receivedAt: nil)
    }

    package func display(_ terminal: Terminal, receivedAt: CFTimeInterval?) {
        display(terminal.snapshot(), receivedAt: receivedAt)
    }

    package func display(_ next: Terminal.Snapshot, receivedAt: CFTimeInterval? = nil) {
        synchronizedOutput.submit(next, receivedAt: receivedAt, synchronizedOutputID: next.synchronizedOutputID)
    }

    private func accept(_ next: Terminal.Snapshot, receivedAt: CFTimeInterval?) {
        if let last = snapshot, last.generation == next.generation { return }
        let oldTracking = snapshot?.mouseTracking
        transcript.display(next)
        snapshot = next.viewport(rowsFromBottom: transcript.offset)
        if oldTracking != next.mouseTracking {
            lastPointer = nil
            capturedButtons.removeAll()
        }
        refreshInteraction()
        received = receivedAt
        invalidateFrame()
    }

    /// An in-band replay replaces the entire source, whose generation and row IDs start over.
    /// Keep the native responder and any committed selection that still identifies the same text.
    package func replaceDisplayedSnapshot(_ next: Terminal.Snapshot, receivedAt: CFTimeInterval?) {
        synchronizedOutput.reset()
        #if os(macOS)
        macInput.invalidateTranscriptCache()
        #endif
        transcript.replace(next)
        snapshot = next.viewport(rowsFromBottom: transcript.offset)
        renderer?.discardGeometry()
        lastPointer = nil
        capturedButtons.removeAll()
        refreshInteraction()
        received = receivedAt
        invalidateFrame()
    }

    /// Flush synchronized output and publish the final drawable before adding the Ended notice.
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

    private func finishFinalFrame() {
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
    public func reset() {
        finishFinalFrame()
        synchronizedOutput.reset()
        snapshot = nil
        #if os(macOS)
        macInput.invalidateTranscriptCache()
        #endif
        transcript = TerminalTranscript()
        cancelPendingInput()
        refreshInteraction()
        received = nil
        renderer?.discardGeometry()
        invalidateFrame()
    }

    /// Suspends or resumes drawing. Suspending clears the view's uncommitted input.
    public func setRenderingActive(_ newValue: Bool) {
        if !newValue {
            finishFinalFrame()
            cancelPendingInput()
        }
        setDrawingVisible(newValue)
    }

    /// A covered Mac window keeps its shell and composition. Only the latest generation
    /// reaches Metal when the surface becomes visible again.
    func setDrawingVisible(_ visible: Bool) {
        guard active != visible else { return }
        active = visible
        synchronizedOutput.setActive(visible && window != nil)
        if visible { invalidateFrame() } else { releaseDrawables() }
    }

    /// Requests native keyboard focus for this viewport and returns whether it was granted.
    @discardableResult public func focusInput() -> Bool {
        guard acceptsTerminalInput else { return false }
        #if os(macOS)
        return window?.makeFirstResponder(macInput) ?? false
        #else
        return phoneInput.becomeFirstResponder()
        #endif
    }

    /// Discard local composition and latched modifiers when the host detaches from the PTY.
    public func cancelPendingInput() {
        lastPointer = nil
        capturedButtons.removeAll()
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
        phoneInput.synchronize(cursorRect: cursorRect, pointSize: metrics?.pointSize ?? 13, theme: resolvedTheme)
        phoneTranscript.synchronize()
        #endif
        onViewportInteractionChange?()
    }

    package func setHistoryOffset(_ rows: Int) {
        let old = transcript.offset
        transcript.scroll(rows)
        guard old != transcript.offset else { return }
        snapshot = transcript.source?.viewport(rowsFromBottom: transcript.offset)
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

    func updateSelection(_ update: (inout TerminalTranscript) -> Void) {
        let previous = selection
        update(&transcript)
        if selection != previous {
            refreshInteraction()
            invalidateFrame()
        }
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
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { invalidateFrame() }

    /// Submits the pending terminal frame when MetalKit asks the view to draw.
    public func draw(in view: MTKView) {
        guard active, dirty, inFlight < 3, window != nil else { return }
        updateGeometry()
        prepareRenderer()
        guard let renderer, let metrics, drawableSize.width > 0, drawableSize.height > 0,
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable else { return }
        let started = CACurrentMediaTime()
        do {
            let frame = try renderer.encode(snapshot: snapshot, metrics: metrics, theme: resolvedTheme,
                                            pass: pass, viewport: drawableSize, selection: selection, showsCursor: acceptsTerminalInput)
            let submitted = CACurrentMediaTime()
            let first = snapshot != nil && !hasSubmittedContent
            if first { hasSubmittedContent = true }
            let finalRevision = finalFrameWaiter == nil ? nil : finalFrameRevision
            let report = onFrame
            let reportCompletion = onFrameCompleted
            let observesPresentation = report != nil || finalRevision != nil
            let presentation: Presentation? = (observesPresentation || reportCompletion != nil) ?
                Presentation(cpu: submitted - started, shaderCompile: first ? firstCompilation : nil,
                             firstFrame: first ? submitted - firstContentStart : nil, submitted: submitted, received: received,
                             generation: snapshot?.generation ?? 0, uploads: frame.glyphUploads,
                             rows: frame.rowsPrepared) { [weak self] frame in
                    report?(frame)
                    if let self, let finalRevision, self.finalFrameRevision == finalRevision {
                        if frame.gpuCompleted { self.finishFinalFrame() }
                        else { self.invalidateFrame() }
                    }
                } : nil
            #if targetEnvironment(simulator)
            // The Simulator SDK exposes no drawable presentation handler or timestamp.
            presentation?.presentationKnown = true
            #else
            if observesPresentation, let presentation {
                drawable.addPresentedHandler { output in
                    let time = output.presentedTime
                    Task { @MainActor in
                        presentation.presented = time > 0 ? time : nil
                        presentation.presentationKnown = true
                        presentation.resolve()
                    }
                }
            }
            #endif
            frame.buffer.addCompletedHandler { [weak self] command in
                let gpu = command.gpuEndTime - command.gpuStartTime
                let completed = command.status == .completed
                Task { @MainActor in
                    if let presentation {
                        presentation.gpu = gpu > 0 ? gpu : nil
                        presentation.gpuCompleted = completed
                        presentation.completed = true
                        reportCompletion?(presentation.measurement)
                        if !completed { presentation.presentationKnown = true }
                        presentation.resolve()
                    }
                    if let self {
                        self.inFlight -= 1
                        if self.dirty { self.invalidateFrame() }
                    }
                }
            }
            dirty = false
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
            frame.buffer.present(drawable)
            frame.buffer.commit()
        } catch {
            renderer.discardResources()
            NSLog("Thrush Metal frame failed: %@", String(describing: error))
        }
    }
}
