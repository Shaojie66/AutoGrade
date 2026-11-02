import AppKit
import AutoGradeCore
import SwiftUI

@main
struct AutoGradeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var project = Project()

    var body: some Scene {
        Window(L(S.appName), id: "main") {
            MainWindow(project: project)
                .onAppear { OpenRequests.shared.attach(project) }
        }
        .commands { AppCommands(project: project) }

        Settings {
            SettingsView()
        }
    }
}

struct AppCommands: Commands {
    let project: Project

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L(S.open)) { project.openPanel() }.keyboardShortcut("o")
            Button(L(S.export)) { project.beginExport() }.keyboardShortcut("e").disabled(!project.canEdit)
        }
        CommandMenu(L(S.playback)) {
            Button(L(project.isPlaying ? S.pause : S.play)) { project.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(project.summary == nil)
            Button(L(S.previousFrame)) { project.step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(project.summary == nil)
            Button(L(S.nextFrame)) { project.step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(project.summary == nil)
            Divider()
            Button(L(S.addCut)) { project.addCut() }.keyboardShortcut("k").disabled(!project.canAddCut)
            Button(L(S.removeCut)) { project.removeCut() }.keyboardShortcut(.delete).disabled(!project.canRemoveCut)
        }
    }
}

/// `open -a AutoGrade <file>` and Finder's Open With arrive here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        MainActor.assumeIsolated { OpenRequests.shared.open(url) }
    }
}

/// Holds a file that arrives before the window (and its Project) exists.
@MainActor
final class OpenRequests {
    static let shared = OpenRequests()
    private weak var project: Project?
    private var pending: URL?

    func attach(_ project: Project) {
        self.project = project
        if let pending { self.pending = nil; project.open(pending) }
    }

    func open(_ url: URL) {
        if let project { project.open(url) } else { pending = url }
    }
}
