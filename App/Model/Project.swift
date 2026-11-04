import AppKit
import AutoGradeCore
import Foundation
import Observation
import UniformTypeIdentifiers

enum CompareMode: String, CaseIterable, Sendable {
    case split, original, graded
    case output          // the reframed picture (成片), only while an aspect is set
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
    var compare: CompareMode = .split {
        didSet { if (compare == .output) != (oldValue == .output) { showFrame(playhead) } }
    }
    /// The live crop centre while a drag is under way (normalised along the axis), drawn before it is committed.
    var draggingCrop: Float?
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
    var exportAudio = true                       // copy the source's audio track (CLAUDE.md 导出)
    var exportSRT = true                         // write <name>.srt beside the video when there are subtitles
    var burnSubtitles = false                    // draw the subtitles into the picture
    private(set) var exportProgress: Double?
    private(set) var exportChecking = false      // the check after writing is running
    private(set) var lastExport: URL?

    // covers (CLAUDE.md 封面)
    var coverAspects: Set<CoverAspect> = Set(Cover.defaultAspects)
    var coverFormat: CoverFormat = .png
    /// Frames ticked for export; the top `Cover.defaultCount` after each scan or cut edit.
    var coverChosen: Set<Int> = []
    private(set) var selectedCover: Int?             // a frame index
    var coverPreviewAspect: CoverAspect = .portrait3x4 {
        didSet { refreshCoverPreview() }
    }
    private(set) var coverPreview: NSImage?
    private(set) var coverTitleOverlapsFace = false
    /// The owner's title on every cover (CLAUDE.md 封面 / 版式); empty = none.
    var coverTitleText = "" { didSet { if coverTitleText != oldValue { refreshCoverPreview() } } }
    var coverSubtitleText = "" { didSet { if coverSubtitleText != oldValue { refreshCoverPreview() } } }
    var coverTemplate: CoverTitleTemplate = .bottom { didSet { if coverTemplate != oldValue { refreshCoverPreview() } } }
    // title candidates (CLAUDE.md 封面 / 云端候选 / App): off unless turned on in Settings
    let titleSettings: TitleSuggestionSettings
    private let titleTransport: TitleTransport
    /// A description sent with the subtitles to get candidates; not drawn on the cover.
    var coverTopicText = ""
    private(set) var titleCandidates: [String] = []
    private(set) var offeredTitles: [String] = []
    private(set) var suggestingTitles = false
    private(set) var titleSuggestionError: String?

    private var coverTitle: CoverTitle? {
        let t = CoverTitle(title: coverTitleText, subtitle: coverSubtitleText.isEmpty ? nil : coverSubtitleText, template: coverTemplate)
        return t.isEmpty ? nil : t
    }
    private(set) var coverThumbnails: [Int: NSImage] = [:]   // by frame

    private let engine: Engine?
    private var frameTask: Task<Void, Never>?
    private var pendingFrame: Int?
    private var playTask: Task<Void, Never>?

