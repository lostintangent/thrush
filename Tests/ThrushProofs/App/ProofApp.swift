import SwiftUI
import Thrush

/// The sample's app, with the proofs' probe above its window. Each proof host mounts the public view as an app would.
@main
struct ProofApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var delegate: ProofDelegate
    #else
    @UIApplicationDelegateAdaptor private var delegate: ProofDelegate
    #endif

    var body: some Scene {
        WindowGroup { ProofWindow(proof: .shared) }
            .defaultSize(width: 720, height: 494)
            #if os(macOS)
            .windowToolbarStyle(.unifiedCompact)
            #endif
    }
}

struct ProofWindow: View {
    @ObservedObject var proof: Proof
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some View {
        host
            .environment(\.terminalProbe, proof.probe)
            #if os(iOS)
            .preferredColorScheme(proof.options.appearance.colorScheme)
            .onChange(of: scenePhase, initial: true) { _, phase in proof.sceneChanged(to: phase) }
            #endif
            .task { await proof.attend() }
    }

    @ViewBuilder private var host: some View {
        let options = proof.options
        if options.benchmarkURL != nil {
            RendererSurface(view: proof.view)
        } else if options.checksToolbar {
            #if os(macOS)
            MacToolbarProof(ignoresSafeArea: options.hostIgnoresSafeArea, split: options.splitsToolbar)
                .toolbarBackgroundVisibility(options.showsToolbarBackground ? .visible : .automatic, for: .windowToolbar)
            #else
            PhoneToolbarProof(ignoresSafeArea: options.hostIgnoresSafeArea)
            #endif
        } else if options.cyclesAppearance {
            ThemedWindow(theme: proof.theme)
        } else {
            ShellWindow()
        }
    }
}

/// The sample's window with a theme the appearance cycle sets.
private struct ThemedWindow: View {
    let theme: TerminalTheme?
    @StateObject private var model = WindowModel()

    var body: some View {
        NavigationStack {
            TerminalView(model.tab.session, theme: theme).navigationTitle("Terminal")
        }
    }
}

/// The render benchmark mounts the Metal view without a session.
#if os(macOS)
private struct RendererSurface: NSViewRepresentable {
    let view: TerminalMetalView
    func makeNSView(context: Context) -> TerminalMetalView { view }
    func updateNSView(_ view: TerminalMetalView, context: Context) {}
}
#else
private struct RendererSurface: UIViewRepresentable {
    let view: TerminalMetalView
    func makeUIView(context: Context) -> TerminalMetalView { view }
    func updateUIView(_ view: TerminalMetalView, context: Context) {}
}
#endif

#if os(macOS)
@MainActor final class ProofDelegate: NSObject, NSApplicationDelegate {
    private let proof = Proof.shared
    private var appearanceSignal: DispatchSourceSignal?
    private var laterAppearances = ["light", "custom"][...]

    func applicationWillFinishLaunching(_ notification: Notification) {
        // SwiftUI restores the frame a previous run left, so each proof starts from the sample's default window.
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        // The proofs pass paths as arguments, which AppKit would otherwise open as documents in place of the window.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": false])
        NSWindow.allowsAutomaticWindowTabbing = false
        setAppearance(proof.options.cyclesAppearance ? .dark : proof.options.appearance)
        if proof.options.cyclesAppearance { proof.onFirstOutput = { [weak self] in self?.cycleAppearance() } }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        proof.setRendering(true)
    }

    // Connected terminal views observe their window's visibility themselves and keep their shells attached while hidden.
    func applicationWillHide(_ notification: Notification) { proof.setRendering(false) }
    func applicationDidUnhide(_ notification: Notification) { proof.setRendering(true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Reports dark, then steps to light and a custom theme at each SIGUSR1 while the terminal stays attached.
    /// The capture runner sends each signal once it has checked the step before, and listens for each step on stdout.
    private func cycleAppearance() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.nextAppearance() }
        }
        source.activate()
        appearanceSignal = source
        report(appearance: "dark")
    }

    private func nextAppearance() {
        guard let step = laterAppearances.popFirst() else { return }
        setAppearance(step == "light" ? .light : .dark)
        proof.theme = step == "custom" ? Proof.customTheme : nil
        report(appearance: step)
    }

    private func report(appearance step: String) {
        FileHandle.standardOutput.write(Data("appearance=\(step)\n".utf8))
    }

    private func setAppearance(_ appearance: ProofOptions.Appearance) {
        NSApp.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
#else
@MainActor final class ProofDelegate: NSObject, UIApplicationDelegate {
    // The proof's Metal view asks UIKit for its scene's text effects window, and making that window
    // inside the window group evaluates the group again. So the proof starts before any scene connects.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = Proof.shared
        return true
    }
}
#endif
