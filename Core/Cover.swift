import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Cover still shapes (CLAUDE.md 封面). Separate from the video's `Aspect`, so
/// the reframe menu never offers 3:4 or 4:3; the crop rule is the same.
public enum CoverAspect: String, CaseIterable, Sendable {
    case portrait3x4 = "3:4"
    case landscape4x3 = "4:3"
    case landscape16x9 = "16:9"
    case original = "orig"

    /// The file-name tag: 3x4, 4x3, 16x9, orig.
    public var tag: String { rawValue.replacingOccurrences(of: ":", with: "x") }

    var ratio: Double? {
        switch self {
        case .portrait3x4: 3.0 / 4.0
        case .landscape4x3: 4.0 / 3.0
        case .landscape16x9: 16.0 / 9.0
        case .original: nil
        }
    }

    public func outputSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        switch self {
        case .portrait3x4: (1080, 1440)
        case .landscape4x3: (1440, 1080)
        case .landscape16x9: (1920, 1080)
        case .original: (sourceWidth, sourceHeight)
        }
    }

    /// The largest crop of this shape and the axis it slides along; the whole
    /// frame for `original`.
    public func crop(width: Int, height: Int) -> (length: SIMD2<Float>, axis: Int) {
        guard let ratio else { return (SIMD2(Float(width), Float(height)), 0) }
        return Aspect.largestCrop(ratio: ratio, width: width, height: height)
    }
}

public enum CoverFormat: String, CaseIterable, Sendable {
    case png, jpeg

    public var fileExtension: String { self == .png ? "png" : "jpg" }
    var type: UTType { self == .png ? .png : .jpeg }
}

/// Per-frame features of the cover scan, from the decoder's luma only
/// (CLAUDE.md 封面 / 逐帧特征). Cut edits only change the scores, never these.
public struct CoverFeatures: Sendable {
    public var sharpness: [Double] = []     // variance of the 4-neighbour Laplacian
    public var hi: [Double] = []            // share of Y' >= 0.98
    public var lo: [Double] = []            // share of Y' <= 0.02
    public var mean: [Double] = []
    public var diffPrevious: [Double] = []  // mean |Y'(i) - Y'(i-1)|; 0 for the first frame
    public var diffNext: [Double] = []      // mean |Y'(i+1) - Y'(i)|; 0 for the last frame

    public var count: Int { sharpness.count }
    public init() {}
}

/// What the scan found: the features, and the subject track it used (the
/// reframe's, or detected in the same pass).
public struct CoverScan: Sendable {
    public let features: CoverFeatures
    public let track: SubjectTrack
    public let seconds: Double
}

public enum Cover {
    // CLAUDE.md 封面 — change the rules there first, then here and in make_fixtures.py.
    public static let analysisHeight = 360
    public static let weights = (sharpness: 0.4, exposure: 0.3, face: 0.2, motion: 0.1)
    static let clipHigh = 0.98, clipLow = 0.02, clipBudget = 0.10
    static let targetMean = 0.45, meanSpan = 0.55
    static let faceFullArea = 0.04, edgeMargin = 0.05, edgeFactor = 0.5
    static let transitionShare = 0.1, transitionMin = 0.2, transitionMax = 0.5, transitionFloor = 0.5
    public static let minShotSeconds = Reframe.minSegmentSeconds
    static let percentile = 0.95
    public static let defaultCount = 3
    public static let defaultAspects: [CoverAspect] = [.portrait3x4, .landscape16x9]
    public static let jpegQuality = 0.92

    // MARK: features

