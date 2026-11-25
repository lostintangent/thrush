import Foundation

/// Presentation needs a real window and drawable. Launch the same packaged, shader-bearing
/// executable that a user opens and inherit its table and error output.
func runPackagedRenderer(arguments: [String]) throws {
    guard arguments.count == 2 || (arguments.count == 4 && arguments[2] == "--output") else {
        throw BenchmarkError("Usage: ThrushBench --render MAC_APP [--output PATH]")
    }
    let app = URL(fileURLWithPath: arguments[1], isDirectory: true)
    guard let executable = Bundle(url: app)?.executableURL else {
        throw BenchmarkError("No executable in \(app.path). Build the Mac demo with scripts/build-demo.sh mac.")
    }
    let output = URL(fileURLWithPath: arguments.count == 4 ? arguments[3] : ".build/benchmarks/render.json")
    let host = Process()
    host.executableURL = executable
    host.arguments = ["--benchmark", output.path, "--lifecycle-check"]
    try host.run()
    let deadline = ContinuousClock.now + .seconds(150)
    while host.isRunning && ContinuousClock.now < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    if host.isRunning {
        host.terminate()
        throw BenchmarkError("Packaged renderer did not finish in 150 seconds.")
    }
    guard host.terminationReason == .exit, host.terminationStatus == 0,
          FileManager.default.fileExists(atPath: output.path) else {
        throw BenchmarkError("Packaged renderer failed with status \(host.terminationStatus).")
    }
}
