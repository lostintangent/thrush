import Foundation
import SwiftParser
import SwiftSyntax

struct Item: Decodable {}
struct Manifest: Decodable {
    struct Target: Decodable {
        let name: String
        let dependencies: [Item]
        let resources: [Item]
        let pluginUsages: [Item]?
    }
    struct Product: Decodable {
        let name: String
        let targets: [String]
    }
    let targets: [Target]
    let products: [Product]
}
struct Description: Decodable {
    struct Target: Decodable {
        let name: String
        let path: String
        let sources: [String]
    }
    let targets: [Target]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func readPackage<T: Decodable>(_ arguments: [String], as type: T.Type) throws -> T {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
    process.arguments = ["package"] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("SwiftPM could not inspect the package.") }
    return try JSONDecoder().decode(type, from: data)
}

final class Imports: SyntaxVisitor {
    var declarations: [ImportDeclSyntax] = []
    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        declarations.append(node)
        return .skipChildren
    }
}

let manifest = try readPackage(["dump-package"], as: Manifest.self)
guard manifest.products.first(where: { $0.name == "Thrush" })?.targets == ["Thrush"],
      let core = manifest.targets.first(where: { $0.name == "Thrush" }),
      core.dependencies.isEmpty, core.resources.isEmpty, core.pluginUsages?.isEmpty != false
else { fail("The Thrush product must contain only the dependency-free, resource-free core.") }

let description = try readPackage(["describe", "--type", "json"], as: Description.self)
guard let target = description.targets.first(where: { $0.name == "Thrush" }), !target.sources.isEmpty
else { fail("SwiftPM did not list the Thrush sources.") }
for source in target.sources {
    let path = "\(target.path)/\(source)"
    guard path.hasSuffix(".swift") else { fail("Unexpected non-Swift source in the core: \(path)") }
    let tree = Parser.parse(source: try String(contentsOfFile: path, encoding: .utf8))
    let imports = Imports(viewMode: .sourceAccurate)
    imports.walk(tree)
    if let declaration = imports.declarations.first {
        let location = declaration.startLocation(converter: SourceLocationConverter(fileName: path, tree: tree))
        fail("\(path):\(location.line): unexpected core import: \(declaration.path.trimmedDescription)")
    }
}
print("Thrush has zero imports across \(target.sources.count) Swift sources and zero target dependencies.")
