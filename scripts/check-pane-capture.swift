// Independent check that the simulator framebuffer contains the visible copy of its native notice.
import CoreML
import Foundation
import Vision

let arguments = Array(CommandLine.arguments.dropFirst())
guard let image = arguments.first, arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Usage: check-pane-capture IMAGE EXPECTED_VISIBLE_STRINGS…\n".utf8))
    exit(2)
}

func words(_ text: String) -> String {
    text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
}

let expected = arguments.dropFirst().map(words)
let url = URL(fileURLWithPath: image)
var attempts: [String] = []
for level in [VNRequestTextRecognitionLevel.fast, .accurate] {
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLevel = level
    recognition.recognitionLanguages = ["en-US"]
    recognition.usesLanguageCorrection = false
    do {
        // Hosted Mac VMs can render an iPhone framebuffer without supporting
        // the accelerator selected by Vision's accurate recognition model.
        if level == .fast {
            for (stage, devices) in try recognition.supportedComputeStageDevices {
                if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                    recognition.setComputeDevice(cpu, for: stage)
                }
            }
        }
        try VNImageRequestHandler(url: url).perform([recognition])
        let lines = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = words(lines.joined(separator: " "))
        if expected.allSatisfy({ text.contains($0) }) { exit(0) }
        attempts.append("Read " + lines.joined(separator: " | "))
    } catch {
        attempts.append("Vision: " + String(describing: error))
    }
}
FileHandle.standardError.write(Data(("Expected " + expected.joined(separator: " | ") + ". "
                                    + attempts.joined(separator: "\n") + "\n").utf8))
exit(1)
