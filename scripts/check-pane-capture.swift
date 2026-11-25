// Independent check that the simulator framebuffer contains the visible copy of its native notice.
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

let recognition = VNRecognizeTextRequest()
recognition.recognitionLevel = .accurate
recognition.recognitionLanguages = ["en-US"]
recognition.usesLanguageCorrection = false
try VNImageRequestHandler(url: URL(fileURLWithPath: image)).perform([recognition])
let recognized = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
let visible = words(recognized.joined(separator: " "))
for expected in arguments.dropFirst() where !visible.contains(words(expected)) {
    FileHandle.standardError.write(Data("Missing \(expected.debugDescription) in framebuffer text \(recognized).\n".utf8))
    exit(1)
}
