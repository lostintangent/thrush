// Format the current shell prompt.
struct Prompt {
    let path: String
    let isRoot: Bool
    let width = 24

    var text: String {
        let cwd = path.suffix(width)
        let mark = isRoot ? "#" : "$"
        return "\(cwd) \(mark) "
    }
}
