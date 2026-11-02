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
    private var finals: [LUT3D] = []
    /// Three slots so the slot being drawn is never the one being written.
    private var previewSlots: [PreviewTargets] = []
    private var nextSlot = 0
    /// Cancellation must reach a running job, which holds the actor, so it lives outside it.
    nonisolated let control = CancelControl()

    init() throws {
        core = try AutoGrader()
    }

    // MARK: analysis and edits

    func open(_ url: URL, progress: @escaping @Sendable (Double) -> Void) throws -> Summary {
        let token = control.begin()
        defer { control.end(token) }
        // Probe the format first so an unsupported file fails before any work.
        let probe = try VideoReader(url: url, device: core.metal.device)
        let expected = max(1.0, probe.info.duration.seconds * Double(probe.info.nominalFrameRate))
        let result = try core.analyze(url, lutSize: 65, cancel: token) { i in progress(min(1, Double(i + 1) / expected)) }
        source = url
        analysis = result
        strengths = Array(repeating: 1, count: result.shots.count)
        finals = result.luts
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
        try rebuildFinals()
        return summary()
    }

    func removeCut(beforeShot k: Int) throws -> Summary {
        guard let a = analysis, k >= 1, k < a.shots.count else { return summary() }
        analysis = try core.removeCut(a, beforeShot: k)
        strengths.remove(at: k)                     // the merged shot keeps the earlier one's strength
        try rebuildFinals()
        return summary()
    }

    func setStrength(_ value: Float, shot k: Int) throws {
        guard let a = analysis, k < strengths.count else { return }
        strengths[k] = value
        finals[k] = try core.finalLUT(a, shot: k, strength: value)
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
        return Summary(info: a.info, shots: a.shots, strengths: strengths, shotSeconds: seconds,
                       frameCount: a.frameCount, frameRate: Double(a.frameCount) / duration, warnings: a.warnings)
    }

    private func noVideo() throws -> Summary { throw VideoError.reader("no video is open") }

    // MARK: preview

    func frame(_ index: Int) throws -> DisplayFrame {
        guard let source, let a = analysis else { throw VideoError.reader("no video is open") }
        let decoded = try core.decodeFrame(source, analysis: a, index: index)
        return try present(decoded, analysis: a)
    }

    private func present(_ decoded: DecodedFrame, analysis a: Analysis) throws -> DisplayFrame {
        let slot = previewSlots[nextSlot]
        nextSlot = (nextSlot + 1) % previewSlots.count
        try core.preview(decoded, lut: finals[a.shotIndex(forFrame: decoded.index)], into: slot)
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
    func play(from index: Int, onFrame: @escaping @Sendable (DisplayFrame, PlaybackStats) -> Void) async {
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
            guard let frame = try? present(decoded, analysis: analysis ?? a) else { break }
            shown += 1
            window.append(clock.now)
            window.removeAll { clock.now - $0 > .seconds(1) }
            onFrame(frame, PlaybackStats(fps: Double(window.count), dropped: dropped))
        }
    }

    // MARK: export

    /// Writes the graded video (and optionally the .cube files) with the
    /// current strengths. Replacing an existing file is the caller's decision,
    /// taken in the save panel; here it means: write a temp file beside it,
    /// then swap it in, so a failed export never destroys the old one.
    func export(to output: URL, codec: OutputCodec, cubes: URL?,
                progress: @escaping @Sendable (Double) -> Void) throws {
        guard let source, let a = analysis else { throw VideoError.reader("no video is open") }
        let token = control.begin()
        defer { control.end(token) }
        let fm = FileManager.default
        let replacing = fm.fileExists(atPath: output.path)
        let target = replacing
            ? output.deletingLastPathComponent().appendingPathComponent(".autograde-\(UUID().uuidString).mov")
            : output
        _ = try core.render(source, analysis: a, luts: finals, to: target, codec: codec, cancel: token) { i in
            progress(Double(i + 1) / Double(a.frameCount))
        }
        if replacing { _ = try fm.replaceItemAt(output, withItemAt: target) }

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
