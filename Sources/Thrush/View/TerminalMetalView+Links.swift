import Foundation
import ThrushCore

extension Terminal.Link {
    /// Where a link goes, decided from its URI alone, since its text can say anything.
    enum Destination: Equatable {
        /// An `http` or `https` page, which a click or tap opens.
        case web(URL)
        /// Any other scheme, such as `mailto`, `ssh` or an app's own. It can launch an app, so a click
        /// or tap shows the link's menu first.
        case app(URL)
        /// A path on the machine the program ran on, which is often not this device. The system would
        /// resolve the path here whatever the host, so Thrush offers it to copy and never opens it.
        case file(path: String)
        /// A `javascript` or `data` URI, or one that doesn't parse, which Thrush only copies.
        case inert
    }

    var destination: Destination {
        guard let url = URL(string: uri), let scheme = url.scheme?.lowercased() else { return .inert }
        switch scheme {
        case "http", "https":
            return url.host()?.isEmpty == false ? .web(url) : .inert
        case "file":
            let path = url.path(percentEncoded: false)
            return path.isEmpty ? .inert : .file(path: path)
        case "javascript", "data":
            return .inert
        default:
            return .app(url)
        }
    }

    /// The URL that Open Link opens, or `nil` when Thrush won't open the link.
    var openableURL: URL? {
        switch destination {
        case .web(let url), .app(let url): url
        case .file, .inert: nil
        }
    }

    /// What Copy Link puts on the pasteboard, or for a file link, what Copy Path does.
    var copiedText: String {
        if case .file(let path) = destination { return path }
        return uri
    }

    var copyTitle: String {
        if case .file = destination { return "Copy Path" }
        return "Copy Link"
    }

    /// The destination as menus, tooltips and VoiceOver show it. A parsed URI shows percent escapes for
    /// anything outside ASCII, so direction overrides and lookalike letters can't disguise it, and a long
    /// one keeps its start and end.
    var displayedDestination: String {
        let text = URL(string: uri)?.absoluteString ?? String(String.UnicodeScalarView(uri.unicodeScalars.filter {
            $0.properties.generalCategory != .format && $0.properties.generalCategory != .control
        }))
        let limit = 160
        guard text.count > limit else { return text }
        return "\(text.prefix(limit * 2 / 3))…\(text.suffix(limit / 3))"
    }
}

/// A link's text on one row of the viewport.
struct LinkRun: Equatable {
    let number: UInt32
    let row: Int
    let columns: Range<Int>
}

extension TerminalMetalView {
    /// A link the reader is about to open: under the pointer with ⌘ held, or pressed.
    struct EngagedLink: Equatable {
        /// The link's number in the snapshot, which every cell of the link carries in its style.
        let number: UInt32
        /// Whether a finger or a ⌘-click holds the link down.
        let pressed: Bool
    }

    /// The link whose text is under `point`. Unlike ``cell(at:)``, the point must be inside a cell of
    /// the link, so the space beside a link and the margins around the grid aren't part of it.
    func link(at point: CGPoint) -> (number: UInt32, link: Terminal.Link)? {
        guard let (row, column) = cell(at: point), cellRect(row: row, column: column).contains(point) else { return nil }
        return link(row: row, column: column)
    }

    func link(row: Int, column: Int) -> (number: UInt32, link: Terminal.Link)? {
        guard let snapshot, snapshot.rows.indices.contains(row), (0..<snapshot.size.columns).contains(column) else {
            return nil
        }
        let style = snapshot.rows[row][column].style
        if let link = snapshot.link(for: style) { return (style.link, link) }
        return foundLinks.first { $0.runs.contains { $0.row == row && $0.columns.contains(column) } }
            .map { ($0.number, $0.link) }
    }

    /// The URLs found in the viewport's plain text, read the first time something asks after it changes.
    var foundLinks: [LinkFinder.Found] {
        if let found { return found }
        guard let source = viewport.source, let snapshot else { return [] }
        let links = finder.find(in: source, top: source.history.count - viewport.offset, count: snapshot.rows.count)
        found = links
        return links
    }

