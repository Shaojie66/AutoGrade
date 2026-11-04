import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Output frame shape for reframing (CLAUDE.md 重构图). Fixed platform sizes.
public enum Aspect: String, CaseIterable, Sendable {
    case vertical9x16 = "9:16"
    case horizontal16x9 = "16:9"

    public var outputSize: (width: Int, height: Int) {
        self == .vertical9x16 ? (1080, 1920) : (1920, 1080)
    }

    var ratio: Double { self == .vertical9x16 ? 9.0 / 16.0 : 16.0 / 9.0 }

    /// The largest crop of this aspect in a `width` x `height` frame, and the
    /// axis it slides along (0 = x, 1 = y). Only translation, never zoom.
    public func crop(width: Int, height: Int) -> (length: SIMD2<Float>, axis: Int) {
        Aspect.largestCrop(ratio: ratio, width: width, height: height)
    }

    /// Shared with `CoverAspect` (CLAUDE.md 封面: the same crop rule).
    static func largestCrop(ratio: Double, width: Int, height: Int) -> (length: SIMD2<Float>, axis: Int) {
        let w = Double(width), h = Double(height)
        if w / h > ratio { return (SIMD2(Float(h * ratio), Float(h)), 0) }
        return (SIMD2(Float(w), Float(w / ratio)), 1)
    }
}

/// Where the subject is in each frame (CLAUDE.md 重构图: faces, then people,
/// then objectness saliency). Normalised [0,1] frame coordinates, top-left origin.
public struct SubjectTrack: Sendable {
    public enum Source: String, Sendable { case face, human, saliency }

    public struct Sample: Sendable {
        public let center: SIMD2<Float>
        public let size: SIMD2<Float>
        public let source: Source

        public init(center: SIMD2<Float>, size: SIMD2<Float>, source: Source) {
            self.center = center
            self.size = size
            self.source = source
        }
    }

    /// One entry per analysed frame; nil = nothing found.
    public let samples: [Sample?]
    public let seconds: Double

    public init(samples: [Sample?], seconds: Double = 0) {
        self.samples = samples
        self.seconds = seconds
    }

    public func count(_ source: Source) -> Int { samples.filter { $0?.source == source }.count }
}

/// Each frame's crop rectangle in source pixels, and how each shot was decided.
public struct CropPath: Sendable {
    public enum Mode: String, Sendable { case fixed, follow, manual }

    public let aspect: Aspect
    public let length: SIMD2<Float>
    public let axis: Int
    public let origins: [SIMD2<Float>]      // per frame
    public let modes: [Mode]                // per shot
    public let centers: [Float]             // per frame, crop centre along `axis`, normalised

    public var outputSize: (width: Int, height: Int) { aspect.outputSize }
}

public enum Reframe {
    /// Path parameters (CLAUDE.md 重构图; tune there first).
    public static let smoothingSeconds = 0.8          // Gaussian sigma
    public static let maxSpeed: Float = 0.6           // crop lengths per second
    public static let fitMargin: Float = 0.1          // of the crop length, each side
    /// Shots shorter than this share the path of the shot before them (the first
    /// one: the shot after). Over-cut clips (CLAUDE.md 已知坑: 1-2 frame "shots")
    /// would otherwise get a new crop every frame. Grading is not affected.
    public static let minSegmentSeconds = 1.0

    /// Consecutive shots grouped for the path: each group starts at a shot that is
    /// at least `minSegmentSeconds` long (or at the first shot).
    static func segments(_ shots: [Shot], _ times: [CMTime]) -> [ClosedRange<Int>] {
        func long(_ s: Shot) -> Bool { Double(s.frames) * frameDuration(times, s.first...s.last) >= minSegmentSeconds }
        var groups: [ClosedRange<Int>] = [], groupHasLong = false
        for k in shots.indices {
            let isLong = long(shots[k])
            // a short shot joins the group before; leading short shots wait for the first long one
            if let last = groups.last, !isLong || !groupHasLong {
                groups[groups.count - 1] = last.lowerBound...k
                groupHasLong = groupHasLong || isLong
            } else {
                groups.append(k...k)
                groupHasLong = isLong
            }
        }
        return groups
    }

