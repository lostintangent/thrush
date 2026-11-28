import CoreGraphics
import ThrushCore

extension TerminalMetalView {
    var historyCount: Int { viewport.historyCount }
    package var historyOffset: Int { viewport.offset }
    var isPointerReporting: Bool { inputAvailability == .live && historyOffset == 0 && snapshot.map { $0.modes.mouseTracking != .off } == true }
    /// Wheels, trackpads and iPhone swipes scroll the program instead of history.
    var programTakesScrolling: Bool { inputAvailability == .live && historyOffset == 0 && snapshot?.programTakesScrolling == true }
    var selectedText: String? { selection.map { viewport.text(in: $0) } }
    /// VoiceOver reads what a sighted reader sees, so concealed text is blank. Copy keeps it.
    var spokenSelectedText: String? { selection.map { viewport.text(in: $0, spoken: true) } }
    func text(in selection: Selection, spoken: Bool = false) -> String { viewport.text(in: selection, spoken: spoken) }

    func selectWord(row: Int, column: Int) {
        updateSelection { $0.selectWord(row: row, column: column) }
    }

    func spokenLineText(row: Int) -> String {
        var reader = viewport
        reader.selectLine(row: row)
        return reader.selection.map { reader.text(in: $0, spoken: true) } ?? ""
    }

    func selectLine(row: Int) {
        updateSelection { $0.selectLine(row: row) }
    }

    func sendInput(_ input: Terminal.Input) {
        guard acceptsTerminalInput else { return }
        setHistoryOffset(0)
        selection = nil
        onInput?(input)
    }

    /// All native input surfaces use top-left-origin points and the renderer's snapped cell edges.
    func cellRect(row: Int, column: Int) -> CGRect {
        guard let m = metrics else { return .zero }
        return CGRect(x: CGFloat(m.x(column)) / m.scale, y: CGFloat(m.y(row)) / m.scale,
                      width: CGFloat(m.x(column + 1) - m.x(column)) / m.scale,
                      height: CGFloat(m.rowHeightPixels) / m.scale)
    }

    func cell(at point: CGPoint) -> (row: Int, column: Int)? {
        guard let m = metrics, let snapshot else { return nil }
        let y = Int(floor((point.y * m.scale - CGFloat(m.y(0))) / CGFloat(m.rowHeightPixels)))
        let x = point.x * m.scale
        // Rounded boundaries can fall either side of the nominal advance.
        var col = max(0, min(snapshot.size.columns - 1, Int(floor((x - CGFloat(m.x(0))) / m.advancePixels))))
        if col + 1 < snapshot.size.columns, x >= CGFloat(m.x(col + 1)) { col += 1 }
        else if col > 0, x < CGFloat(m.x(col)) { col -= 1 }
        return (min(max(y, 0), snapshot.size.rows - 1), col)
    }

    var cursorRect: CGRect {
        guard let snapshot, (0..<snapshot.size.rows).contains(snapshot.cursorRow) else { return .zero }
        return cellRect(row: snapshot.cursorRow, column: min(snapshot.size.columns - 1, snapshot.cursorColumn))
    }
}
