import AppKit
import AutoGradeCore
import Foundation
import Observation
import UniformTypeIdentifiers

enum CompareMode: String, CaseIterable, Sendable {
    case split, original, graded
}

/// The one place interface state changes (CLAUDE.md, App/Model). Views read it
/// and call its methods; every engine call goes through here.
@MainActor @Observable
final class Project {
    enum Phase: Equatable {
        case empty
        case analyzing(Double)
        case ready
        case failed(String)
    }

    struct Alert: Identifiable {
        let id = UUID()
        let title: Copy
        let message: String
    }

    // video and analysis
    private(set) var phase: Phase = .empty
    private(set) var source: URL?
    private(set) var summary: Summary?
    private(set) var strengths: [Float] = []
    private(set) var styles: [String] = []       // per shot
    private(set) var thumbnails: [Int: NSImage] = [:]

    // styles
    /// Every style this Mac has (FiveK first), fixed at launch.
    let availableStyles: [Style]
    /// The style new videos open in, and what "apply to all shots" last chose.
    private(set) var defaultStyle: String
    static let defaultStyleKey = "defaultStyle"

    // view state
    private(set) var playhead = 0
    var split: Double = 0.5
    var compare: CompareMode = .split
    private(set) var display: DisplayFrame?
    private(set) var isPlaying = false
    private(set) var stats: PlaybackStats?
    private(set) var busy: Copy?                 // shown while a cut edit re-analyses
    private(set) var busyProgress: Double = 0
    var alert: Alert?

    // export
    var showingExport = false
    var exportCodec: OutputCodec = .hevc
    var exportCubes = false
    private(set) var exportProgress: Double?
    private(set) var lastExport: URL?

    private let engine: Engine?
    private var frameTask: Task<Void, Never>?
    private var pendingFrame: Int?
    private var playTask: Task<Void, Never>?

    init() {
        var missing: String?
        do {
            let engine = try Engine()
            self.engine = engine
            availableStyles = engine.styles
            let stored = UserDefaults.standard.string(forKey: Self.defaultStyleKey) ?? StyleCatalog.builtinID
            if engine.styles.contains(where: { $0.id == stored }) {
                defaultStyle = stored
            } else {
                defaultStyle = StyleCatalog.builtinID
                missing = stored
            }
            for warning in engine.styleWarnings { print("AutoGrade styles: \(warning)") }
        } catch {
            engine = nil
            availableStyles = []
            defaultStyle = StyleCatalog.builtinID
            phase = .failed("\(error)")
        }
        if let missing { alert = Alert(title: S.styleMissingTitle, message: L(S.styleMissingBody(missing))) }
    }

    var canEdit: Bool { phase == .ready && busy == nil && exportProgress == nil }
    var currentShot: Int? { summary.map { shotIndex(forFrame: playhead, in: $0.shots) } }