    /// Height > 360: scale to 360 high, width rounded half up; otherwise unchanged.
    public static func analysisSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard height > analysisHeight else { return (width, height) }
        return (Int((Double(width) * Double(analysisHeight) / Double(height) + 0.5).rounded(.down)), analysisHeight)
    }

    /// Y' = clamp((Y - 16) / 219, 0, 1) of a '420v' buffer, at the analysis size.
    /// Bilinear, align_corners=False, no antialias (PyTorch's formula); the clamp
    /// is applied per source sample, as numpy clamps before resizing.
    public static func luma(_ pixels: CVPixelBuffer) -> (width: Int, height: Int, values: [Double]) {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pixels, 0), h = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
        let table = (0..<256).map { min(max((Double($0) - 16) / 219, 0), 1) }
        let (aw, ah) = analysisSize(width: w, height: h)
        if (aw, ah) == (w, h) {
            var out = [Double](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { out[y * w + x] = table[Int(base[y * row + x])] } }
            return (w, h, out)
        }
        return (aw, ah, resize(width: w, height: h, toWidth: aw, toHeight: ah) { x, y in table[Int(base[y * row + x])] })
    }

    /// Bilinear resize, align_corners=False: source = (i + 0.5)·scale − 0.5, clamped at 0.
    public static func resize(width: Int, height: Int, toWidth: Int, toHeight: Int, _ at: (Int, Int) -> Double) -> [Double] {
        func taps(_ n: Int, _ out: Int) -> [(Int, Int, Double)] {
            let scale = Double(n) / Double(out)
            return (0..<out).map { i in
                let s = max((Double(i) + 0.5) * scale - 0.5, 0)
                let i0 = min(Int(s), n - 1)
                return (i0, min(i0 + 1, n - 1), s - Double(i0))
            }
        }
        let xs = taps(width, toWidth), ys = taps(height, toHeight)
        var out = [Double](repeating: 0, count: toWidth * toHeight)
        for (j, (y0, y1, fy)) in ys.enumerated() {
            for (i, (x0, x1, fx)) in xs.enumerated() {
                let top = at(x0, y0) * (1 - fx) + at(x1, y0) * fx
                let bottom = at(x0, y1) * (1 - fx) + at(x1, y1) * fx
                out[j * toWidth + i] = top * (1 - fy) + bottom * fy
            }
        }
        return out
    }

    public static func frameFeatures(_ y: [Double], width w: Int, height h: Int)
        -> (sharpness: Double, hi: Double, lo: Double, mean: Double) {
        var sum = 0.0, sumSq = 0.0, n = 0.0
        if w > 2 && h > 2 {
            for r in 1..<(h - 1) {
                for c in 1..<(w - 1) {
                    let i = r * w + c
                    let l = 4 * y[i] - y[i - w] - y[i + w] - y[i - 1] - y[i + 1]
                    sum += l
                    sumSq += l * l
                    n += 1
                }
            }
        }
        let m = n > 0 ? sum / n : 0
        let variance = n > 0 ? max(sumSq / n - m * m, 0) : 0
        var hi = 0, lo = 0, total = 0.0
        for v in y {
            if v >= clipHigh { hi += 1 }
            if v <= clipLow { lo += 1 }
            total += v
        }
        let count = Double(y.count)
        return (variance, Double(hi) / count, Double(lo) / count, total / count)
    }

    static func meanAbsDifference(_ a: [Double], _ b: [Double]) -> Double {
        precondition(a.count == b.count)
        var s = 0.0
        for i in a.indices { s += abs(a[i] - b[i]) }
        return s / Double(a.count)
    }

    // MARK: scores

    public struct Scores: Sendable {
        /// Sharpness normalised within each shot: picks the frame of a shot.
        public let pick: [Double]
        /// Sharpness normalised over the whole video: ranks the shots' picks.
        public let rank: [Double]
    }

    public struct Candidate: Sendable, Equatable {
        public let shot: Int
        public let frame: Int
        public let pick: Double
        public let rank: Double
    }

    /// `score = (0.4 S + 0.3 E + 0.2 F + 0.1 M) · T` (CLAUDE.md 封面 / 分数). `faces`
    /// are the subject track's samples; only `.face` ones count.
    public static func scores(_ f: CoverFeatures, faces: [SubjectTrack.Sample?], shots: [Shot],
                              frameTimes: [CMTime]) -> Scores {
        precondition(f.count == frameTimes.count && faces.count == f.count)
        let n = f.count, seconds = frameTimes.map(\.seconds)
        let exposure = (0..<n).map { i in
            clamp01(1 - (f.hi[i] + f.lo[i]) / clipBudget) * clamp01(1 - abs(f.mean[i] - targetMean) / meanSpan)
        }
        let face = faces.map { s -> Double in
            guard let s, s.source == .face else { return 0 }
            let cx = Double(s.center.x), cy = Double(s.center.y), w = Double(s.size.x), h = Double(s.size.y)
            let edge = min(cx - w / 2, cy - h / 2, 1 - (cx + w / 2), 1 - (cy + h / 2)) < edgeMargin
            return min(1, w * h / faceFullArea) * (edge ? edgeFactor : 1)
        }
        var motion = [Double](repeating: 0, count: n), transition = [Double](repeating: 1, count: n)
        for shot in shots {
            let dur = Double(shot.frames) * Reframe.frameDuration(frameTimes, shot.first...shot.last)
            let window = min(max(transitionShare * dur, transitionMin), transitionMax)
            for i in shot.first...shot.last {
                var sides: [Double] = []
                if i > shot.first { sides.append(f.diffPrevious[i]) }
                if i < shot.last { sides.append(f.diffNext[i]) }
                motion[i] = sides.isEmpty ? 0 : sides.reduce(0, +) / Double(sides.count)
                let d = min(seconds[i] - seconds[shot.first], seconds[shot.last] - seconds[i])
                transition[i] = d >= window ? 1 : transitionFloor + (1 - transitionFloor) * d / window
            }
        }
        let pMotion = quantile(motion.sorted(), percentile)
        let blur: [Double] = motion.map { pMotion <= 1e-12 ? 1 : 1 - clamp01($0 / pMotion) }
        func total(_ sharp: [Double]) -> [Double] {
            (0..<n).map { (i: Int) -> Double in
                let s: Double = weights.sharpness * sharp[i] + weights.exposure * exposure[i]
                let rest: Double = weights.face * face[i] + weights.motion * blur[i]
                return (s + rest) * transition[i]
            }
        }
        return Scores(pick: total(normalisedSharpness(f.sharpness, ranges: shots.map { $0.first...$0.last })),
                      rank: total(normalisedSharpness(f.sharpness, ranges: [0...(n - 1)])))
    }

    static func normalisedSharpness(_ raw: [Double], ranges: [ClosedRange<Int>]) -> [Double] {
        var out = [Double](repeating: 0, count: raw.count)
        for r in ranges {
            let p = quantile(raw[r].sorted(), percentile)
            guard p > 1e-12 else { continue }
            for i in r { out[i] = clamp01(raw[i] / p) }
        }
        return out
    }

    /// Each eligible shot's best frame (first on ties), ordered by rank score
    /// (earlier frame on ties). Shots under `minShotSeconds` are left out unless all are.
    public static func candidates(_ s: Scores, shots: [Shot], frameTimes: [CMTime]) -> [Candidate] {
        func long(_ shot: Shot) -> Bool {
            Double(shot.frames) * Reframe.frameDuration(frameTimes, shot.first...shot.last) >= minShotSeconds
        }
        let eligible = shots.indices.filter { long(shots[$0]) }
        let picked = (eligible.isEmpty ? Array(shots.indices) : eligible).map { k -> Candidate in
            var best = shots[k].first
            for i in shots[k].first...shots[k].last where s.pick[i] > s.pick[best] { best = i }
            return Candidate(shot: k, frame: best, pick: s.pick[best], rank: s.rank[best])
        }
        return picked.sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.frame < $1.frame }
    }

    // MARK: framing

    /// The crop centre (normalised, top-left origin): this frame's face, else its
    /// person / saliency sample, else the median of the shot's samples, else the middle.
    public static func center(frame i: Int, track: SubjectTrack, shot: Shot) -> SIMD2<Float> {
        if let s = track.samples[i] { return s.center }
        let known = (shot.first...shot.last).compactMap { track.samples[$0]?.center }
        guard !known.isEmpty else { return SIMD2(0.5, 0.5) }
        let xs = known.map { Double($0.x) }.sorted(), ys = known.map { Double($0.y) }.sorted()
        return SIMD2(Float(quantile(xs, 0.5)), Float(quantile(ys, 0.5)))
    }

    /// Crop origin and length in source pixels: slide along the crop's axis to
    /// centre `center`, kept inside the frame.
    public static func crop(center: SIMD2<Float>, aspect: CoverAspect, width: Int, height: Int)
        -> (origin: SIMD2<Float>, length: SIMD2<Float>) {
        let (length, axis) = aspect.crop(width: width, height: height)
        let extent = Float(axis == 0 ? width : height), crop = length[axis]
        var origin = SIMD2<Float>(0, 0)
        if crop < extent - 0.5 { origin[axis] = min(max(center[axis] * extent - crop / 2, 0), extent - crop) }
        return (origin, length)
    }

    /// `<prefix>_cover<rank>_shot<NN>_f<NNNN>_<tag>.<ext>`; rank from 1, shot from 0.
    public static func fileName(prefix: String, rank: Int, shot: Int, frame: Int, aspect: CoverAspect,
                                format: CoverFormat) -> String {
        String(format: "%@_cover%d_shot%02d_f%04d_%@.%@", prefix, rank, shot, frame, aspect.tag, format.fileExtension)
    }

    // MARK: helpers

    static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// Linear interpolation between order statistics (numpy's default; Reframe.quantile in Double).
    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let x = q * Double(sorted.count - 1), i = Int(x), f = x - Double(i)
        return i + 1 < sorted.count ? sorted[i] * (1 - f) + sorted[i + 1] * f : sorted[i]
    }
}

