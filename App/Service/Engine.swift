import AutoGradeCore
import AVFoundation
import CoreGraphics
import Foundation
import Metal

/// Values that cross from the engine to the main actor. They are immutable
/// once made (textures are only rewritten after the display has moved on to
/// another slot, see `previewSlots`), so sharing them read-only is safe.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
}

/// What the interface needs to know about the current analysis.
struct Summary: Sendable {
    let info: VideoInfo
    let shots: [Shot]
    let strengths: [Float]
    let styles: [String]
    let hasAudio: Bool
    let reframe: ReframeInfo?
    let subtitles: [SubtitleCue]
    let shotSeconds: [Double]
    let frameCount: Int
    let frameRate: Double     // frames / duration, for the transport's step size only
    let warnings: [String]
}

/// One frame ready to draw: the ungraded and graded BGRA8 textures from the
/// shared grading path (CLAUDE.md 架构原则 5).
struct DisplayFrame: @unchecked Sendable {
    let index: Int
    let original: MTLTexture
    let graded: MTLTexture
}

/// The reframe state the interface draws: the crop per frame (normalised along
/// `axis`) and how each shot was decided (CLAUDE.md 重构图).
struct ReframeInfo: Sendable {
    let aspect: Aspect
    let axis: Int
    let length: SIMD2<Double>          // crop size as a fraction of the frame
    let centers: [Float]               // per frame
    let modes: [CropPath.Mode]         // per shot
}

struct PlaybackStats: Sendable {
    let fps: Double
    let dropped: Int
}

