import Foundation
import ThrushPTY

@main
enum ThrushServerMain {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("ThrushServer: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let command = CommandLine.arguments
        if command.count == 3, command[1] == "--pty-child" { exit(thrush_run_child(command[2])) }
        var port: UInt16 = 9138
        var shell = "/bin/zsh"
        var dataDirectory: URL?
        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        let usage = "Usage: swift run ThrushServer [--port PORT] [--shell EXECUTABLE] [--data-dir EMPTY_DIRECTORY]"
        while let option = arguments.next() {
            if option == "--help" { print(usage); return }
            guard let value = arguments.next() else { throw ServerOptionError(usage) }
            switch option {
            case "--port":
                guard let number = UInt16(value) else { throw ServerOptionError(usage) }
                port = number
            case "--shell": shell = URL(filePath: value).standardizedFileURL.path
            case "--data-dir": dataDirectory = URL(filePath: value).standardizedFileURL
            default: throw ServerOptionError(usage)
            }
        }

        let files = FileManager.default
        guard files.isExecutableFile(atPath: shell) else { throw ServerOptionError("Shell is not executable: \(shell)") }
        let data = dataDirectory ?? files.temporaryDirectory.appending(path: "thrush-" + UUID().uuidString)
        let permissions: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try files.createDirectory(at: data, withIntermediateDirectories: true, attributes: permissions)
        guard try files.contentsOfDirectory(atPath: data.path).isEmpty else {
            throw ServerOptionError("The data directory must be empty: \(data.path)")
        }
        defer { if dataDirectory == nil { try? files.removeItem(at: data) } }
        let source = try JSONSerialization.data(withJSONObject: ["server": "ThrushServer", "protocol": 1], options: [.prettyPrinted])
        try source.write(to: data.appending(path: "source.json"), options: .withoutOverwriting)
        for name in ["work", "home", "tmp"] {
            try files.createDirectory(at: data.appending(path: name), withIntermediateDirectories: false, attributes: permissions)
        }
        let home = data.appending(path: "home").path
        let environment = [
            "HOME": home, "CFFIXED_USER_HOME": home, "TMPDIR": data.appending(path: "tmp").path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": shell, "LC_ALL": "en_US.UTF-8",
            "TERM": "xterm-256color", "COLORTERM": "truecolor",
        ]
        print("Shell directory: \(data.appending(path: "work").path)")
        try startServer(port: port, shell: shell, directory: data.appending(path: "work"), environment: environment)
    }
}

private struct ServerOptionError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
