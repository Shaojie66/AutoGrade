import AVFoundation
import CoreML
import CoreVideo
import Foundation
import Metal

public struct Shot: Sendable, Equatable {
    public let first: Int   // frame indices, inclusive
    public let last: Int
    public var frames: Int { last - first + 1 }

    public init(first: Int, last: Int) {
        self.first = first
        self.last = last
    }
}

/// Wall-clock seconds per stage, summed over frames. Every stage waits for its
/// GPU work, so these are serial costs, not a throughput figure.
public struct StageTimes: Sendable {
    public var decode = 0.0, convert = 0.0, resize = 0.0, predict = 0.0, bake = 0.0, detect = 0.0
    public var apply = 0.0, encode = 0.0
    public var frames = 0
}

/// What pass 2 wrote: what ExportCheck needs to know to check the file.
public struct RenderResult: Sendable {
    public let times: StageTimes
    public let codec: OutputCodec
    /// Audio packets copied; nil when the output has no audio track.
    public let audioPackets: Int?
    public let warnings: [String]
    /// The crop each frame was reframed with; nil = the source's own frame.
    public let reframe: CropPath?
    /// The subtitles burnt in, if any (CLAUDE.md 字幕).
    public let subtitles: SubtitleBurn?
    /// The enhancements applied, if any (CLAUDE.md 画质增强).
    public let enhance: EnhanceSettings?

    public init(times: StageTimes, codec: OutputCodec, audioPackets: Int?, warnings: [String], reframe: CropPath?,
                subtitles: SubtitleBurn? = nil, enhance: EnhanceSettings? = nil) {
        self.enhance = enhance
        self.times = times
        self.codec = codec
        self.audioPackets = audioPackets
        self.warnings = warnings
        self.reframe = reframe
        self.subtitles = subtitles
    }
}

/// Result of pass 1, and the state cut editing works on. Preview and export
/// both read this (CLAUDE.md 架构原则 3). `sums` are the unclamped per-shot
/// sums of baked LUTs; `luts` are their clamped means (CLAUDE.md, 切点编辑).
/// `styles` is each shot's style id: a sum only ever holds one style's frames
/// (CLAUDE.md, 风格). Edits return a new Analysis and never write into an
/// existing buffer.
public struct Analysis {
    public let info: VideoInfo
    public let lutSize: Int
    public let frameTimes: [CMTime]
    public let shots: [Shot]
    public let sums: [LUT3D]
    public let luts: [LUT3D]
    public let styles: [String]
    public let times: StageTimes
    public let warnings: [String]

    public var frameCount: Int { frameTimes.count }