/// Owns the AutoGrader and everything mutable about the open video. Runs on
/// its own serial queue: the Core is synchronous (it waits on the GPU and on
/// AVFoundation loads), and blocking a dedicated queue is fine where blocking
/// the shared cooperative pool is not.
actor Engine {
    private let queue = DispatchSerialQueue(label: "dev.chenshaojie.autograde.engine", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let core: AutoGrader
    private var source: URL?
    private var analysis: Analysis?
    private var strengths: [Float] = []
    private var hasAudio = false
    // reframing (CLAUDE.md 重构图): the subject track is per video, the path per edit
    private var track: SubjectTrack?
    private var aspect: Aspect?
    private var cropOverrides: [Float?] = []
    private var path: CropPath?
    private var reframeSlots: [ReframeTargets] = []
    // subtitles (CLAUDE.md 字幕): edited here; burns are per output size and rebuilt on any edit
    private var cues: [SubtitleCue] = []
    private var showSubtitles = false
    private var burns: [String: SubtitleBurn] = [:]
    private var finals: [LUT3D] = []
    /// Three slots so the slot being drawn is never the one being written.
    private var previewSlots: [PreviewTargets] = []
    private var nextSlot = 0
    /// Cancellation must reach a running job, which holds the actor, so it lives outside it.
    nonisolated let control = CancelControl()
    /// Fixed for the engine's lifetime: styles are found once, at launch.
    nonisolated let styles: [Style]
    nonisolated let styleWarnings: [String]

    init() throws {
        core = try AutoGrader()
        styles = core.catalog.styles
        styleWarnings = core.catalog.warnings
    }

    // MARK: analysis and edits

    func open(_ url: URL, style: String, progress: @escaping @Sendable (Double) -> Void) throws -> Summary {
        let token = control.begin()
        defer { control.end(token) }
        // Probe the format first so an unsupported file fails before any work.
        let probe = try VideoReader(url: url, device: core.metal.device)
        let expected = max(1.0, probe.info.duration.seconds * Double(probe.info.nominalFrameRate))
        let result = try core.analyze(url, lutSize: 65, style: style, cancel: token) { i in
            progress(min(1, Double(i + 1) / expected))
        }
        source = url
        analysis = result
        hasAudio = (try? AudioPassthrough.trackCount(url)) ?? 0 > 0
        strengths = Array(repeating: 1, count: result.shots.count)
        finals = result.luts
        track = nil
        aspect = nil
        path = nil
        reframeSlots = []
        cropOverrides = Array(repeating: nil, count: result.shots.count)
        cues = []
        burns = [:]
        previewSlots = try (0..<3).map { _ in
            try PreviewTargets(kernels: core.kernels, width: result.info.width, height: result.info.height)
        }
        return summary()
    }

    func addCut(atFrame frame: Int, progress: @escaping @Sendable (Double) -> Void) throws -> Summary {
        guard let source, let a = analysis else { return try noVideo() }
        let k = a.shotIndex(forFrame: frame)
        let shot = a.shots[k]
        guard frame > shot.first else { return summary() }   // already a shot start
        let token = control.begin()
        defer { control.end(token) }
        analysis = try core.addCut(a, source: source, atFrame: frame, cancel: token) { i in
            progress(Double(i - shot.first + 1) / Double(shot.frames))
        }
        strengths.insert(strengths[k], at: k + 1)   // both halves keep the shot's strength
        cropOverrides.insert(cropOverrides[k], at: k + 1)
        try rebuildFinals()
        rebuildPath()
        return summary()
    }

    /// Merging shots of different styles re-analyses the later one (CLAUDE.md, 风格).
    func removeCut(beforeShot k: Int, progress: @escaping @Sendable (Double) -> Void) throws -> Summary {
        guard let source, let a = analysis, k >= 1, k < a.shots.count else { return summary() }
        let token = control.begin()
        defer { control.end(token) }
        let later = a.shots[k]
        analysis = try core.removeCut(a, beforeShot: k, source: source, cancel: token) { i in
            progress(Double(i - later.first + 1) / Double(later.frames))
        }
        strengths.remove(at: k)                     // the merged shot keeps the earlier one's strength (and style)
        cropOverrides.remove(at: k)
        try rebuildFinals()
        rebuildPath()
        return summary()
    }

    /// Grade shots `range` in `style`; only those shots are decoded, cuts and strengths stay.
    func setStyle(_ style: String, shots range: ClosedRange<Int>,
                  progress: @escaping @Sendable (Double) -> Void) throws -> Summary {
        guard let source, let a = analysis, range.upperBound < a.shots.count else { return try noVideo() }
        let token = control.begin()
        defer { control.end(token) }
        let first = a.shots[range.lowerBound].first, frames = a.shots[range.upperBound].last - first + 1
        analysis = try core.restyle(a, source: source, shots: range, to: style, cancel: token) { i in
            progress(Double(i - first + 1) / Double(frames))
        }
        try rebuildFinals()
        return summary()
    }

    func setStrength(_ value: Float, shot k: Int) throws {
        guard let a = analysis, k < strengths.count else { return }
        strengths[k] = value
        finals[k] = try core.finalLUT(a, shot: k, strength: value)
    }

    // MARK: reframe

    /// nil = the source's own frame. The first time a video is reframed its
    /// subjects are detected (one pass, cancellable); after that only the path is recomputed.
    func setAspect(_ newAspect: Aspect?, progress: @escaping @Sendable (Double) -> Void) throws -> Summary {
        guard let source, let a = analysis else { return try noVideo() }
        if let newAspect, track == nil {
            let token = control.begin()
            defer { control.end(token) }
            track = try core.detectSubjects(source, analysis: a, cancel: token) { i in
                progress(Double(i + 1) / Double(a.frameCount))
            }
        }
        if newAspect != aspect {
            cropOverrides = Array(repeating: nil, count: a.shots.count)   // positions are per axis
            reframeSlots = try newAspect.map { asp in
                try (0..<3).map { _ in
                    try ReframeTargets(kernels: core.kernels, sourceWidth: a.info.width, sourceHeight: a.info.height, aspect: asp)
                }
            } ?? []
        }
        aspect = newAspect
        rebuildPath()
        return summary()
    }

    /// Shot k fixed at `center` (normalised along the crop's axis), or back to automatic (nil).
    func setCropCenter(_ center: Float?, shot k: Int) -> Summary? {
        guard analysis != nil, k < cropOverrides.count else { return nil }
        cropOverrides[k] = center.map { min(max($0, 0), 1) }
        rebuildPath()
        return summary()
    }

    // MARK: subtitles

    enum SubtitleError: Error, CustomStringConvertible {
        case needsMacOS26, unsupported(String), recognition(String)
        var description: String {
            switch self {
            case .needsMacOS26: "speech recognition needs macOS 26 or later"
            case .unsupported(let l): "\(l) is not supported"
            case .recognition(let e): e
            }
        }
    }

    /// Recognise the video's speech in `language` and split it into cues for the current frame.
    /// A failure is reported as `.recognition`, so the interface can offer the model download.
    func transcribe(language: String, progress: @escaping @Sendable (Double) -> Void) throws -> Summary {
        guard let source, let a = analysis else { return try noVideo() }
        guard #available(macOS 26.0, *) else { throw SubtitleError.needsMacOS26 }
        guard let locale = try Transcriber.locale(for: language) else { throw SubtitleError.unsupported(language) }
        let token = control.begin()
        defer { control.end(token) }
        let tokens: [SubtitleToken]
        do {
            tokens = try Transcriber.transcribe(source, locale: locale, cancel: token, progress: progress)
        } catch is Cancelled {
            throw Cancelled()
        } catch {
            throw SubtitleError.recognition("\(error)")
        }
        cues = Subtitles.cues(tokens: tokens, cuts: a.shots.dropFirst().map { a.frameTimes[$0.first].seconds },
                              frameSeconds: a.info.duration.seconds / Double(max(a.frameCount, 1)),
                              script: SubtitleScript(language: locale.identifier), vertical: aspect == .vertical9x16)
        burns = [:]
        showSubtitles = true
        return summary()
    }

    /// Download a language's system speech model; only after the user agreed (CLAUDE.md 字幕).
    func downloadSpeechModel(language: String, progress: @escaping @Sendable (Double) -> Void) throws {
        guard #available(macOS 26.0, *) else { throw SubtitleError.needsMacOS26 }
        guard let locale = try Transcriber.locale(for: language) else { throw SubtitleError.unsupported(language) }
        try Transcriber.downloadModel(locale, progress: progress)
    }

    nonisolated static func speechLanguages() -> [String] {
        guard #available(macOS 26.0, *) else { return [] }
        return (try? Transcriber.supportedLanguages()) ?? []
    }

    func importSubtitles(_ url: URL) throws -> (Summary, [String]) {
        let parsed = Subtitles.parseSRT(try String(contentsOf: url, encoding: .utf8))
        cues = parsed.cues
        burns = [:]
        showSubtitles = true
        return (summary(), parsed.warnings)
    }

    func setCueText(_ text: String, cue k: Int) -> Summary? {
        guard k < cues.count else { return nil }
        cues[k].lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        burns = [:]
        return summary()
    }

    func deleteCue(_ k: Int) -> Summary? {
        guard k < cues.count else { return nil }
        cues.remove(at: k)
        burns = [:]
        return summary()
    }

    func clearSubtitles() -> Summary? {
        guard analysis != nil else { return nil }
        cues = []
        burns = [:]
        return summary()
    }

    func setShowSubtitles(_ on: Bool) { showSubtitles = on }

    func subtitlesText() -> String { Subtitles.srt(cues) }

    /// The burn for a `width` x `height` picture, made once per edit.
    private func burn(_ width: Int, _ height: Int) -> SubtitleBurn? {
        guard !cues.isEmpty else { return nil }
        let key = "\(width)x\(height)"
        if let b = burns[key] { return b }
        let b = SubtitleBurn(cues: cues, width: width, height: height, kernels: core.kernels)
        burns[key] = b
        return b
    }

    private func rebuildPath() {
        guard let a = analysis, let aspect, let track else { path = nil; return }
        path = Reframe.path(track: track, shots: a.shots, frameTimes: a.frameTimes, width: a.info.width,
                            height: a.info.height, aspect: aspect, overrides: cropOverrides)
    }

    private func rebuildFinals() throws {
        guard let a = analysis else { return }
        finals = try core.finalLUTs(a, strengths: strengths)
    }

    private func summary() -> Summary {
        guard let a = analysis else { fatalError("summary without analysis") }
        let end = a.info.duration
        let seconds = a.shots.map { shot -> Double in
            let stop = shot.last + 1 < a.frameCount ? a.frameTimes[shot.last + 1] : end
            return max(0, (stop - a.frameTimes[shot.first]).seconds)
        }
        let duration = max(end.seconds, 1e-6)
        return Summary(info: a.info, shots: a.shots, strengths: strengths, styles: a.styles, hasAudio: hasAudio,
                       reframe: path.map { p in
                           ReframeInfo(aspect: p.aspect, axis: p.axis,
                                       length: SIMD2(Double(p.length.x) / Double(a.info.width), Double(p.length.y) / Double(a.info.height)),
                                       centers: p.centers, modes: p.modes)
                       },
                       subtitles: cues,
                       shotSeconds: seconds,
                       frameCount: a.frameCount, frameRate: Double(a.frameCount) / duration, warnings: a.warnings)
    }

    private func noVideo() throws -> Summary { throw VideoError.reader("no video is open") }

    // MARK: preview

    /// `output`: the reframed picture ("成片", the export's bytes) when a crop is set.
    func frame(_ index: Int, output: Bool = false) throws -> DisplayFrame {
        guard let source, let a = analysis else { throw VideoError.reader("no video is open") }
        let decoded = try core.decodeFrame(source, analysis: a, index: index)
        return try present(decoded, analysis: a, output: output)
    }

    private func present(_ decoded: DecodedFrame, analysis a: Analysis, output: Bool) throws -> DisplayFrame {
        let lut = finals[a.shotIndex(forFrame: decoded.index)]
        if output, let path, !reframeSlots.isEmpty {
            let slot = reframeSlots[nextSlot % reframeSlots.count]
            nextSlot = (nextSlot + 1) % 3
            let (w, h) = path.outputSize
            try core.previewReframed(decoded, lut: lut, path: path, into: slot, subtitles: showSubtitles ? burn(w, h) : nil)
            return DisplayFrame(index: decoded.index, original: slot.output, graded: slot.output)
        }
        let slot = previewSlots[nextSlot]
        nextSlot = (nextSlot + 1) % previewSlots.count
        try core.preview(decoded, lut: lut, into: slot, subtitles: showSubtitles ? burn(a.info.width, a.info.height) : nil)
        return DisplayFrame(index: decoded.index, original: slot.original, graded: slot.graded)
    }

    /// The shot list picture: the shot's middle frame, graded at its strength.
    func thumbnail(shot k: Int, width: Int = 192) throws -> Unchecked<CGImage> {
        guard let source, let a = analysis, k < a.shots.count else { throw VideoError.reader("no such shot") }
        let shot = a.shots[k]
        let decoded = try core.decodeFrame(source, analysis: a, index: (shot.first + shot.last) / 2)
        let texture = try core.thumbnail(decoded, lut: finals[k], width: width)
        return Unchecked(value: try Self.image(texture))
    }

    /// BGRA8 texture -> CGImage, tagged ITU-R 709 like the preview layer.
    private static func image(_ t: MTLTexture) throws -> CGImage {
        let row = t.width * 4
        var bytes = [UInt8](repeating: 0, count: row * t.height)
        t.getBytes(&bytes, bytesPerRow: row, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        guard let space = CGColorSpace(name: CGColorSpace.itur_709),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: t.width, height: t.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
                                  space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                           | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw VideoError.reader("thumbnail image")
        }
        return image
    }

    // MARK: playback

    /// Plays from `index` at the source's own timestamps until the task is
    /// cancelled or the video ends. A frame already more than one frame late is
    /// decoded but not graded or shown (dropped), so the clock never slips.
    /// The actor is free between frames (`Task.sleep`), so strength changes and
    /// edits interleave with playback.
    func play(from index: Int, output: Bool = false, onFrame: @escaping @Sendable (DisplayFrame, PlaybackStats) -> Void) async {
        guard let source, let a = analysis, index < a.frameCount else { return }
        let reader: VideoReader
        do {
            reader = try VideoReader(url: source, device: core.metal.device,
                                     timeRange: a.timeRange(first: index, last: a.frameCount - 1), frameTimes: a.frameTimes)
        } catch { return }
        let clock = ContinuousClock()
        let start = clock.now
        let origin = a.frameTimes[index]
        let slack = Duration.seconds(max(a.info.duration.seconds, 1e-3) / Double(a.frameCount))   // one frame
        var dropped = 0, shown = 0
        var window: [ContinuousClock.Instant] = []
        while !Task.isCancelled {
            guard let decoded = try? reader.next() else { break }
            let due = start + .seconds((decoded.presentationTime - origin).seconds)
            if clock.now > due + slack {
                dropped += 1
                continue
            }
            try? await Task.sleep(until: due, clock: clock)
            if Task.isCancelled { break }
            guard let frame = try? present(decoded, analysis: analysis ?? a, output: output) else { break }
            shown += 1
            window.append(clock.now)
            window.removeAll { clock.now - $0 > .seconds(1) }
            onFrame(frame, PlaybackStats(fps: Double(window.count), dropped: dropped))
        }
    }

    // MARK: export

    /// Writes the graded video (and optionally the .cube files) with the
    /// current strengths, then checks it (CLAUDE.md 导出). Replacing an existing
    /// file is the caller's decision, taken in the save panel; here it means:
    /// write a temp file beside it, then swap it in, so a failed export never
    /// destroys the old one. A failed check keeps the file; the report says why.
    func export(to output: URL, codec: OutputCodec, audio: Bool, cubes: URL?, burnSubtitles: Bool, srt: URL?,
                progress: @escaping @Sendable (Double) -> Void,
                checking: @escaping @Sendable () -> Void) throws -> ExportReport {
        guard let source, let a = analysis else { throw VideoError.reader("no video is open") }
        let token = control.begin()
        defer { control.end(token) }
        let fm = FileManager.default
        let replacing = fm.fileExists(atPath: output.path)
        let target = replacing
            ? output.deletingLastPathComponent().appendingPathComponent(".autograde-\(UUID().uuidString).mov")
            : output
        let size = path?.outputSize ?? (a.info.width, a.info.height)
        let rendered = try core.render(source, analysis: a, luts: finals, to: target, codec: codec, audio: audio,
                                       reframe: path, subtitles: burnSubtitles ? burn(size.0, size.1) : nil, cancel: token) { i in
            progress(Double(i + 1) / Double(a.frameCount))
        }
        checking()
        var report = try core.checkExport(target, source: source, analysis: a, luts: finals, render: rendered)
        report.warnings = rendered.warnings
        if replacing { _ = try fm.replaceItemAt(output, withItemAt: target) }
        if let srt, !cues.isEmpty {   // replacing an existing one was confirmed in the interface
            try Subtitles.srt(cues).write(to: srt, atomically: true, encoding: .utf8)
        }

        if let cubes {
            let prefix = source.deletingPathExtension().lastPathComponent
            let staging = fm.temporaryDirectory.appendingPathComponent("autograde-cubes-\(UUID().uuidString)")
            let written = try core.writeCubes(a, luts: finals, to: staging, prefix: prefix)
            try fm.createDirectory(at: cubes, withIntermediateDirectories: true)
            for file in written {
                let dest = cubes.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: dest.path) {
                    _ = try fm.replaceItemAt(dest, withItemAt: file)   // confirmed in the replace alert
                } else {
                    try fm.moveItem(at: file, to: dest)
                }
            }
            try? fm.removeItem(at: staging)   // the now-empty staging directory this call made
        }
        return report
    }

    /// Names the .cube export would write, so the interface can ask before replacing.
    func cubeNames() -> [String] {
        guard let source, let a = analysis else { return [] }
        let prefix = source.deletingPathExtension().lastPathComponent
        return a.shots.indices.map { AutoGrader.cubeName(prefix: prefix, shot: $0) }
    }

    nonisolated func cancelCurrentJob() { control.cancelCurrent() }
}

/// Holds the token of whatever long job is running, so the main actor can cancel it.
final class CancelControl: @unchecked Sendable {
    private let lock = NSLock()
    private var current: CancelToken?

    func begin() -> CancelToken {
        let token = CancelToken()
        lock.withLock { current = token }
        return token
    }

    func end(_ token: CancelToken) {
        lock.withLock { if current === token { current = nil } }
    }

    func cancelCurrent() {
        lock.withLock { current?.cancel() }
    }
}
