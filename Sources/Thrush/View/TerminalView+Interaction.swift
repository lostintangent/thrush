import CoreGraphics
import ThrushCore

extension TerminalView {
    var historyCount: Int { transcript.historyCount }
    package var historyOffset: Int { transcript.offset }
    var isPointerReporting: Bool { inputAvailability == .live && historyOffset == 0 && snapshot.map { $0.mouseTracking != .off } == true }
    var selectedText: String? { selection.map { transcript.text(in: $0) } }
    func text(in selection: Selection) -> String { transcript.text(in: selection) }

    func selectWord(row: Int, column: Int) {
        updateSelection { $0.selectWord(row: row, column: column) }
    }

    func logicalLineText(row: Int) -> String {
        var reader = transcript
        reader.selectLine(row: row)
        return reader.selection.map { reader.text(in: $0) } ?? ""
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
