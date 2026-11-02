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

/// Result of pass 1, and the state cut editing works on. Preview and export
/// both read this (CLAUDE.md 架构原则 3). `sums` are the unclamped per-shot
/// sums of baked LUTs; `luts` are their clamped means (CLAUDE.md, 切点编辑).
/// Edits return a new Analysis and never write into an existing buffer.
public struct Analysis {
    public let info: VideoInfo
    public let lutSize: Int
    public let frameTimes: [CMTime]
    public let shots: [Shot]
    public let sums: [LUT3D]
    public let luts: [LUT3D]
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
    public let grader: Grader

    public init(computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        metal = try MetalContext()
        kernels = GradeKernels(metal: metal)
        grader = try Grader(kernels: kernels, computeUnits: computeUnits)
    }

    // MARK: pass 1

    public func analyze(_ url: URL, lutSize: Int = 65, cutThreshold: Float = ShotDetector.defaultThreshold,
                        cancel: CancelToken? = nil, progress: ((Int) -> Void)? = nil) throws -> Analysis {
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
            let (baked, thumb) = try analyzeFrame(frame, lutSize: lutSize, thumbnail: true, times: &times, clock: &clock)
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
                        luts: luts, times: times, warnings: reader.warnings)
    }

    /// One frame of pass 1: its AiLUT baked to lutSize^3, and (optionally) the
    /// shot-detection thumbnail.
    private func analyzeFrame(_ frame: DecodedFrame, lutSize: Int, thumbnail: Bool,
                              times: inout StageTimes, clock: inout Clock) throws -> (LUT3D, [Float]?) {
        let rgb = try kernels.yuvToRGB(luma: frame.luma, chroma: frame.chroma)
        times.convert += clock.lap()
        let small = try kernels.resize(rgb, width: Grader.inputSide, height: Grader.inputSide)
        let thumb = thumbnail
            ? try kernels.resize(rgb, width: ShotDetector.thumbnailWidth, height: ShotDetector.thumbnailHeight).floats()
            : nil
        times.resize += clock.lap()
        let ai = try grader.predict(small)
        times.predict += clock.lap()
        let baked = try kernels.bake(ai, size: lutSize)
        times.bake += clock.lap()
        return (baked, thumb)
    }

    // MARK: cut editing

    /// Remove the cut in front of shot `index` (index >= 1): it merges into the
    /// shot before it. Exact — the sums add — so nothing is re-analysed.
    public func removeCut(_ analysis: Analysis, beforeShot index: Int) throws -> Analysis {
        precondition(index >= 1 && index < analysis.shots.count)
        let a = analysis.shots[index - 1], b = analysis.shots[index]
        let sum = try kernels.makeLUT(size: analysis.lutSize)
        try kernels.accumulate(sum, analysis.sums[index - 1])
        try kernels.accumulate(sum, analysis.sums[index])
        let merged = Shot(first: a.first, last: b.last)
        return try replacing(analysis, shots: (index - 1)...index, with: [(merged, sum)])
    }

    /// Add a cut so that `frame` starts a new shot. Only the shot being split
    /// is decoded again; both halves' sums come out of that one pass.
    public func addCut(_ analysis: Analysis, source url: URL, atFrame frame: Int,
                       cancel: CancelToken? = nil, progress: ((Int) -> Void)? = nil) throws -> Analysis {
        let k = analysis.shotIndex(forFrame: frame)
        let shot = analysis.shots[k]
        precondition(frame > shot.first && frame <= shot.last, "frame \(frame) is already a shot start")
        let reader = try VideoReader(url: url, device: metal.device,
                                     timeRange: analysis.timeRange(first: shot.first, last: shot.last),
                                     frameTimes: analysis.frameTimes)
        let before = try kernels.makeLUT(size: analysis.lutSize), after = try kernels.makeLUT(size: analysis.lutSize)
        var seen = 0, times = StageTimes(), clock = Clock()
        while let f = try reader.next(), f.index <= shot.last {
            if cancel?.isCancelled == true { throw Cancelled() }
            let (baked, _) = try analyzeFrame(f, lutSize: analysis.lutSize, thumbnail: false, times: &times, clock: &clock)
            try kernels.accumulate(f.index < frame ? before : after, baked)
            seen += 1
            progress?(f.index)
        }
        guard seen == shot.frames else {
            throw VideoError.reader("re-analysing shot \(k) decoded \(seen) frames, expected \(shot.frames)")
        }
        return try replacing(analysis, shots: k...k, with: [(Shot(first: shot.first, last: frame - 1), before),
                                                            (Shot(first: frame, last: shot.last), after)])
    }

    private func replacing(_ a: Analysis, shots range: ClosedRange<Int>, with parts: [(Shot, LUT3D)]) throws -> Analysis {
        var shots = a.shots, sums = a.sums, luts = a.luts
        shots.replaceSubrange(range, with: parts.map(\.0))
        sums.replaceSubrange(range, with: parts.map(\.1))
        luts.replaceSubrange(range, with: try parts.map { try kernels.mean($0.1, frames: $0.0.frames) })
        return Analysis(info: a.info, lutSize: a.lutSize, frameTimes: a.frameTimes, shots: shots, sums: sums,
                        luts: luts, times: a.times, warnings: a.warnings)
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
    public func preview(_ frame: DecodedFrame, lut: LUT3D, into targets: PreviewTargets) throws {
        try metal.run { enc in
            try kernels.encodeGradeFrame(into: enc, luma: frame.luma, chroma: frame.chroma, lut: lut,
                                         scratch: targets.scratch, graded: targets.graded, original: targets.original)
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

    /// Encode the video with one final LUT per shot (`finalLUTs`). On error or
    /// cancellation the partial output — a file this call created — is removed.
    /// `frameHook` sees each graded BGRA buffer before it is appended (tests).
    public func render(_ url: URL, analysis: Analysis, luts: [LUT3D], to output: URL, codec: OutputCodec = .hevc,
                       cancel: CancelToken? = nil, progress: ((Int) -> Void)? = nil,
                       frameHook: ((Int, CVPixelBuffer) -> Void)? = nil) throws -> StageTimes {
        precondition(luts.count == analysis.shots.count)
        let reader = try VideoReader(url: url, device: metal.device)
        let writer = try VideoWriter(url: output, width: reader.info.width, height: reader.info.height,
                                     codec: codec, device: metal.device)
        do {
            let scratch = (try kernels.makeImage(width: reader.info.width, height: reader.info.height),
                           try kernels.makeImage(width: reader.info.width, height: reader.info.height))
            var times = StageTimes()
            var clock = Clock()
            while let frame = try reader.next() {
                if cancel?.isCancelled == true { throw Cancelled() }
                times.decode += clock.lap()
                let (pixels, texture, textureRef) = try writer.makeFrame()
                try metal.run { enc in
                    try kernels.encodeGradeFrame(into: enc, luma: frame.luma, chroma: frame.chroma,
                                                 lut: luts[analysis.shotIndex(forFrame: frame.index)],
                                                 scratch: scratch, graded: texture, original: nil)
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
            return times
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
            try CubeWriter.write(lut, title: "AutoGrade \(prefix) shot \(k) (frames \(shot.first)-\(shot.last))", to: url)
            return url
        }
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