    /// The crop for every frame. `overrides[k]`: shot k fixed at that normalised
    /// centre (manual). Each shot is computed on its own: no smoothing across cuts.
    public static func path(track: SubjectTrack, shots: [Shot], frameTimes: [CMTime], width: Int, height: Int,
                            aspect: Aspect, overrides: [Float?]) -> CropPath {
        precondition(track.samples.count == frameTimes.count && overrides.count == shots.count)
        let (length, axis) = aspect.crop(width: width, height: height)
        let extent = Float(axis == 0 ? width : height), crop = length[axis]
        let half = crop / 2, lo = half, hi = extent - half
        var centers = [Float](repeating: extent / 2, count: frameTimes.count), modes: [CropPath.Mode] = []

        for group in segments(shots, frameTimes) {
            let range = shots[group.lowerBound].first...shots[group.upperBound].last
            let mode: CropPath.Mode
            defer { modes += Array(repeating: mode, count: group.count) }
            let manual = group.lazy.compactMap { overrides[$0] }.first
            if crop >= extent - 0.5 {                       // nothing to slide
                mode = manual == nil ? .fixed : .manual
                continue
            }
            if let manual {
                for f in range { centers[f] = min(max(manual * extent, lo), hi) }
                mode = .manual
                continue
            }
            let raw = filled(range.map { track.samples[$0].map { $0.center[axis] * extent } }, default: extent / 2)
            let sorted = raw.sorted()
            let q05 = quantile(sorted, 0.05), q95 = quantile(sorted, 0.95)
            if q95 - q05 <= crop * (1 - 2 * fitMargin) {
                let c = min(max(quantile(sorted, 0.5), lo), hi)
                for f in range { centers[f] = c }
                mode = .fixed
                continue
            }
            let dt = frameDuration(frameTimes, range)
            // smooth, limit the speed, smooth again: the limiter alone turns at full
            // speed (11.7 px/frame² at a swing's ends, measured 2026-11-03); a second
            // Gaussian rounds those turns and, being an average, keeps the speed limit.
            let sigma = Float(smoothingSeconds / dt)
            let limited = gaussian(speedLimited(gaussian(raw, sigma: sigma), step: maxSpeed * crop * Float(dt)), sigma: sigma)
            for (i, f) in range.enumerated() { centers[f] = min(max(limited[i], lo), hi) }
            mode = .follow
        }
        let origins = centers.map { c -> SIMD2<Float> in axis == 0 ? SIMD2(c - half, 0) : SIMD2(0, c - half) }
        return CropPath(aspect: aspect, length: length, axis: axis, origins: origins, modes: modes,
                        centers: centers.map { $0 / extent })
    }

    // MARK: path helpers (internal for tests)

    /// Missing samples: linear between neighbours, held at the ends; all missing -> `default`.
    static func filled(_ values: [Float?], default fallback: Float) -> [Float] {
        let known = values.enumerated().compactMap { i, v in v.map { (i, $0) } }
        guard let first = known.first, let last = known.last else { return values.map { _ in fallback } }
        var out = [Float](repeating: 0, count: values.count), j = 0
        for i in values.indices {
            if i <= first.0 { out[i] = first.1; continue }
            if i >= last.0 { out[i] = last.1; continue }
            while known[j + 1].0 < i { j += 1 }
            let (a, va) = known[j], (b, vb) = known[j + 1]
            out[i] = va + (vb - va) * Float(i - a) / Float(b - a)
        }
        return out
    }

    static func quantile(_ sorted: [Float], _ q: Float) -> Float {
        let x = q * Float(sorted.count - 1), i = Int(x), f = x - Float(i)
        return i + 1 < sorted.count ? sorted[i] * (1 - f) + sorted[i + 1] * f : sorted[i]
    }

    /// Zero-phase Gaussian. Past the shot's ends the track is extended by point
    /// reflection about the end (x[-k] = 2·a − x[k]), so a steady pan stays exactly
    /// linear up to the cut; dropping and renormalising the window lagged 7 px
    /// mid-shot and ~60 px at the ends. The anchor `a` is a straight-line fit over
    /// the last ~2σ frames (robust, `lineAt`), not the end sample itself: reflecting
    /// about one noisy sample pinned the path's ends to it (2026-11-04, car-window clip).
    static func gaussian(_ x: [Float], sigma: Float) -> [Float] {
        guard sigma > 0.01, x.count > 1 else { return x }
        let r = Int((3 * sigma).rounded(.up)), n = x.count
        let w = (-r...r).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let norm = w.reduce(0, +)
        let m = min(n, max(3, Int((2 * sigma).rounded())))
        let head = lineAt(Array(x[0..<m]), 0), tail = lineAt(Array(x[(n - m)...].reversed()), 0)
        func at(_ i: Int) -> Float {
            if i < 0 { return 2 * head - at(-i) }
            if i >= n { return 2 * tail - at(2 * (n - 1) - i) }
            return x[i]
        }
        return x.indices.map { i in (-r...r).reduce(Float(0)) { $0 + w[$1 + r] * at(i + $1) } / norm }
    }