    /// `stylesDirectory` nil: FiveK only (AppTests); the app uses the default. `titleSettings`
    /// and `titleTransport` are injectable so AppTests never touch the Keychain or the network.
    init(stylesDirectory: URL? = StyleCatalog.defaultDirectory, titleSettings: TitleSuggestionSettings = .shared,
         titleTransport: TitleTransport = URLSessionTitleTransport()) {
        self.titleSettings = titleSettings
        self.titleTransport = titleTransport
        var missing: String?
        do {
            let engine = try Engine(stylesDirectory: stylesDirectory)
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
        if compare == .output { compare = .split }   // a new video opens in its own frame
        source = url
        summary = nil
        strengths = []
        styles = []
        thumbnails = [:]
        coverChosen = []
        coverTopicText = ""
        titleCandidates = []
        offeredTitles = []
        titleSuggestionError = nil
        selectedCover = nil
        coverPreview = nil
        coverThumbnails = [:]
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
                if let frame = try? await engine.frame(i, output: compare == .output) { display = frame }
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
            await engine.play(from: from, output: compare == .output) { frame, stats in
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

    // MARK: subtitles (CLAUDE.md 字幕)

    var subtitles: [SubtitleCue] { summary?.subtitles ?? [] }
    private(set) var showSubtitles = false
    /// Recognition languages this Mac offers (empty below macOS 26).
    let speechLanguages: [String] = Engine.speechLanguages()

    func languageName(_ id: String) -> String {
        let display = Locale(identifier: Localization.shared.language == .simplifiedChinese ? "zh-Hans" : "en")
        return display.localizedString(forIdentifier: id) ?? id
    }

    func setShowSubtitles(_ on: Bool) {
        showSubtitles = on
        Task {
            await engine?.setShowSubtitles(on)
            if !isPlaying { showFrame(playhead) }
        }
    }

    /// Recognise speech; if that fails (often: the model is not on this Mac yet),
    /// ask before downloading it, then try once more (CLAUDE.md 字幕: a red line).
    func generateSubtitles(language: String) {
        guard let engine, canEdit else { return }
        stopPlaying()
        busy = S.recognising
        busyProgress = 0
        Task {
            defer { busy = nil }
            do {
                apply(try await engine.transcribe(language: language) { p in Task { @MainActor in self.busyProgress = p } },
                      keepThumbnails: true)
                showSubtitles = true
            } catch is Cancelled {
            } catch Engine.SubtitleError.recognition(let why) {
                let ask = NSAlert()
                ask.messageText = L(S.speechModelTitle)
                ask.informativeText = L(S.speechModelBody(languageName(language), why))
                ask.addButton(withTitle: L(S.download))
                ask.addButton(withTitle: L(S.cancel))
                guard ask.runModal() == .alertFirstButtonReturn else { return }
                do {
                    busy = S.downloadingModel
                    busyProgress = 0
                    try await engine.downloadSpeechModel(language: language) { p in Task { @MainActor in self.busyProgress = p } }
                    busy = S.recognising
                    busyProgress = 0
                    apply(try await engine.transcribe(language: language) { p in Task { @MainActor in self.busyProgress = p } },
                          keepThumbnails: true)
                    showSubtitles = true
                } catch is Cancelled {
                } catch {
                    alert = Alert(title: S.subtitlesFailed, message: "\(error)")
                }
            } catch {
                alert = Alert(title: S.subtitlesFailed, message: "\(error)")
            }
        }
    }

    func importSubtitles() {
        guard let engine, canEdit else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let (s, warnings) = try await engine.importSubtitles(url)
                apply(s, keepThumbnails: true)
                showSubtitles = true
                if !warnings.isEmpty { alert = Alert(title: S.subtitlesImported, message: warnings.joined(separator: "\n")) }
            } catch {
                alert = Alert(title: S.subtitlesFailed, message: "\(error)")
            }
        }
    }

    func setCueText(_ text: String, cue k: Int) {
        guard let engine else { return }
        Task { if let s = await engine.setCueText(text, cue: k) { apply(s, keepThumbnails: true) } }
    }

    func deleteCue(_ k: Int) {
        guard let engine else { return }
        Task { if let s = await engine.deleteCue(k) { apply(s, keepThumbnails: true) } }
    }

    func clearSubtitles() {
        guard let engine else { return }
        Task { if let s = await engine.clearSubtitles() { apply(s, keepThumbnails: true) } }
    }

    func seek(toSeconds t: Double) {
        guard let s = summary else { return }
        seek(min(Int(t * s.frameRate), s.frameCount - 1))
    }

    // MARK: covers (CLAUDE.md 封面)

    var covers: [Cover.Candidate]? { summary?.covers }

    /// The first time: one pass over the video (busy, cancellable).
    func findCovers() {
        guard let engine, canEdit else { return }
        stopPlaying()
        busy = S.findingCovers
        busyProgress = 0
        Task {
            do {
                apply(try await engine.scanCovers { p in Task { @MainActor in self.busyProgress = p } }, keepThumbnails: true)
            } catch is Cancelled {
            } catch {
                alert = Alert(title: S.coversFailed, message: "\(error)")
            }
            busy = nil
        }
    }

    /// New candidates (scan or cut edit): tick the top ones again, keep the selection if it is still a candidate.
    private func coversChanged() {
        guard let covers else { return }
        coverChosen = Set(covers.prefix(Cover.defaultCount).map(\.frame))
        if let f = selectedCover, !covers.contains(where: { $0.frame == f }) { selectedCover = nil }
        coverThumbnails = [:]
        refreshCoverThumbnails()
        refreshCoverPreview()
    }

    func selectCover(_ frame: Int) {
        selectedCover = frame
        seek(frame)
        refreshCoverPreview()
    }

    private func refreshCoverThumbnails() {
        guard let engine, let covers else { return }
        let shots = summary?.shots
        for c in covers {
            Task {
                guard let image = try? await engine.thumbnail(frame: c.frame, shot: c.shot), summary?.shots == shots else { return }
                coverThumbnails[c.frame] = NSImage(cgImage: image.value, size: NSSize(width: image.value.width, height: image.value.height))
            }
        }
    }

    private func refreshCoverPreview() {
        guard let engine, let f = selectedCover, let c = covers?.first(where: { $0.frame == f }) else {
            coverPreview = nil
            return
        }
        let aspect = coverPreviewAspect, title = coverTitle
        Task {
            guard let (image, overlaps) = try? await engine.coverPreview(c, aspect: aspect, title: title),
                  selectedCover == f, coverPreviewAspect == aspect, coverTitle == title else { return }
            coverPreview = NSImage(cgImage: image.value, size: NSSize(width: image.value.width, height: image.value.height))
            coverTitleOverlapsFace = overlaps
        }
    }

    var canSuggestTitles: Bool {
        titleSettings.enabled && titleSettings.hasKey && summary != nil && !suggestingTitles
    }

    /// What a request would send: the description and the subtitles (cut to the limit), in characters.
    var titleSendCounts: (topic: Int, subtitles: Int) {
        let topic = coverTopicText.trimmingCharacters(in: .whitespacesAndNewlines).count
        let subs = subtitles.map { $0.lines.joined(separator: " ") }.filter { !$0.isEmpty }.joined(separator: "\n").count
        return (topic, min(subs, TitleSuggester.transcriptLimit))
    }

    /// Only a description, no subtitles: the candidates come out close to each other.
    var titleInputIsThin: Bool { subtitles.isEmpty }

    /// Ask DeepSeek for candidates. `anotherBatch` sends the ones already offered,
    /// asking for new ones. Nothing is sent when it is off or no key is saved.
    func suggestTitles(anotherBatch: Bool = false) {
        guard let engine, titleSettings.enabled, !suggestingTitles else { return }
        guard let key = titleSettings.keyForRequest() else {
            titleSuggestionError = L(S.titleNeedsKey)
            return
        }
        let shapes = CoverAspect.allCases.filter(coverAspects.contains)
        let aspects = shapes.isEmpty ? Cover.defaultAspects : shapes
        let exclude = anotherBatch ? offeredTitles : [], topic = coverTopicText, transport = titleTransport
        suggestingTitles = true
        titleSuggestionError = nil
        Task {
            defer { suggestingTitles = false }
            guard let request = await engine.titleRequest(topic: topic, aspects: aspects, exclude: exclude) else { return }
            do {
                let titles = try await TitleSuggester.suggest(request, key: key, transport: transport)
                titleCandidates = titles
                offeredTitles = (anotherBatch ? offeredTitles : []) + titles
            } catch let e as TitleSuggestionError {
                titleSuggestionError = L(S.titleError(e))
            } catch {
                titleSuggestionError = L(S.titleError(.network("\(type(of: error))")))
            }
        }
    }

    /// Put a candidate in the title field; the owner can still edit it.
    func useTitleCandidate(_ title: String) { coverTitleText = title }

    /// The ticked covers in rank order, numbered by their rank in the list.
    private var chosenCovers: [(rank: Int, candidate: Cover.Candidate)] {
        (covers ?? []).enumerated().filter { coverChosen.contains($0.element.frame) }.map { ($0.offset + 1, $0.element) }
    }

    var canExportCovers: Bool { canEdit && !chosenCovers.isEmpty && !coverAspects.isEmpty }

    /// Choose a folder, ask before replacing, write and check every cover.
    func exportCovers() {
        guard let engine, let source, canExportCovers else { return }
        stopPlaying()
        let folder = NSOpenPanel()
        folder.canChooseDirectories = true
        folder.canChooseFiles = false
        folder.canCreateDirectories = true
        folder.message = L(S.chooseCoverFolder)
        folder.prompt = L(S.exportCoversButton)
        folder.directoryURL = source.deletingLastPathComponent()
        guard folder.runModal() == .OK, let dir = folder.url else { return }
        let chosen = chosenCovers, format = coverFormat, title = coverTitle
        let aspects = CoverAspect.allCases.filter(coverAspects.contains)
        let names = Engine.coverNames(source: source, covers: chosen, aspects: aspects, format: format)
        let existing = names.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        if !existing.isEmpty {
            let ask = NSAlert()
            ask.messageText = L(S.replaceCoversTitle)
            ask.informativeText = L(S.replaceCoversBody(existing.count))
            ask.addButton(withTitle: L(S.replace))
            ask.addButton(withTitle: L(S.cancel))
            guard ask.runModal() == .alertFirstButtonReturn else { return }
        }
        busy = S.exportingCovers
        busyProgress = 0
        Task {
            do {
                let checks = try await engine.exportCovers(chosen, aspects: aspects, format: format, title: title, to: dir) { p in
                    Task { @MainActor in self.busyProgress = p }
                }
                let failed = checks.filter { !$0.passed }
                lastExport = checks.first?.url
                alert = Alert(title: failed.isEmpty ? S.coversExported : S.coversCheckFailed,
                              message: L(S.coversSummary(dir.path, count: checks.count,
                                                         failures: failed.flatMap { c in c.failures.map { "\(c.url.lastPathComponent): \($0)" } })))
            } catch is Cancelled {
            } catch {
                alert = Alert(title: S.coversFailed, message: "\(error)")
            }
            busy = nil
        }
    }

    // MARK: enhancement (CLAUDE.md 画质增强)

    var enhance: EnhanceSettings { summary?.enhance ?? EnhanceSettings() }

    /// Shots the background effect leaves alone because no one was found in them.
    var shotsWithoutPeople: [Int] {
        guard enhance.background != nil, let people = enhance.backgroundShots else { return [] }
        return people.indices.filter { !people[$0] }
    }

    func setDenoise(_ strength: Float?) { setEnhance(denoise: strength, background: enhance.background) }
    func setBackground(_ effect: BackgroundEffect?) { setEnhance(denoise: enhance.denoise, background: effect) }

    /// The first background choice finds people in every frame (busy, cancellable).
    private func setEnhance(denoise: Float?, background: BackgroundEffect?) {
        guard let engine, canEdit, denoise != enhance.denoise || background != enhance.background else { return }
        stopPlaying()
        busy = S.findingPeople
        busyProgress = 0
        Task {
            do {
                apply(try await engine.setEnhance(denoise: denoise, background: background) { p in
                    Task { @MainActor in self.busyProgress = p }
                }, keepThumbnails: true)
            } catch is Cancelled {
            } catch {
                alert = Alert(title: S.enhanceFailed, message: "\(error)")
            }
            busy = nil
        }
    }

    // MARK: reframe

    var reframe: ReframeInfo? { summary?.reframe }

    /// nil = original frame. Detects subjects the first time (busy, cancellable).
    func setAspect(_ aspect: Aspect?) {
        guard let engine, canEdit, aspect != reframe?.aspect else { return }
        stopPlaying()
        busy = S.detectingSubjects
        busyProgress = 0
        Task {
            do {
                apply(try await engine.setAspect(aspect) { p in Task { @MainActor in self.busyProgress = p } }, keepThumbnails: true)
                if aspect == nil, compare == .output { compare = .graded }
            } catch is Cancelled {
            } catch {
                alert = Alert(title: S.reframeFailed, message: "\(error)")
            }
            busy = nil
        }
    }

    /// Fix shot k's crop where it was dragged, or (nil) return it to automatic.
    func setCropCenter(_ center: Float?, shot k: Int) {
        guard let engine else { return }
        Task {
            if let s = await engine.setCropCenter(center, shot: k) { apply(s, keepThumbnails: true) }
            draggingCrop = nil
        }
    }

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
        refreshCoverPreview()
        refreshCoverThumbnails()
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

    private func apply(_ s: Summary, keepThumbnails: Bool = false) {
        let old = summary
        summary = s
        strengths = s.strengths
        styles = s.styles
        showFrame(playhead)
        if s.covers != old?.covers { coversChanged() }
        else if s.styles != old?.styles || s.enhance != old?.enhance { refreshCoverPreview() }   // the cover's pixels changed
        if !keepThumbnails {   // a crop change does not change the graded thumbnails
            thumbnails = [:]
            refreshThumbnails()
        }
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
        save.directoryURL = source.deletingLastPathComponent()   // next to the source by default
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
        let codec = exportCodec, audio = exportAudio && (summary?.hasAudio ?? false)
        let hasSubtitles = !subtitles.isEmpty, burn = burnSubtitles && hasSubtitles
        let srt: URL? = exportSRT && hasSubtitles ? output.deletingPathExtension().appendingPathExtension("srt") : nil
        if let srt, FileManager.default.fileExists(atPath: srt.path) {
            let ask = NSAlert()
            ask.messageText = L(S.replaceSRTTitle(srt.lastPathComponent))
            ask.addButton(withTitle: L(S.replace))
            ask.addButton(withTitle: L(S.cancel))
            guard ask.runModal() == .alertFirstButtonReturn else { return }
        }
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
            exportChecking = false
            do {
                let report = try await engine.export(to: output, codec: codec, audio: audio, cubes: cubes,
                                                     burnSubtitles: burn, srt: srt,
                    progress: { p in Task { @MainActor in if self.exportProgress != nil { self.exportProgress = p } } },
                    checking: { Task { @MainActor in self.exportChecking = true } })
                lastExport = output
                alert = Alert(title: report.passed ? S.exportDone : S.exportCheckFailed,
                              message: L(S.exportSummary(output.path, frames: report.videoSamples, sampled: report.frames.count,
                                                         audioPackets: report.audioPackets, failures: report.failures,
                                                         warnings: report.warnings)))
            } catch is Cancelled {
            } catch {
                alert = Alert(title: S.exportFailed, message: "\(error)")
            }
            exportProgress = nil
            exportChecking = false
        }
    }

    func showLastExport() {
        if let lastExport { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) }
    }
}

func shotIndex(forFrame frame: Int, in shots: [Shot]) -> Int {
    shots.lastIndex { $0.first <= frame } ?? 0
}
