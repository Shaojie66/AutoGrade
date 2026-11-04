import AutoGradeCore
import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @Bindable var project: Project
    @State private var dropTargeted = false
    @State private var sidebar = 0               // 0 shots, 1 subtitles

    var body: some View {
        content
            .frame(minWidth: 980, minHeight: 620)
            .toolbar {
                ToolbarItemGroup {
                    Button { project.openPanel() } label: { Label(L(S.open), systemImage: "folder") }
                    Button { project.reanalyze() } label: { Label(L(S.reanalyze), systemImage: "arrow.clockwise") }
                        .disabled(!project.canEdit)
                    Menu {
                        if !project.speechLanguages.isEmpty {
                            Menu(L(S.generateSubtitles)) {
                                ForEach(menuLanguages, id: \.self) { id in
                                    Button(project.languageName(id)) { project.generateSubtitles(language: id) }
                                }
                            }
                        } else {
                            Text(L(S.subtitlesNeedMac26))
                        }
                        Button(L(S.importSRT)) { project.importSubtitles() }
                        Divider()
                        Toggle(L(S.showSubtitles), isOn: Binding(get: { project.showSubtitles }, set: { project.setShowSubtitles($0) }))
                            .disabled(project.subtitles.isEmpty)
                        Button(L(S.clearSubtitles)) { project.clearSubtitles() }
                            .disabled(project.subtitles.isEmpty)
                    } label: {
                        Label(L(S.subtitlesMenu), systemImage: "captions.bubble")
                    }
                    .disabled(!project.canEdit)
                    .accessibilityLabel(L(S.subtitlesMenu))
                    Menu {
                        Picker(L(S.aspect), selection: Binding(get: { project.reframe?.aspect },
                                                               set: { project.setAspect($0) })) {
                            Text(L(S.aspectOriginal)).tag(Aspect?.none)
                            Text(L(S.aspectVertical)).tag(Aspect?.some(.vertical9x16))
                            Text(L(S.aspectHorizontal)).tag(Aspect?.some(.horizontal16x9))
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(L(S.aspect), systemImage: "crop")
                    }
                    .disabled(!project.canEdit)
                    .accessibilityLabel(L(S.aspect))
                    if project.availableStyles.count > 1 {
                        Menu {
                            Section(L(S.applyToAllShots)) {
                                ForEach(project.availableStyles) { s in
                                    Toggle(project.styleName(s.id), isOn: Binding(
                                        get: { project.defaultStyle == s.id },
                                        set: { if $0 { project.setStyleForAll(s.id) } }))
                                }
                            }
                        } label: {
                            Label(L(S.style), systemImage: "camera.filters")
                        }
                        .disabled(project.busy != nil || project.exportProgress != nil)
                        .accessibilityLabel(L(S.style))
                    }
                    Button { project.beginExport() } label: { Label(L(S.export), systemImage: "square.and.arrow.up") }
                        .disabled(!project.canEdit)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in project.open(url) } }
                }
                return true
            }
            .sheet(isPresented: $project.showingExport) { ExportSheet(project: project) }
            .alert(item: $project.alert) { a in
                Alert(title: Text(L(a.title)), message: Text(a.message), dismissButton: .default(Text(L(S.ok))))
            }
    }

    /// Mandarin first (the default, CLAUDE.md 字幕), then the rest as the system lists them.
    private var menuLanguages: [String] {
        let first = ["zh_CN", "en_US"].filter(project.speechLanguages.contains)
        return first + project.speechLanguages.filter { !first.contains($0) }
    }

    @ViewBuilder private var content: some View {
        switch project.phase {
        case .empty:
            EmptyState(project: project, targeted: dropTargeted)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(L(S.openFailed)).font(.title3)
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .textSelection(.enabled).frame(maxWidth: 520)
                Button(L(S.open)) { project.openPanel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .analyzing, .ready:
            editor
        }
    }

    private var editor: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $sidebar) {
                    Text(L(S.sidebarShots)).tag(0)
                    Text(L(S.sidebarSubtitles)).tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                if sidebar == 0 { ShotList(project: project) } else { SubtitleList(project: project) }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            VStack(spacing: 0) {
                ZStack {
                    PreviewView(frame: project.display, split: project.split, mode: project.compare)
                    CompareOverlay(project: project)
                    overlayStatus
                }
                Divider()
                Transport(project: project)
            }
        }
    }

    @ViewBuilder private var overlayStatus: some View {
        if case .analyzing(let p) = project.phase {
            progressCard(L(S.analyzing), p, cancellable: true)
        } else if let busy = project.busy {
            progressCard(L(busy), project.busyProgress, cancellable: true)
        } else if let p = project.exportProgress {
            progressCard(L(project.exportChecking ? S.checkingExport : S.exporting), project.exportChecking ? 1 : p,
                         cancellable: !project.exportChecking)
        }
    }

    private func progressCard(_ title: String, _ p: Double, cancellable: Bool) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.headline)
            ProgressView(value: p).frame(width: 260)
            Text("\(Int(p * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if cancellable { Button(L(S.cancel)) { project.cancelJob() } }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EmptyState: View {
    @Bindable var project: Project
    let targeted: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(L(S.emptyTitle)).font(.title3)
            Text(L(S.emptyHint)).font(.callout).foregroundStyle(.secondary)
            Button(L(S.open)) { project.openPanel() }.controlSize(.large).keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(targeted ? Color.accentColor.opacity(0.12) : .clear)
    }
}