    /// Theil–Sen line through `y` (at 0, 1, 2, …), evaluated at `t`: median of the
    /// pairwise slopes, median intercept. Robust to a bad end sample, which a
    /// least-squares fit weights most (it still moved the start 196 px, 2026-11-04).
    static func lineAt(_ y: [Float], _ t: Float) -> Float {
        guard y.count > 1 else { return y.first ?? 0 }
        var slopes: [Float] = []
        for i in y.indices { for j in (i + 1)..<y.count { slopes.append((y[j] - y[i]) / Float(j - i)) } }
        slopes.sort()
        let slope = quantile(slopes, 0.5)
        let intercepts = y.enumerated().map { $1 - slope * Float($0) }.sorted()
        return quantile(intercepts, 0.5) + slope * t
    }

    /// At most `step` per frame: forward and backward limited passes, averaged, so
    /// the result has no lag direction and still moves at most `step` per frame.
    static func speedLimited(_ x: [Float], step: Float) -> [Float] {
        guard x.count > 1 else { return x }
        var f = x, b = x
        for i in 1..<x.count { f[i] = min(max(x[i], f[i - 1] - step), f[i - 1] + step) }
        for i in stride(from: x.count - 2, through: 0, by: -1) { b[i] = min(max(x[i], b[i + 1] - step), b[i + 1] + step) }
        return zip(f, b).map { ($0 + $1) / 2 }
    }

    static func frameDuration(_ times: [CMTime], _ range: ClosedRange<Int>) -> Double {
        guard range.count > 1 else { return 1.0 / 30 }
        let span = (times[range.upperBound] - times[range.lowerBound]).seconds
        return max(span / Double(range.count - 1), 1e-3)
    }

    // MARK: detection

    /// Find the subject in one frame (decoder planes, any orientation-free 420v buffer).
    static func detect(_ pixels: CVPixelBuffer) throws -> SubjectTrack.Sample? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
        let faces = VNDetectFaceRectanglesRequest()
        try handler.perform([faces])
        if let s = weighted(faces.results?.map { ($0.boundingBox, Float(1)) } ?? [], .face) { return s }
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        try handler.perform([humans])
        if let s = weighted(humans.results?.map { ($0.boundingBox, $0.confidence) } ?? [], .human) { return s }
        // Objectness, not attention: attention saliency is pulled toward the frame
        // centre (measured 2026-11-03 on synthetic_subject: 68 px off vs 4 px).
        let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
        try handler.perform([saliency])
        let objects = saliency.results?.first?.salientObjects ?? []
        return weighted(objects.map { ($0.boundingBox, $0.confidence) }, .saliency)
    }

    /// Area x confidence weighted centre of Vision boxes (bottom-left origin) -> top-left.
    static func weighted(_ boxes: [(CGRect, Float)], _ source: SubjectTrack.Source) -> SubjectTrack.Sample? {
        var cx: Float = 0, cy: Float = 0, total: Float = 0, w: Float = 0, h: Float = 0
        for (box, confidence) in boxes {
            let weight = Float(box.width * box.height) * max(confidence, 0.01)
            guard weight > 0 else { continue }
            cx += weight * Float(box.midX)
            cy += weight * Float(1 - box.midY)
            w = max(w, Float(box.width))
            h = max(h, Float(box.height))
            total += weight
        }
        guard total > 0 else { return nil }
        return .init(center: SIMD2(cx / total, cy / total), size: SIMD2(w, h), source: source)
    }
}

extension AutoGrader {
    /// One pass over the video finding the subject in every frame (CLAUDE.md 重构图).
    /// Independent of grading: styles and cut edits never need it again.
    public func detectSubjects(_ url: URL, analysis: Analysis, cancel: CancelToken? = nil,
                               progress: ((Int) -> Void)? = nil) throws -> SubjectTrack {
        let start = CFAbsoluteTimeGetCurrent()
        let reader = try VideoReader(url: url, device: metal.device)
        var samples: [SubjectTrack.Sample?] = []
        while let frame = try reader.next() {
            if cancel?.isCancelled == true { throw Cancelled() }
            samples.append(try Reframe.detect(frame.pixelBuffer))
            progress?(frame.index)
        }
        guard samples.count == analysis.frameCount else {
            throw VideoError.reader("subject detection decoded \(samples.count) frames, analysis saw \(analysis.frameCount)")
        }
        return SubjectTrack(samples: samples, seconds: CFAbsoluteTimeGetCurrent() - start)
    }
}