// MARK: - scan, render, write

extension AutoGrader {
    /// The cover scan (CLAUDE.md 封面): one pass computing every frame's features,
    /// and detecting the subject in the same pass when `track` is nil.
    public func coverScan(_ url: URL, analysis: Analysis, track: SubjectTrack? = nil, cancel: CancelToken? = nil,
                          progress: ((Int) -> Void)? = nil) throws -> CoverScan {
        let start = CFAbsoluteTimeGetCurrent()
        let reader = try VideoReader(url: url, device: metal.device)
        var f = CoverFeatures(), samples: [SubjectTrack.Sample?] = [], previous: [Double]?
        while let frame = try reader.next() {
            if cancel?.isCancelled == true { throw Cancelled() }
            let (w, h, y) = Cover.luma(frame.pixelBuffer)
            let (sharpness, hi, lo, mean) = Cover.frameFeatures(y, width: w, height: h)
            f.sharpness.append(sharpness)
            f.hi.append(hi)
            f.lo.append(lo)
            f.mean.append(mean)
            let d = previous.map { Cover.meanAbsDifference(y, $0) } ?? 0
            f.diffPrevious.append(d)
            if !f.diffNext.isEmpty { f.diffNext[f.diffNext.count - 1] = d }
            f.diffNext.append(0)
            previous = y
            if track == nil { samples.append(try Reframe.detect(frame.pixelBuffer)) }
            progress?(frame.index)
        }
        guard f.count == analysis.frameCount else {
            throw VideoError.reader("cover scan decoded \(f.count) frames, analysis saw \(analysis.frameCount)")
        }
        let seconds = CFAbsoluteTimeGetCurrent() - start
        return CoverScan(features: f, track: track ?? SubjectTrack(samples: samples, seconds: seconds), seconds: seconds)
    }