    /// What each row of `drawn` shows of the links its cells' styles don't name: the addresses found in
    /// its text, and the engaged link's columns. `drawn` holds the viewport and any rows held around it.
    func drawnLinks(in drawn: Terminal.Snapshot) -> [RowLinks] {
        var links = Array(repeating: RowLinks(), count: drawn.rows.count)
        var found = foundLinks
        #if os(iOS)
        if heldRowsAround > 0, let source = viewport.source {
            // The held rows read on from the same lines, so the viewport's links keep their numbers.
            let top = source.history.count - min(max(0, viewport.offset), source.history.count) - heldRowsAround
            let first = max(0, top)
            found = finder.find(in: source, top: first, count: drawn.rows.count - (first - top)).map { link in
                LinkFinder.Found(number: link.number, link: link.link, runs: link.runs.map {
                    LinkRun(number: $0.number, row: $0.row + first - top, columns: $0.columns)
                })
            }
        }
        #endif
        let engaged = engagedLink
        for link in found {
            for run in link.runs where links.indices.contains(run.row) {
                links[run.row].found.append(run.columns)
                if link.number == engaged?.number { links[run.row].engaged.append(run.columns) }
            }
        }
        guard let engaged else { return links }
        if !LinkFinder.isFound(engaged.number) {
            for (y, row) in drawn.rows.enumerated() {
                let end = row.trimmedLength
                var x = 0
                while x < end {
                    var next = x + 1
                    while next < end, row[next].style.link == row[x].style.link { next += 1 }
                    if row[x].style.link == engaged.number { links[y].engaged.append(x..<next) }
                    x = next
                }
            }
        }
        for y in links.indices where !links[y].engaged.isEmpty { links[y].pressed = engaged.pressed }
        return links
    }

    /// The visible runs of linked text, top to bottom and left to right, or only the runs of `number`.
    /// A link a program wraps or redraws across rows with one id has one number, so it has a run on each row,
    /// and so does a URL found across soft-wrapped rows.
    func linkRuns(of number: UInt32? = nil) -> [LinkRun] {
        if let number, LinkFinder.isFound(number) { return foundLinks.first { $0.number == number }?.runs ?? [] }
        guard let snapshot else { return [] }
        var runs: [LinkRun] = []
        for (y, row) in snapshot.rows.enumerated() {
            let end = row.trimmedLength
            var x = 0
            while x < end {
                let style = row[x].style
                var next = x + 1
                while next < end, row[next].style.link == style.link { next += 1 }
                if style.link != 0, number == nil || number == style.link, snapshot.link(for: style) != nil {
                    runs.append(LinkRun(number: style.link, row: y, columns: x..<next))
                }
                x = next
            }
        }
        guard number == nil, !foundLinks.isEmpty else { return runs }
        return (runs + foundLinks.flatMap(\.runs)).sorted { ($0.row, $0.columns.lowerBound) < ($1.row, $1.columns.lowerBound) }
    }

    /// Each visible link once, in reading order of its first run, with all of its runs.
    func visibleLinks() -> [(number: UInt32, link: Terminal.Link, runs: [LinkRun])] {
        var links: [(number: UInt32, link: Terminal.Link, runs: [LinkRun])] = []
        var index: [UInt32: Int] = [:]
        for run in linkRuns() {
            if let at = index[run.number] {
                links[at].runs.append(run)
            } else if let link = link(row: run.row, column: run.columns.lowerBound)?.link {
                index[run.number] = links.count
                links.append((run.number, link, [run]))
            }
        }
        return links
    }

    /// The text a link shows across its visible runs, with a space where it continues on another row.
    func linkText(_ runs: [LinkRun]) -> String {
        guard let snapshot else { return "" }
        var text = ""
        for (index, run) in runs.enumerated() {
            let row = snapshot.rows[run.row]
            if index > 0 {
                let previous = runs[index - 1]
                let wraps = row.isWrapped && run.row == previous.row + 1 && run.columns.lowerBound == 0
                if !wraps { text.append(" ") }
            }
            var column = run.columns.lowerBound
            while column < run.columns.upperBound {
                let cell = row[column]
                text.append(cell.text(spoken: true))
                column += max(1, cell.width)
            }
        }
        return text
    }

    /// The rect a run's cells cover, in the view's top-left-origin points.
    func rect(of run: LinkRun) -> CGRect {
        cellRect(row: run.row, column: run.columns.lowerBound)
            .union(cellRect(row: run.row, column: run.columns.upperBound - 1))
    }

    /// Opens a web link through ``openURL`` and returns true. Other destinations return false, so the
    /// caller shows the link's menu first.
    func openWebLink(_ link: Terminal.Link) -> Bool {
        guard case .web(let url) = link.destination else { return false }
        openURL(url)
        return true
    }
}
