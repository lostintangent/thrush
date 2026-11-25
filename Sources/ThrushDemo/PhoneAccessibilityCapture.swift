#if os(iOS)
import ThrushUI
import UIKit

/// In-process observations for the explicit simulator VoiceOver proof on the notice peer.
@MainActor final class PhoneAccessibilityCapture: NSObject {
    private struct Event: Encodable {
        let time: Double, kind: String
        let voiceOverRunning, reduceMotion, reduceTransparency: Bool
        let contentSize: String
        let focusedLabel, changedFocus, announcement: String?
        let announcementSuccessful: Bool?
    }

    private struct Report: Encodable {
        let events: [Event]
        let mounted: [PhoneCapture.State]
        let visibleRows: [String]
    }

    private weak var view: TerminalView?
    private let destination: URL
    private var events = [Event]()
    private var mounted = [PhoneCapture.State]()
    private var visibleRows = [String]()

    init?(scene: DemoOptions.Scene, view: TerminalView) {
        guard CommandLine.arguments.contains("--capture-accessibility"), scene.capturesNotice else { return nil }
        self.view = view
        destination = URL.documentsDirectory.appending(path: "accessibility-" + scene.rawValue + ".json")
        super.init()
        for name in [UIAccessibility.elementFocusedNotification, UIAccessibility.announcementDidFinishNotification,
                     UIAccessibility.voiceOverStatusDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(received(_:)), name: name, object: nil)
        }
        record("launch")
    }

    func observe(_ state: PhoneCapture.State) {
        // Keep transition data until a matching completed drawable is available, even if the app is relaunched.
        if mounted.contains(where: {
            $0.notice?.title == state.notice?.title && $0.gpuCompleted == state.gpuCompleted
                && $0.generation == state.generation && $0.columns == state.columns && $0.rows == state.rows
        }) { return }
        mounted.append(state)
        visibleRows = view?.snapshot?.rows.map(\.text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? []
        record("layout")
    }

    @objc private func received(_ notification: Notification) {
        let info = notification.userInfo
        let focused = info?[UIAccessibility.focusedElementUserInfoKey] as? NSObject
        let announcement = info?[UIAccessibility.announcementStringValueUserInfoKey] as? String
        let successful = info?[UIAccessibility.announcementWasSuccessfulUserInfoKey] as? Bool
        record(notification.name.rawValue, changedFocus: focused?.accessibilityLabel,
               announcement: announcement, successful: successful)
    }

    private func record(_ kind: String, changedFocus: String? = nil, announcement: String? = nil, successful: Bool? = nil) {
        let focused = UIAccessibility.focusedElement(using: .notificationVoiceOver) as? NSObject
        events.append(Event(time: Date().timeIntervalSince1970, kind: kind,
                            voiceOverRunning: UIAccessibility.isVoiceOverRunning,
                            reduceMotion: UIAccessibility.isReduceMotionEnabled,
                            reduceTransparency: UIAccessibility.isReduceTransparencyEnabled,
                            contentSize: UIApplication.shared.preferredContentSizeCategory.rawValue,
                            focusedLabel: focused?.accessibilityLabel, changedFocus: changedFocus,
                            announcement: announcement, announcementSuccessful: successful))
        do {
            try JSONEncoder().encode(Report(events: events, mounted: mounted, visibleRows: visibleRows))
                .write(to: destination, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Could not write simulator accessibility observations: \(error)\n".utf8))
        }
    }
}
#endif