    /// The cover's pixels: the export's frame (`decodeFrame(…, exact: true)` with the
    /// export's enhancer), its shot's final LUT, cropped and resized — the same
    /// `encodeGradeFrame` the export uses, without subtitles. BGRA8, rows packed.
    public func renderCover(_ frame: EnhancedFrame, lut: LUT3D, aspect: CoverAspect, center: SIMD2<Float>,
                            into targets: CoverTargets) throws -> [UInt8] {
        precondition(targets.aspect == aspect)
        let f = frame.frame
        let (origin, length) = Cover.crop(center: center, aspect: aspect, width: targets.sourceWidth,
                                          height: targets.sourceHeight)
        try metal.run { enc in
            if let cropped = targets.cropped {
                try kernels.encodeGradeFrame(into: enc, luma: f.luma, chroma: f.chroma, lut: lut, scratch: targets.scratch,
                                             crop: origin, length: length, cropped: cropped, output: targets.output,
                                             background: frame.background)
            } else {
                try kernels.encodeGradeFrame(into: enc, luma: f.luma, chroma: f.chroma, lut: lut, scratch: targets.scratch,
                                             graded: targets.output, original: nil, background: frame.background)
            }
        }
        let (w, h) = (targets.output.width, targets.output.height)
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        targets.output.getBytes(&bgra, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return bgra
    }
}

/// GPU targets for one cover shape and source size, reused across covers.
public final class CoverTargets {
    public let aspect: CoverAspect
    public let sourceWidth: Int
    public let sourceHeight: Int
    let output: MTLTexture
    let cropped: PlanarImage?          // nil for `original`: graded at source size
    let scratch: (rgb: PlanarImage, graded: PlanarImage)

