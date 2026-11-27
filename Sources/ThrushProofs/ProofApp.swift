import SwiftUI
import Thrush

/// The sample's app, with the proofs' probe above its window. Each proof host mounts the public view as an app would.
@main
struct ProofApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var delegate: ProofDelegate
    #endif

    var body: some Scene {
        WindowGroup { ProofWindow(proof: .shared) }
            .defaultSize(width: 720, height: 454)
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

    func applicationWillFinishLaunching(_ notification: Notification) {
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

    /// Steps through dark, light and a custom theme 4 s apart while the terminal stays attached.
    /// The capture runners listen for each step on stdout.
    private func cycleAppearance() {
        Task {
            for step in ["dark", "light", "custom"] {
                if step != "dark" { try? await Task.sleep(for: .seconds(4)) }
                setAppearance(step == "light" ? .light : .dark)
                proof.theme = step == "custom" ? Proof.customTheme : nil
                FileHandle.standardOutput.write(Data("appearance=\(step)\n".utf8))
            }
        }
    }

    private func setAppearance(_ appearance: ProofOptions.Appearance) {
        NSApp.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
#endif