    // MARK: open

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        guard let engine else { return }
        stopPlaying()
        engine.cancelCurrentJob()
        source = url
        summary = nil
        strengths = []
        styles = []
        thumbnails = [:]
        display = nil
        playhead = 0
        phase = .analyzing(0)
        let style = defaultStyle
        Task {
            do {
                let s = try await engine.open(url, style: style) { p in
                    Task { @MainActor in self.updateAnalysisProgress(p, for: url) }
                }
                guard source == url else { return }   // another file was opened meanwhile
                summary = s
                strengths = s.strengths
                styles = s.styles
                phase = .ready
                showFrame(0)
                refreshThumbnails()
            } catch is Cancelled {
                if source == url { phase = .empty }
            } catch {
                if source == url { phase = .failed("\(error)") }
            }
        }
    }

    func reanalyze() {
        if let source { open(source) }
    }

    func cancelJob() {
        engine?.cancelCurrentJob()
    }

    private func updateAnalysisProgress(_ p: Double, for url: URL) {
        if source == url, case .analyzing = phase { phase = .analyzing(p) }
    }

    // MARK: frames

    func seek(_ frame: Int) {
        guard let summary else { return }
        stopPlaying()
        playhead = min(max(frame, 0), summary.frameCount - 1)
        showFrame(playhead)
    }

    func step(_ delta: Int) { seek(playhead + delta) }

    func selectShot(_ k: Int) {
        guard let shot = summary?.shots[k] else { return }
        seek((shot.first + shot.last) / 2)
    }

    /// Latest request wins: while one frame is being made, newer requests
    /// replace each other and only the last is made next.
    private func showFrame(_ index: Int) {
        guard let engine else { return }
        if frameTask != nil {
            pendingFrame = index
            return
        }
        frameTask = Task {
            var next: Int? = index
            while let i = next {
                pendingFrame = nil
                if let frame = try? await engine.frame(i) { display = frame }
                next = pendingFrame
            }
            frameTask = nil
        }
    }

    // MARK: playback

    func togglePlay() {
        isPlaying ? stopPlaying() : startPlaying()
    }

    private func startPlaying() {
        guard let engine, let summary, canEdit else { return }
        if playhead >= summary.frameCount - 1 { playhead = 0 }
        isPlaying = true
        let from = playhead
        playTask = Task {
            await engine.play(from: from) { frame, stats in
                Task { @MainActor in
                    guard self.isPlaying else { return }
                    self.display = frame
                    self.playhead = frame.index
                    self.stats = stats
                }
            }
            if !Task.isCancelled { isPlaying = false }
        }
    }

    func stopPlaying() {
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }

    // MARK: strength

    func setStrength(_ value: Float, shot k: Int) {
        guard let engine, k < strengths.count else { return }
        strengths[k] = value
        Task {
            try? await engine.setStrength(value, shot: k)
            if !isPlaying { showFrame(playhead) }
        }
    }

    func strengthCommitted(shot k: Int) {
        refreshThumbnail(k)
    }

    // MARK: cut editing

    var canAddCut: Bool {
        guard canEdit, let s = summary, let k = currentShot else { return false }
        return playhead > s.shots[k].first
    }

    var canRemoveCut: Bool { canEdit && (currentShot ?? 0) >= 1 }

    func addCut() {
        guard let engine, canAddCut else { return }
        stopPlaying()
        let frame = playhead
        busy = S.editing
        busyProgress = 0
        Task {
            do {
                let s = try await engine.addCut(atFrame: frame) { p in Task { @MainActor in self.busyProgress = p } }
                apply(s)
            } catch is Cancelled {
            } catch {
                alert = Alert(title: S.openFailed, message: "\(error)")
            }
            busy = nil
        }
    }

    func removeCut() {
        guard let engine, canRemoveCut, let k = currentShot else { return }
        stopPlaying()
        busy = S.editing                             // re-analyses when the two shots' styles differ
        busyProgress = 0
        Task {
            do {
                apply(try await engine.removeCut(beforeShot: k) { p in Task { @MainActor in self.busyProgress = p } })
            } catch is Cancelled {
            } catch {
                alert = Alert(title: S.openFailed, message: "\(error)")
            }
            busy = nil
        }
    }

    // MARK: styles

    func styleName(_ id: String) -> String {
        guard let style = availableStyles.first(where: { $0.id == id }) else { return id }
        return style.isBuiltin ? L(S.styleFiveK) : L(Copy(en: style.nameEN, zh: style.nameZH))
    }

    /// Grade one shot in another style: re-analyses that shot only.
    func setStyle(_ id: String, shot k: Int) {
        guard canEdit, k < styles.count, styles[k] != id else { return }
        restyle(id, shots: k...k)
    }

    /// Grade every shot in `id` (cuts stay), and open future videos in it.
    /// The default only changes once the shots are restyled: a cancelled
    /// restyle leaves both the shots and the default as they were.
    func setStyleForAll(_ id: String) {
        guard summary != nil else { return rememberDefault(id) }
        guard canEdit else { return }
        guard styles.contains(where: { $0 != id }) else { return rememberDefault(id) }
        restyle(id, shots: 0...(styles.count - 1)) { self.rememberDefault(id) }
    }

    private func rememberDefault(_ id: String) {
        defaultStyle = id
        UserDefaults.standard.set(id, forKey: Self.defaultStyleKey)
    }

    private func restyle(_ id: String, shots range: ClosedRange<Int>, onSuccess: (() -> Void)? = nil) {
        guard let engine else { return }
        stopPlaying()
        busy = S.restyling
        busyProgress = 0
        Task {
            do {
                apply(try await engine.setStyle(id, shots: range) { p in Task { @MainActor in self.busyProgress = p } })
                onSuccess?()
            } catch is Cancelled {
            } catch {
                alert = Alert(title: S.styleFailed, message: "\(error)")
            }
            busy = nil
        }
    }

    private func apply(_ s: Summary) {
        summary = s
        strengths = s.strengths
        styles = s.styles
        thumbnails = [:]
        showFrame(playhead)
        refreshThumbnails()
    }

    // MARK: thumbnails

    private func refreshThumbnails() {
        guard let count = summary?.shots.count else { return }
        for k in 0..<count { refreshThumbnail(k) }
    }

    private func refreshThumbnail(_ k: Int) {
        guard let engine else { return }
        let shots = summary?.shots
        Task {
            guard let image = try? await engine.thumbnail(shot: k), summary?.shots == shots else { return }
            thumbnails[k] = NSImage(cgImage: image.value, size: NSSize(width: image.value.width, height: image.value.height))
        }
    }

    // MARK: export

    func beginExport() {
        guard canEdit else { return }
        stopPlaying()
        showingExport = true
    }

    /// Runs the save (and folder) panels, asks before replacing .cube files, then exports.
    func runExport() {
        guard let engine, let source else { return }
        showingExport = false
        let save = NSSavePanel()
        save.allowedContentTypes = [.quickTimeMovie]
        save.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "_graded.mov"
        guard save.runModal() == .OK, let output = save.url else { return }   // the panel itself confirms replacing

        var cubes: URL?
        if exportCubes {
            let folder = NSOpenPanel()
            folder.canChooseDirectories = true
            folder.canChooseFiles = false
            folder.canCreateDirectories = true
            folder.message = L(S.chooseCubeFolder)
            folder.directoryURL = output.deletingLastPathComponent()
            guard folder.runModal() == .OK, let dir = folder.url else { return }
            cubes = dir
        }
        let codec = exportCodec
        Task {
            if let dir = cubes {
                let existing = await engine.cubeNames().filter {
                    FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
                }
                if !existing.isEmpty {
                    let ask = NSAlert()
                    ask.messageText = L(S.replaceCubesTitle)
                    ask.informativeText = L(S.replaceCubesBody(existing.count))
                    ask.addButton(withTitle: L(S.replace))
                    ask.addButton(withTitle: L(S.cancel))
                    guard ask.runModal() == .alertFirstButtonReturn else { return }
                }
            }
            exportProgress = 0
            do {
                try await engine.export(to: output, codec: codec, cubes: cubes) { p in
                    Task { @MainActor in if self.exportProgress != nil { self.exportProgress = p } }
                }
                lastExport = output
                alert = Alert(title: S.exportDone, message: output.path)
            } catch is Cancelled {
            } catch {
                alert = Alert(title: S.exportFailed, message: "\(error)")
            }
            exportProgress = nil
        }
    }

    func showLastExport() {
        if let lastExport { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) }
    }
}

func shotIndex(forFrame frame: Int, in shots: [Shot]) -> Int {
    shots.lastIndex { $0.first <= frame } ?? 0
}