    public init(kernels: GradeKernels, sourceWidth: Int, sourceHeight: Int, aspect: CoverAspect) throws {
        self.aspect = aspect
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        let (w, h) = aspect.outputSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        output = try kernels.makeDisplayTexture(width: w, height: h)
        cropped = aspect == .original ? nil : try kernels.makeImage(width: w, height: h)
        scratch = (try kernels.makeImage(width: sourceWidth, height: sourceHeight),
                   try kernels.makeImage(width: sourceWidth, height: sourceHeight))
    }
}

/// The check after writing a cover (CLAUDE.md 封面 / 写完自检).
public struct CoverCheck: Sendable {
    public let url: URL
    public var meanAbs = 0.0           // levels, decoded file vs the pixels written
    public var maxAbs = 0
    public var failures: [String] = []
    public var passed: Bool { failures.isEmpty }
}

public enum CoverWriter {
    /// JPEG: mean error over RGB vs the pixels written (CLAUDE.md 容差表).
    public static let maxJPEGMeanAbs = 2.0

    public enum WriteError: Error, CustomStringConvertible {
        case exists(URL)
        case encode(String)

        public var description: String {
            switch self {
            case .exists(let url): "\(url.path) already exists"
            case .encode(let why): "could not write the cover: \(why)"
            }
        }
    }

    /// Write packed BGRA8 as 8-bit RGB, tagged sRGB, values unchanged; then read
    /// it back and compare. A failed check keeps the file and lists why.
    public static func write(bgra: [UInt8], width: Int, height: Int, to url: URL, format: CoverFormat,
                             overwrite: Bool = false) throws -> CoverCheck {
        precondition(bgra.count == width * height * 4)
        if FileManager.default.fileExists(atPath: url.path) {
            guard overwrite else { throw WriteError.exists(url) }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil)
        else { throw WriteError.encode("image setup") }
        let options: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: Cover.jpegQuality] : [:]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw WriteError.encode("ImageIO finalize") }
        return recheck(url, bgra: bgra, width: width, height: height, format: format)
    }

    /// Compare a written cover against the pixels it should hold.
    public static func recheck(_ url: URL, bgra: [UInt8], width: Int, height: Int, format: CoverFormat) -> CoverCheck {
        var report = CoverCheck(url: url)
        guard let decoded = readRGB(url) else {
            report.failures.append("the written file could not be decoded")
            return report
        }
        if (decoded.width, decoded.height) != (width, height) {
            report.failures.append("size \(decoded.width)x\(decoded.height), expected \(width)x\(height)")
            return report
        }
        if decoded.colourSpace != (CGColorSpace.sRGB as String) {
            report.failures.append("colour space \(decoded.colourSpace ?? "none"), expected sRGB")
        }
        var sum = 0, worst = 0
        for i in 0..<(width * height) {
            for (c, byte) in [(0, 2), (1, 1), (2, 0)] {
                let d = abs(Int(decoded.rgb[i * 3 + c]) - Int(bgra[i * 4 + byte]))
                sum += d
                worst = max(worst, d)
            }
        }
        report.meanAbs = Double(sum) / Double(3 * width * height)
        report.maxAbs = worst
        switch format {
        case .png where worst != 0:
            report.failures.append("PNG pixels differ from those written (max \(worst) levels)")
        case .jpeg where report.meanAbs > maxJPEGMeanAbs:
            report.failures.append(String(format: "JPEG mean error %.2f levels > %.1f", report.meanAbs, maxJPEGMeanAbs))
        default: break
        }
        return report
    }

    /// Decoded samples straight from the image's provider: no colour management.
    public static func readRGB(_ url: URL) -> (width: Int, height: Int, rgb: [UInt8], colourSpace: String?)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.bitsPerComponent == 8, let raw = image.dataProvider?.data as Data? else { return nil }
        let w = image.width, h = image.height, bpp = image.bitsPerPixel / 8, row = image.bytesPerRow
        guard bpp == 3 || bpp == 4 else { return nil }
        // channel offsets of R, G, B within a pixel
        let alpha = image.alphaInfo
        let little = image.bitmapInfo.contains(.byteOrder32Little)
        let alphaFirst = alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst
        let offsets: [Int]
        if bpp == 3 { offsets = [0, 1, 2] }
        else if little { offsets = alphaFirst ? [2, 1, 0] : [3, 2, 1] }
        else { offsets = alphaFirst ? [1, 2, 3] : [0, 1, 2] }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        raw.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for y in 0..<h {
                for x in 0..<w {
                    for c in 0..<3 { rgb[(y * w + x) * 3 + c] = p[y * row + x * bpp + offsets[c]] }
                }
            }
        }
        return (w, h, rgb, image.colorSpace?.name as String?)
    }
}