    public func shotIndex(forFrame frame: Int) -> Int {
        var lo = 0, hi = shots.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if shots[mid].first <= frame { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The time range covering frames first...last, for a range read.
    public func timeRange(first: Int, last: Int) -> CMTimeRange {
        let end = last + 1 < frameTimes.count ? frameTimes[last + 1] : CMTimeAdd(frameTimes[last], CMTime(value: 1, timescale: 600))
        return CMTimeRange(start: frameTimes[first], end: end)
    }
}

/// Preview targets for one video size, reused across frames: the ungraded and
/// graded BGRA8 textures the display samples, plus float scratch.
/// Targets for the reframed ("成片") preview: the output-size BGRA8 texture
/// the display samples, plus float scratch at source and output size.
public final class ReframeTargets {
    public let output: MTLTexture
    let cropped: PlanarImage
    let scratch: (rgb: PlanarImage, graded: PlanarImage)

    public init(kernels: GradeKernels, sourceWidth: Int, sourceHeight: Int, aspect: Aspect) throws {
        let (w, h) = aspect.outputSize
        output = try kernels.makeDisplayTexture(width: w, height: h)
        cropped = try kernels.makeImage(width: w, height: h)
        scratch = (try kernels.makeImage(width: sourceWidth, height: sourceHeight),
                   try kernels.makeImage(width: sourceWidth, height: sourceHeight))
    }
}

public final class PreviewTargets {
    public let original: MTLTexture
    public let graded: MTLTexture
    let scratch: (rgb: PlanarImage, graded: PlanarImage)

    public init(kernels: GradeKernels, width: Int, height: Int) throws {
        original = try kernels.makeDisplayTexture(width: width, height: height)
        graded = try kernels.makeDisplayTexture(width: width, height: height)
        scratch = (try kernels.makeImage(width: width, height: height), try kernels.makeImage(width: width, height: height))
    }
}

/// The two-pass pipeline: analyze (decode -> RGB -> 256^2 -> AiLUT -> bake to
/// N^3 -> shot detection -> per-shot sums) and render (decode -> RGB -> final
/// LUT -> encode), plus the cut edits and preview the app needs.
public final class AutoGrader {
    public let metal: MetalContext
    public let kernels: GradeKernels
    public let catalog: StyleCatalog

    /// `stylesDirectory` nil grades with FiveK only (tests); `extraStyles` are
    /// injected predictors (StyleTests).
    public init(computeUnits: MLComputeUnits = .cpuAndGPU, stylesDirectory: URL? = StyleCatalog.defaultDirectory,
                extraStyles: [(Style, LUTPredictor)] = []) throws {
        metal = try MetalContext()
        kernels = GradeKernels(metal: metal)
        catalog = try StyleCatalog(kernels: kernels, directory: stylesDirectory, computeUnits: computeUnits,
                                   extra: extraStyles)
    }

    // MARK: pass 1

    public func analyze(_ url: URL, lutSize: Int = 65, cutThreshold: Float = ShotDetector.defaultThreshold,
                        style: String = StyleCatalog.builtinID,
                        cancel: CancelToken? = nil, progress: ((Int) -> Void)? = nil) throws -> Analysis {
        let predictor = try catalog.predictor(style)
        let reader = try VideoReader(url: url, device: metal.device)
        var detector = ShotDetector(threshold: cutThreshold)
        var times = StageTimes()
        var frameTimes: [CMTime] = []
        var shots: [Shot] = [], sums: [LUT3D] = [], counts: [Int] = []
        var shotStart = 0, shotFrames = 0
        var acc = try kernels.makeLUT(size: lutSize)

        func closeShot(endingBefore frame: Int) {
            shots.append(Shot(first: shotStart, last: frame - 1))
            sums.append(acc)
            counts.append(shotFrames)
        }

        var clock = Clock()
        while let frame = try reader.next() {
            if cancel?.isCancelled == true { throw Cancelled() }
            times.decode += clock.lap()
            frameTimes.append(frame.presentationTime)
            let (baked, thumb) = try analyzeFrame(frame, lutSize: lutSize, predictor: predictor, thumbnail: true,
                                                  times: &times, clock: &clock)
            if detector.isCut(thumbnail: thumb!) {
                closeShot(endingBefore: frame.index)
                acc = try kernels.makeLUT(size: lutSize)
                shotStart = frame.index
                shotFrames = 0
            }
            try kernels.accumulate(acc, baked)
            shotFrames += 1
            times.detect += clock.lap()
            times.frames += 1
            progress?(frame.index)
        }
        guard times.frames > 0 else { throw VideoError.reader("no frames decoded") }
        closeShot(endingBefore: times.frames)
        let luts = try zip(sums, counts).map { try kernels.mean($0, frames: $1) }
        return Analysis(info: reader.info, lutSize: lutSize, frameTimes: frameTimes, shots: shots, sums: sums,
                        luts: luts, styles: Array(repeating: style, count: shots.count), times: times,
                        warnings: reader.warnings)
    }

    /// One frame of pass 1: its AiLUT baked to lutSize^3, and (optionally) the
    /// shot-detection thumbnail.
    private func analyzeFrame(_ frame: DecodedFrame, lutSize: Int, predictor: LUTPredictor, thumbnail: Bool,
                              times: inout StageTimes, clock: inout Clock) throws -> (LUT3D, [Float]?) {
        let rgb = try kernels.yuvToRGB(luma: frame.luma, chroma: frame.chroma)
        times.convert += clock.lap()
        let small = try kernels.resize(rgb, width: Grader.inputSide, height: Grader.inputSide)
        let thumb = thumbnail
            ? try kernels.resize(rgb, width: ShotDetector.thumbnailWidth, height: ShotDetector.thumbnailHeight).floats()
            : nil
        times.resize += clock.lap()
        let ai = try predictor.predict(small)
        times.predict += clock.lap()
        let baked = try kernels.bake(ai, size: lutSize)
        times.bake += clock.lap()
        return (baked, thumb)
    }

    // MARK: cut editing and styles

    /// Remove the cut in front of shot `index` (index >= 1): it merges into the
    /// shot before it and takes that shot's style. Same style: exact, the sums
    /// add and nothing is decoded. Different styles: the later part is first
    /// re-analysed in the earlier shot's style from `source` (CLAUDE.md, 风格).
    public func removeCut(_ analysis: Analysis, beforeShot index: Int, source url: URL,
                          cancel: CancelToken? = nil, progress: ((Int) -> Void)? = nil) throws -> Analysis {
        precondition(index >= 1 && index < analysis.shots.count)
        let a = analysis.shots[index - 1], b = analysis.shots[index]
        let style = analysis.styles[index - 1]
        let later = analysis.styles[index] == style
            ? analysis.sums[index]
            : try accumulate(analysis, source: url, parts: [(b, style)], cancel: cancel, progress: progress)[0]
        let sum = try kernels.makeLUT(size: analysis.lutSize)
        try kernels.accumulate(sum, analysis.sums[index - 1])
        try kernels.accumulate(sum, later)
        let merged = Shot(first: a.first, last: b.last)
        return try replacing(analysis, shots: (index - 1)...index, with: [(merged, sum, style)])
    }

    /// Add a cut so that `frame` starts a new shot. Only the shot being split
    /// is decoded again; both halves' sums come out of that one pass, and both
    /// keep the shot's style.
    public func addCut(_ analysis: Analysis, source url: URL, atFrame frame: Int,
                       cancel: CancelToken? = nil, progress: ((Int) -> Void)? = nil) throws -> Analysis {
        let k = analysis.shotIndex(forFrame: frame)
        let shot = analysis.shots[k], style = analysis.styles[k]
        precondition(frame > shot.first && frame <= shot.last, "frame \(frame) is already a shot start")
        let halves = [Shot(first: shot.first, last: frame - 1), Shot(first: frame, last: shot.last)]
        let sums = try accumulate(analysis, source: url, parts: halves.map { ($0, style) }, cancel: cancel, progress: progress)
        return try replacing(analysis, shots: k...k, with: [(halves[0], sums[0], style), (halves[1], sums[1], style)])
    }

    /// Grade shots `range` in `style` instead: those shots are decoded once
    /// (one read across the whole range), cuts stay where they are.
    public func restyle(_ analysis: Analysis, source url: URL, shots range: ClosedRange<Int>, to style: String,
                        cancel: CancelToken? = nil, progress: ((Int) -> Void)? = nil) throws -> Analysis {
        precondition(range.lowerBound >= 0 && range.upperBound < analysis.shots.count)
        let shots = Array(analysis.shots[range])
        let sums = try accumulate(analysis, source: url, parts: shots.map { ($0, style) }, cancel: cancel, progress: progress)
        return try replacing(analysis, shots: range, with: zip(shots, sums).map { ($0, $1, style) })
    }

    /// Decode the frames of `parts` (consecutive shots) in one range read and
    /// return each part's sum of baked LUTs, every frame predicted in its part's style.
    private func accumulate(_ analysis: Analysis, source url: URL, parts: [(shot: Shot, style: String)],
                            cancel: CancelToken?, progress: ((Int) -> Void)?) throws -> [LUT3D] {
        let first = parts.first!.shot.first, last = parts.last!.shot.last
        for (p, q) in zip(parts, parts.dropFirst()) { precondition(q.shot.first == p.shot.last + 1, "parts must be consecutive") }
        let predictors = try parts.map { try catalog.predictor($0.style) }
        let sums = try parts.map { _ in try kernels.makeLUT(size: analysis.lutSize) }
        let reader = try VideoReader(url: url, device: metal.device, timeRange: analysis.timeRange(first: first, last: last),
                                     frameTimes: analysis.frameTimes)
        var part = 0, seen = 0, times = StageTimes(), clock = Clock()
        while let f = try reader.next(), f.index <= last {
            if cancel?.isCancelled == true { throw Cancelled() }
            while f.index > parts[part].shot.last { part += 1 }
            let (baked, _) = try analyzeFrame(f, lutSize: analysis.lutSize, predictor: predictors[part], thumbnail: false,
                                              times: &times, clock: &clock)
            try kernels.accumulate(sums[part], baked)
            seen += 1
            progress?(f.index)
        }
        guard seen == last - first + 1 else {
            throw VideoError.reader("re-analysing frames \(first)-\(last) decoded \(seen) frames, expected \(last - first + 1)")
        }
        return sums
    }

    private func replacing(_ a: Analysis, shots range: ClosedRange<Int>, with parts: [(Shot, LUT3D, String)]) throws -> Analysis {
        var shots = a.shots, sums = a.sums, luts = a.luts, styles = a.styles
        shots.replaceSubrange(range, with: parts.map(\.0))
        sums.replaceSubrange(range, with: parts.map(\.1))
        luts.replaceSubrange(range, with: try parts.map { try kernels.mean($0.1, frames: $0.0.frames) })
        styles.replaceSubrange(range, with: parts.map(\.2))
        return Analysis(info: a.info, lutSize: a.lutSize, frameTimes: a.frameTimes, shots: shots, sums: sums,
                        luts: luts, styles: styles, times: a.times, warnings: a.warnings)
    }

    // MARK: strength

    /// Per-shot final LUTs: strength 1 is the shot LUT itself (no copy), else a blend.
    public func finalLUTs(_ analysis: Analysis, strengths: [Float]) throws -> [LUT3D] {
        precondition(strengths.count == analysis.shots.count)
        return try strengths.indices.map { try finalLUT(analysis, shot: $0, strength: strengths[$0]) }
    }

    public func finalLUT(_ analysis: Analysis, shot k: Int, strength: Float) throws -> LUT3D {
        strength >= 1 ? analysis.luts[k] : try kernels.blend(analysis.luts[k], strength: strength)
    }

    // MARK: preview

    /// Random access: decode exactly frame `index`.
    public func decodeFrame(_ url: URL, analysis: Analysis, index: Int) throws -> DecodedFrame {
        let reader = try VideoReader(url: url, device: metal.device,
                                     timeRange: analysis.timeRange(first: index, last: index),
                                     frameTimes: analysis.frameTimes)
        guard let frame = try reader.next(), frame.index == index else {
            throw VideoError.reader("could not decode frame \(index)")
        }
        return frame
    }

    /// Grade one decoded frame into `targets` — the same encode path render uses.
    /// `subtitles` (sized for the source frame) are burnt into the graded picture only.
    public func preview(_ frame: DecodedFrame, lut: LUT3D, into targets: PreviewTargets, subtitles: SubtitleBurn? = nil) throws {
        try preview(EnhancedFrame(frame), lut: lut, into: targets, subtitles: subtitles)
    }

    /// The enhanced variant (`decodeFrame(_:analysis:index:enhancer:)`): `original`
    /// shows the decoder's frame, `graded` the enhanced one.
    public func preview(_ frame: EnhancedFrame, lut: LUT3D, into targets: PreviewTargets, subtitles: SubtitleBurn? = nil) throws {
        let overlay = try subtitles?.overlay(at: frame.frame.presentationTime.seconds)
        let denoised = frame.frame.pixelBuffer !== frame.source.pixelBuffer
        try metal.run { enc in
            if denoised {
                try kernels.encodeYUVToRGB(into: enc, luma: frame.source.luma, chroma: frame.source.chroma, output: targets.scratch.rgb)
                try kernels.encodeWriteBGRA8(into: enc, targets.scratch.rgb, to: targets.original)
            }
            try kernels.encodeGradeFrame(into: enc, luma: frame.frame.luma, chroma: frame.frame.chroma, lut: lut,
                                         scratch: targets.scratch, graded: targets.graded,
                                         original: denoised ? nil : targets.original,
                                         background: frame.background, overlay: overlay)
        }
    }

    /// The reframed frame `index` of `path` into `targets` — the same encode
    /// path a reframed render uses (CLAUDE.md 重构图: 成片 = export bytes).
    public func previewReframed(_ frame: DecodedFrame, lut: LUT3D, path: CropPath, into targets: ReframeTargets,
                                subtitles: SubtitleBurn? = nil) throws {
        try previewReframed(EnhancedFrame(frame), lut: lut, path: path, into: targets, subtitles: subtitles)
    }

    public func previewReframed(_ frame: EnhancedFrame, lut: LUT3D, path: CropPath, into targets: ReframeTargets,
                                subtitles: SubtitleBurn? = nil) throws {
        let f = frame.frame
        let overlay = try subtitles?.overlay(at: f.presentationTime.seconds)
        try metal.run { enc in
            try kernels.encodeGradeFrame(into: enc, luma: f.luma, chroma: f.chroma, lut: lut, scratch: targets.scratch,
                                         crop: path.origins[f.index], length: path.length, cropped: targets.cropped,
                                         output: targets.output, background: frame.background, overlay: overlay)
        }
    }

    /// A small graded picture for the shot list: resized *before* grading, so it
    /// is an approximation of the frame, not the frame (that is `preview`).
    public func thumbnail(_ frame: DecodedFrame, lut: LUT3D, width: Int) throws -> MTLTexture {
        let rgb = try kernels.yuvToRGB(luma: frame.luma, chroma: frame.chroma)
        let height = max(2, Int((Double(width) * Double(rgb.height) / Double(rgb.width)).rounded()))
        let small = try kernels.resize(rgb, width: width, height: height)
        let graded = try kernels.applyLUT(small, lut)
        let texture = try kernels.makeDisplayTexture(width: width, height: height)
        try kernels.writeBGRA8(graded, to: texture)
        return texture
    }

    // MARK: pass 2

    /// Encode the video with one final LUT per shot (`finalLUTs`), and copy the
    /// source's first audio track unless `audio` is false (CLAUDE.md 导出). On
    /// error or cancellation the partial output — a file this call created — is
    /// removed. `frameHook` sees each graded BGRA buffer before it is appended (tests).
    public func render(_ url: URL, analysis: Analysis, luts: [LUT3D], to output: URL, codec: OutputCodec = .hevc,
                       audio: Bool = true, reframe: CropPath? = nil, subtitles: SubtitleBurn? = nil,
                       enhance: EnhanceSettings? = nil, cancel: CancelToken? = nil,
                       progress: ((Int) -> Void)? = nil,
                       frameHook: ((Int, CVPixelBuffer) -> Void)? = nil) throws -> RenderResult {
        precondition(luts.count == analysis.shots.count)
        precondition(reframe == nil || reframe!.origins.count == analysis.frameCount)
        let reader = try VideoReader(url: url, device: metal.device)
        let size = reframe?.outputSize ?? (reader.info.width, reader.info.height)
        precondition(subtitles == nil || (subtitles!.width == size.0 && subtitles!.height == size.1), "subtitles sized for the output")
        let writer = try VideoWriter(url: output, width: size.0, height: size.1,
                                     codec: codec, device: metal.device, audioFrom: audio ? url : nil)
        do {
            let scratch = (try kernels.makeImage(width: reader.info.width, height: reader.info.height),
                           try kernels.makeImage(width: reader.info.width, height: reader.info.height))
            let cropped = try reframe.map { _ in try kernels.makeImage(width: size.0, height: size.1) }
            let enhance = enhance?.isEmpty == false ? enhance : nil
            let enhancer = try enhance.map {
                try Enhancer(settings: $0, width: reader.info.width, height: reader.info.height, kernels: kernels)
            }
            let frames = EnhancedFrameStream(reader: reader, analysis: analysis, enhancer: enhancer)
            var times = StageTimes()
            var clock = Clock()
            while let enhanced = try frames.next() {
                let frame = enhanced.frame
                if cancel?.isCancelled == true { throw Cancelled() }
                times.decode += clock.lap()
                let (pixels, texture, textureRef) = try writer.makeFrame()
                let lut = luts[analysis.shotIndex(forFrame: frame.index)]
                let overlay = try subtitles?.overlay(at: frame.presentationTime.seconds)
                try metal.run { enc in
                    if let reframe, let cropped {
                        try kernels.encodeGradeFrame(into: enc, luma: frame.luma, chroma: frame.chroma, lut: lut,
                                                     scratch: scratch, crop: reframe.origins[frame.index],
                                                     length: reframe.length, cropped: cropped, output: texture,
                                                     background: enhanced.background, overlay: overlay)
                    } else {
                        try kernels.encodeGradeFrame(into: enc, luma: frame.luma, chroma: frame.chroma, lut: lut,
                                                     scratch: scratch, graded: texture, original: nil,
                                                     background: enhanced.background, overlay: overlay)
                    }
                }
                withExtendedLifetime(textureRef) {}
                times.apply += clock.lap()
                frameHook?(frame.index, pixels)
                try writer.append(pixels, at: frame.presentationTime)
                times.encode += clock.lap()
                times.frames += 1
                progress?(frame.index)
            }
            try writer.finish()
            times.encode += clock.lap()
            guard times.frames == analysis.frameCount else {
                throw VideoError.reader("render decoded \(times.frames) frames, analysis saw \(analysis.frameCount)")
            }
            return RenderResult(times: times, codec: codec, audioPackets: writer.audioPackets, warnings: writer.warnings,
                                reframe: reframe, subtitles: subtitles, enhance: enhance)
        } catch {
            writer.cancel()
            throw error
        }
    }

    /// One `.cube` per shot: `<prefix>_shot00.cube`, ...
    public func writeCubes(_ analysis: Analysis, luts: [LUT3D], to directory: URL, prefix: String) throws -> [URL] {
        precondition(luts.count == analysis.shots.count)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try luts.enumerated().map { k, lut in
            let url = directory.appendingPathComponent(Self.cubeName(prefix: prefix, shot: k))
            let shot = analysis.shots[k]
            try CubeWriter.write(lut, title: "AutoGrade \(prefix) shot \(k) (frames \(shot.first)-\(shot.last)), "
                                 + styleCredit(analysis.styles[k]), to: url)
            return url
        }
    }

    /// Style name and licence in short, for the `.cube` title (CLAUDE.md 风格模型).
    func styleCredit(_ id: String) -> String {
        let style = catalog.style(id)
        let film = style?.license.contains("CC BY-SA 4.0") == true ? "; film look CC BY-SA 4.0" : ""
        let name = (style?.nameEN ?? id).replacingOccurrences(of: "\"", with: "'")
        return "style \(name) [\(id)]: research use only, non-commercial\(film)"
    }

    public static func cubeName(prefix: String, shot: Int) -> String {
        String(format: "%@_shot%02d.cube", prefix, shot)
    }
}

struct Clock {
    private var last = CFAbsoluteTimeGetCurrent()
    mutating func lap() -> Double {
        let now = CFAbsoluteTimeGetCurrent()
        defer { last = now }
        return now - last
    }
}
