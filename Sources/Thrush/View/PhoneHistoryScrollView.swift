#if os(iOS)
import ThrushCore
import UIKit

/// The scroll view supplies UIKit's pan velocity, deceleration, scroll indicator and VoiceOver
/// paging. Metal draws only the current rows, so a full history needs no offscreen views.
/// When the program takes scrolling, swipes and trackpad scrolls go to it as rows instead.
final class PhoneHistoryScrollView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    unowned let terminal: TerminalMetalView
    private let scroll = UIScrollView()
    private let latest = UIButton(type: .system)
    private lazy var latestBottom = latest.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
    private lazy var selectionControls = PhoneSelectionControls(scrollView: self)
    private var syncing = false
    private var rowHeight: CGFloat = 18
    private var lastTheme: TerminalTheme?
    private var reducedTransparency: Bool?
    private var pressAnchor: TerminalMetalView.Selection?
    private var pointerAnchor: (row: Int, column: Int)?
    private var pointerButton = Terminal.Input.Pointer.Button.left
    private var remotePress = false
    private var displacedPointerClick = false
    private lazy var reclaimClick = UITapGestureRecognizer(target: self, action: #selector(tappedDisplacedPointer))
    private let doubleClick = UITapGestureRecognizer()
    private var lastPointerCell: (row: Int, column: Int)?
    private weak var wheelGesture: UIPanGestureRecognizer?
    /// Where the endless scroll view rests while a program takes scrolling, or nil while it holds history.
    private var programOffset: CGFloat?
    private var programRemainder: CGFloat = 0
    private var programCell: (row: Int, column: Int)?
    private var programModifiers: Terminal.Input.Modifiers = []
    private var pageSentToProgram: (generation: UInt64, deadline: CFTimeInterval)?
    private let reading = PhoneAccessibleText()
    private var panStart: CGFloat = 0
    /// UIKit's measure of the last pan as the finger lifted: seconds since 1970, the points the content moved
    /// under the finger, and the velocity in points per second that UIKit's deceleration glides on from.
    private(set) var lastRelease: (time: Double, travel: CGFloat, velocity: CGFloat)?

    init(terminal: TerminalMetalView) {
        self.terminal = terminal
        super.init(frame: terminal.bounds)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        clipsToBounds = true
        scroll.frame = bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsHorizontalScrollIndicator = false
        scroll.allowsKeyboardScrolling = false
        scroll.scrollsToTop = false
        scroll.bounces = false
        scroll.isAccessibilityElement = false
        scroll.delegate = self
        // A primary-button drag selects. Trackpad and wheel scrolling reach UIScrollView
        // through scroll events, independently of indirect button touches.
        scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addSubview(scroll)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        for recognizer in [tap, press] {
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                            NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            recognizer.delegate = self
            scroll.addGestureRecognizer(recognizer)
        }
        tap.require(toFail: press)

        let mouse = TerminalPointerGesture(target: self, action: #selector(pointer(_:)))
        mouse.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        scroll.addGestureRecognizer(mouse)
        // UIKit distinguishes a single trackpad click from multi-click word or line selection.
        doubleClick.numberOfTapsRequired = 2
        for click in [reclaimClick, doubleClick] {
            click.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            click.buttonMaskRequired = .primary
            click.cancelsTouchesInView = false
            click.delegate = self
            click.isEnabled = false
            scroll.addGestureRecognizer(click)
        }
        reclaimClick.require(toFail: doubleClick)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        scroll.addGestureRecognizer(hover)
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheeled(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        wheelGesture = wheel
        wheel.delegate = self
        scroll.addGestureRecognizer(wheel)
        scroll.panGestureRecognizer.require(toFail: wheel)

        latest.accessibilityLabel = "Latest"
        latest.accessibilityHint = "Returns to the live terminal."
        latest.accessibilityIdentifier = "terminal.latest"
        latest.addAction(UIAction { [weak self] _ in self?.returnToLatest() }, for: .touchUpInside)
        latest.translatesAutoresizingMaskIntoConstraints = false
        latest.isHidden = true
        addSubview(latest)
        NSLayoutConstraint.activate([
            latest.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            latestBottom,
            latest.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            latest.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        isAccessibilityElement = false
        NotificationCenter.default.addObserver(self, selector: #selector(accessibilitySettingsChanged),
                                               name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let native = super.hitTest(point, with: event) else { return nil }
        if native === latest || native.isDescendant(of: latest) { return native }
        return selectionControls.hitTarget(at: point) ?? native
    }

    @objc private func accessibilitySettingsChanged() { synchronize() }

    func synchronize() {
        let displaced = terminal.onDisplacedTap != nil
        if reclaimClick.isEnabled != displaced {
            reclaimClick.isEnabled = displaced
            doubleClick.isEnabled = displaced
            displacedPointerClick = false
        }
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        rowHeight = max(1, terminal.cellRect(row: 0, column: 0).height)
        if terminal.programTakesScrolling {
            // The program takes the scroll view's own pan and glide, so a flick there goes as far as one through history.
            let extent = CGSize(width: bounds.width, height: bounds.height + 2 * Self.endless)
            if scroll.contentSize != extent { scroll.contentSize = extent }
            let resting = !scroll.isTracking && !scroll.isDecelerating
            if programOffset == nil || resting && programOffset != Self.endless {
                programOffset = Self.endless
                scroll.setContentOffset(CGPoint(x: 0, y: Self.endless), animated: false)
            }
        } else {
            let count = terminal.historyCount
            let extent = CGSize(width: bounds.width, height: bounds.height + CGFloat(count) * rowHeight)
            if scroll.contentSize != extent { scroll.contentSize = extent }
            let target = CGPoint(x: 0, y: CGFloat(count - terminal.historyOffset) * rowHeight)
            if programOffset != nil {
                programOffset = nil
                scroll.setContentOffset(target, animated: false)
            } else if Int((scroll.contentOffset.y / rowHeight).rounded()) != count - terminal.historyOffset {
                scroll.contentOffset = target
            }
        }
        scroll.showsVerticalScrollIndicator = programOffset == nil
        latest.isHidden = terminal.historyOffset == 0 || terminal.snapshot?.isAlternate == true
        if lastTheme != terminal.resolvedTheme || reducedTransparency != UIAccessibility.isReduceTransparencyEnabled {
            lastTheme = terminal.resolvedTheme
            reducedTransparency = UIAccessibility.isReduceTransparencyEnabled
            styleLatest()
        }
        let indicator: UIScrollView.IndicatorStyle = terminal.color(.background).isDark ? .white : .black
        if scroll.indicatorStyle != indicator { scroll.indicatorStyle = indicator }
        selectionControls.update()
        layoutLatest()
        reading.invalidate()
        if let page = pageSentToProgram, terminal.snapshot?.generation != page.generation {
            pageSentToProgram = nil
            if CACurrentMediaTime() < page.deadline { readPage(firstLine) }
        }
    }

    private func styleLatest() {
        let theme = terminal.resolvedTheme
        let reduced = UIAccessibility.isReduceTransparencyEnabled
        var config: UIButton.Configuration = reduced ? .filled() : .glass()
        config.cornerStyle = .capsule
        config.title = "Latest"
        config.image = UIImage(systemName: "arrow.down")
        config.imagePadding = 5
        config.preferredSymbolConfigurationForImage = .init(textStyle: .footnote, scale: .small)
        if reduced {
            config.baseBackgroundColor = UIColor(terminalColor: theme.opaqueBacking)
            config.baseForegroundColor = UIColor(terminalColor: theme.palette.foreground)
            config.background.strokeColor = UIColor(terminalColor: theme.palette[index: 8])
            config.background.strokeWidth = 1 / max(1, traitCollection.displayScale)
        } else {
            config.baseForegroundColor = .label
        }
        latest.overrideUserInterfaceStyle = theme == .slateDark ? .dark : theme == .slateLight ? .light : .unspecified
        latest.configuration = config
    }

    func layoutLatest() {
        guard !latest.isHidden else { return }
        let protected = selectionControls.protectedRects
        let width = latest.bounds.width, height = latest.bounds.height
        let left = CGRect(x: 12, y: bounds.maxY + latestBottom.constant - height, width: width, height: height)
        let right = left.offsetBy(dx: bounds.width - 24 - width, dy: 0)
        let trailing = effectiveUserInterfaceLayoutDirection == .leftToRight ? right : left
        let leading = trailing == right ? left : right
        guard protected.contains(where: { $0.intersects(trailing) }) else {
            latest.transform = .identity
            return
        }
        var candidates = [leading]
        // A wrapped selection can put one handle in each bottom corner. First try
        // the two edges just above them and then the gaps beside them in a short viewport.
        for target in protected.sorted(by: { $0.minY > $1.minY }) {
            let rise = target.minY - 4 - trailing.maxY
            if rise < 0 {
                candidates.append(trailing.offsetBy(dx: 0, dy: rise))
                candidates.append(leading.offsetBy(dx: 0, dy: rise))
            }
        }
        for target in protected {
            candidates.append(trailing.offsetBy(dx: target.minX - 4 - trailing.maxX, dy: 0))
            candidates.append(trailing.offsetBy(dx: target.maxX + 4 - trailing.minX, dy: 0))
        }
        let destination = candidates.first { frame in
            frame.minX >= left.minX && frame.maxX <= right.maxX && frame.minY >= bounds.minY &&
                !protected.contains { $0.intersects(frame) }
        } ?? trailing
        latest.transform = CGAffineTransform(translationX: destination.minX - trailing.minX,
                                             y: destination.minY - trailing.minY)
    }

    /// A program scrolls where the pan began, as a wheel would there, from a whole row of travel.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        programRemainder = 0
        programCell = terminal.cell(at: scrollView.panGestureRecognizer.location(in: self)) ?? programCell
        programModifiers = terminalModifiers(scrollView.panGestureRecognizer.modifierFlags)
        panStart = scrollView.contentOffset.y
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        lastRelease = (Date.now.timeIntervalSince1970, scrollView.contentOffset.y - panStart, velocity.y * 1000)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // UIKit also adjusts contentOffset when the viewport or keyboard changes size.
        // Only a person's pan or its deceleration changes the terminal's reading position or scrolls the program.
        let byPerson = !syncing && (scrollView.isDragging || scrollView.isDecelerating)
        if let resting = programOffset {
            programOffset = scrollView.contentOffset.y
            if byPerson { scrollProgram(by: resting - scrollView.contentOffset.y, modifiers: programModifiers) }
            return
        }
        guard byPerson else { return }
        let first = Int((scrollView.contentOffset.y / rowHeight).rounded())
        let offset = min(terminal.historyCount, max(0, terminal.historyCount - first))
        if terminal.historyOffset != offset {
            terminal.setHistoryOffset(offset)
        }
    }

    private func returnToLatest() {
        // Jump directly after a long scroll. Readers shouldn't have to wait through hundreds
        // of rows before the prompt accepts their next gesture.
        scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(terminal.historyCount) * rowHeight), animated: false)
        terminal.setHistoryOffset(0)
        if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .pageScrolled, argument: "Latest output") }
    }

    func selectAccessibleLine(_ row: Int) {
        selectionControls.beginSelection()
        terminal.selectLine(row: row)
        UIAccessibility.post(notification: .layoutChanged,
                             argument: accessibilityElements?.compactMap { $0 as? UIAccessibilityElement }
                                 .first(where: { $0.accessibilityTraits.contains(.selected) }))
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let cell = terminal.cell(at: gesture.location(in: self))
        if let cell, !terminal.isPointerReporting, let range = terminal.selection, let width = terminal.snapshot?.size.columns,
           range.columns(in: cell.row, width: width)?.contains(cell.column) == true {
            selectionControls.beginSelection()
            selectionControls.showMenu()
            return
        }
        if gesture.modifierFlags.intersection([.shift, .alternate, .command, .control]).isEmpty,
           terminal.tapDisplacedGrid() { return }
        guard let cell else { return }
        selectionControls.dismissMenu()
        terminal.selection = nil
        _ = terminal.focusInput()
        if terminal.reportPointer(.press, button: .left, row: cell.row, column: cell.column) {
            _ = terminal.reportPointer(.release, button: .left, row: cell.row, column: cell.column)
        }
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard let cell = terminal.cell(at: point) else { return }
            selectionControls.beginSelection()
            terminal.selectWord(row: cell.row, column: cell.column)
            pressAnchor = terminal.selection
            UISelectionFeedbackGenerator(view: self).selectionChanged()
        case .changed:
            guard let range = pressAnchor, let cell = terminal.cell(at: point) else { return }
            let start = (range.anchorRow, range.anchorColumn)
            let end = (range.headRow, range.headColumn)
            if cell < start {
                terminal.selection = .init(anchorRow: end.0, anchorColumn: end.1, headRow: cell.row, headColumn: cell.column)
            } else if cell > end {
                terminal.selection = .init(anchorRow: start.0, anchorColumn: start.1, headRow: cell.row, headColumn: cell.column)
            } else {
                terminal.selection = range
            }
        case .ended:
            pressAnchor = nil
            selectionControls.showMenu()
        case .cancelled, .failed:
            pressAnchor = nil
        default: break
        }
    }

    @objc private func pointer(_ gesture: TerminalPointerGesture) {
        if gesture.state == .began {
            displacedPointerClick = terminal.onDisplacedTap != nil && gesture.clicks == 1 && gesture.pressedButton == .left
                && gesture.flags.intersection([.shift, .alternate, .command, .control]).isEmpty
        } else if gesture.state == .changed || gesture.state == .cancelled {
            displacedPointerClick = false
        }
        let point = gesture.location(in: self)
        let cell = terminal.cell(at: point) ?? lastPointerCell
        guard let cell else { return }
        let flags = gesture.flags
        let modifiers = terminalModifiers(flags)
        switch gesture.state {
        case .began:
            pointerButton = gesture.pressedButton
            lastPointerCell = cell
            remotePress = !flags.contains(.shift) && terminal.reportPointer(.press, button: pointerButton,
                row: cell.row, column: cell.column, modifiers: modifiers)
            if remotePress { _ = terminal.focusInput(); return }
            if pointerButton == .right {
                if terminal.selection == nil {
                    selectionControls.beginSelection()
                    terminal.selectWord(row: cell.row, column: cell.column)
                }
                selectionControls.showMenu()
            } else if pointerButton == .left {
                selectionControls.beginSelection()
                if gesture.clicks >= 3 {
                    terminal.selectLine(row: cell.row)
                } else if gesture.clicks == 2 {
                    terminal.selectWord(row: cell.row, column: cell.column)
                } else {
                    let prior = terminal.selection
                    pointerAnchor = flags.contains(.shift) ? prior.map { ($0.anchorRow, $0.anchorColumn) } ?? cell : cell
                    terminal.selection = nil
                    if !displacedPointerClick { _ = terminal.focusInput() }
                    if flags.contains(.shift) { extendPointer(to: cell) }
                }
            }
        case .changed:
            guard lastPointerCell?.row != cell.row || lastPointerCell?.column != cell.column else { return }
            lastPointerCell = cell
            if remotePress {
                _ = terminal.reportPointer(.move, button: pointerButton, row: cell.row, column: cell.column, modifiers: modifiers)
            } else if pointerButton == .left {
                extendPointer(to: cell)
            }
        case .ended, .cancelled:
            if remotePress {
                _ = terminal.reportPointer(.release, button: pointerButton, row: cell.row, column: cell.column, modifiers: modifiers)
            }
            pointerAnchor = nil
            remotePress = false
            lastPointerCell = nil
        default: break
        }
    }

    @objc private func tappedDisplacedPointer(_ tap: UITapGestureRecognizer) {
        if displacedPointerClick, tap.modifierFlags.intersection([.shift, .alternate, .command, .control]).isEmpty {
            terminal.tapDisplacedGrid()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other is TerminalPointerGesture && (gestureRecognizer === reclaimClick || gestureRecognizer === doubleClick)
    }

    private func extendPointer(to cell: (row: Int, column: Int)) {
        guard let anchor = pointerAnchor else { return }
        terminal.selection = .init(anchorRow: anchor.row, anchorColumn: anchor.column,
                                   headRow: cell.row, headColumn: cell.column)
    }

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .changed, !remotePress, terminal.isPointerReporting, !gesture.modifierFlags.contains(.shift),
              let cell = terminal.cell(at: gesture.location(in: self)) else { return }
        _ = terminal.reportPointer(.move, button: .none, row: cell.row, column: cell.column,
                                   modifiers: terminalModifiers(gesture.modifierFlags))
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === wheelGesture {
            return terminal.programTakesScrolling && !gestureRecognizer.modifierFlags.contains(.shift)
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// A touch that stops a glide only stops it, as in a native list, so it neither clicks nor selects.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer is UITapGestureRecognizer || gestureRecognizer is UILongPressGestureRecognizer,
              touch.type != .indirectPointer else { return true }
        return !scroll.isDecelerating
    }

    @objc private func wheeled(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            // Two fingers on the trackpad stop a glide, as they do in a list.
            if scroll.isDecelerating { scroll.setContentOffset(scroll.contentOffset, animated: false) }
            programRemainder = 0
        }
        programCell = terminal.cell(at: gesture.location(in: self)) ?? programCell
        scrollProgram(by: gesture.translation(in: self).y, modifiers: terminalModifiers(gesture.modifierFlags))
        gesture.setTranslation(.zero, in: self)
    }

    /// How far the scroll view reaches each way from where it rests while a program takes scrolling.
    private static let endless: CGFloat = 1_000_000

    /// Counts whole rows of travel, toward earlier output as the finger or trackpad moves down.
    /// Shift reaches history instead, as on the Mac, and then the scroll view holds history again.
    private func scrollProgram(by points: CGFloat, modifiers: Terminal.Input.Modifiers) {
        programRemainder += points
        let rows = Int(programRemainder / rowHeight)
        programRemainder -= CGFloat(rows) * rowHeight
        guard rows != 0, let cell = programCell else { return }
        guard !modifiers.contains(.shift) else {
            return terminal.setHistoryOffset(min(terminal.historyCount, max(0, terminal.historyOffset + rows)))
        }
        terminal.scrollProgram(rows: rows, row: cell.row, column: cell.column, modifiers: modifiers)
    }

    private func terminalModifiers(_ flags: UIKeyModifierFlags) -> Terminal.Input.Modifiers {
        var result: Terminal.Input.Modifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.alternate) { result.insert(.alt) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    override var accessibilityElements: [Any]? {
        get { reading.elements(in: self, latest: latest) }
        set { super.accessibilityElements = newValue }
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard direction == .up || direction == .down, let size = terminal.snapshot?.size else { return false }
        let page = max(1, size.rows - 1)
        // A full-screen program gets the page instead, and VoiceOver reads it once the program redraws.
        if terminal.programTakesScrolling {
            terminal.scrollProgram(rows: direction == .up ? page : -page, row: size.rows / 2, column: size.columns / 2)
            pageSentToProgram = (terminal.snapshot?.generation ?? 0, CACurrentMediaTime() + 2)
            return true
        }
        let target = direction == .up ? min(terminal.historyCount, terminal.historyOffset + page)
            : max(0, terminal.historyOffset - page)
        guard target != terminal.historyOffset else { return false }
        terminal.setHistoryOffset(target)
        readPage(target == 0 ? "Latest output" : firstLine)
        return true
    }

    private var firstLine: String? {
        terminal.snapshot?.rows.firstIndex { !$0.text.isEmpty }.map { terminal.spokenLineText(row: $0) }
    }

    private func readPage(_ text: String?) {
        UIAccessibility.post(notification: .pageScrolled, argument: text)
        if let text { terminal.onAccessibilityAnnouncement?(text) }
    }
}

private final class TerminalPointerGesture: UIGestureRecognizer {
    private(set) var pressedButton = Terminal.Input.Pointer.Button.left
    private(set) var flags: UIKeyModifierFlags = []
    private(set) var clicks = 1

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let touch = touches.first, touch.type == .indirectPointer else {
            state = .failed
            return
        }
        flags = event.modifierFlags
        clicks = touch.tapCount
        if event.buttonMask.contains(.secondary) { pressedButton = .right }
        else if event.buttonMask.contains(.button(3)) { pressedButton = .middle }
        else { pressedButton = .left }
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        flags = event.modifierFlags
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .ended }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
}
#endif
