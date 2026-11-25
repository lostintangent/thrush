import Thrush

var terminal = Terminal(size: .init(columns: 80, rows: 24))
let prompt = "thrush$ "
let reply = terminal.receive("\(prompt)\u{1b}[6n".utf8)
let row = terminal.text(inRow: 0)
guard row == prompt, reply == Array("\u{1b}[1;9R".utf8) else {
    fatalError("Prompt checkpoint failed. Row \(row.debugDescription), reply bytes \(reply)")
}

print("row[0] = \(row.debugDescription)")
print("reply = \(String(decoding: reply, as: UTF8.self).debugDescription)")
