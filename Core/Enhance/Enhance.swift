import CoreMedia
import CoreVideo
import Foundation
import Metal

/// The picture enhancements of one render or preview (CLAUDE.md 画质增强).
/// Empty settings leave the existing paths byte for byte unchanged.
public struct EnhanceSettings: Sendable, Equatable {
    /// Noise filter strength 0–1; nil is off. macOS 26 and later.
    public var denoise: Float?
    public var background: BackgroundEffect?
    /// Per shot, whether the background effect applies (nil: every shot) —
    /// `PersonSegmentation.shotsWithPeople`.
    public var backgroundShots: [Bool]?

    public static let defaultDenoise: Float = 0.5

    public init(denoise: Float? = nil, background: BackgroundEffect? = nil, backgroundShots: [Bool]? = nil) {
        self.denoise = denoise
        self.background = background
        self.backgroundShots = backgroundShots
    }

    public var isEmpty: Bool { denoise == nil && background == nil }

    /// Whether this macOS has the noise filter.
    public static var denoiseAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

/// One frame ready to grade: the decoder's frame (the "原片" view), the frame
/// to grade (denoised or the same), and the background pass if any.
public struct EnhancedFrame {
    public let source: DecodedFrame
    public let frame: DecodedFrame
    let background: (MaskImage, BackgroundScratch)?

    public init(_ plain: DecodedFrame) {
        source = plain
        frame = plain
        background = nil
    }

    init(source: DecodedFrame, frame: DecodedFrame, background: (MaskImage, BackgroundScratch)?) {
        self.source = source
        self.frame = frame
        self.background = background
    }
}

/// Prepares frames for the enhancements: what each frame contributes to its
/// neighbours (its mask, its noise-filter input), and the inputs of a frame
/// from its window in the same shot. Export and preview call the same
/// `inputs` with the same window, so their pixels match (CLAUDE.md 原则 5).
public final class Enhancer {
    public let settings: EnhanceSettings
    public let width: Int
    public let height: Int
    /// Preview chains start this many frames before the frame (CLAUDE.md 降噪:
    /// an approximation; the export's chain starts at the shot's first frame).
    public static let previewWarmUp = 8
    /// Frames needed before / after a frame (within its shot), besides a denoise chain.
    public let before: Int
    public let after: Int
    private let kernels: GradeKernels
    private let denoiser: AnyObject?
    private let scratch: BackgroundScratch?
    private let denoiseReach: (previous: Int, next: Int)

    /// What one decoded frame contributes to its window.
    struct Prepared {
        let frame: DecodedFrame
        let mask: PersonMask?
        let denoiseSource: CVPixelBuffer?
    }

    public init(settings: EnhanceSettings, width: Int, height: Int, kernels: GradeKernels) throws {
        self.settings = settings
        self.width = width
        self.height = height
        self.kernels = kernels
        if settings.denoise != nil {
            guard #available(macOS 26.0, *) else { throw VideoError.unsupported("noise reduction needs macOS 26") }
            let d = try Denoiser(width: width, height: height, device: kernels.metal.device)
            denoiser = d
            denoiseReach = (d.previousCount, d.nextCount)
        } else {
            denoiser = nil
            denoiseReach = (0, 0)
        }
        scratch = try settings.background.map {
            try BackgroundScratch(effect: $0, width: width, height: height, device: kernels.metal.device)
        }
        let maskReach = settings.background == nil ? 0 : PersonSegmentation.radius
        before = max(denoiseReach.previous, maskReach)
        after = max(denoiseReach.next, maskReach)
    }

    func prepare(_ frame: DecodedFrame) throws -> Prepared {
        let mask = settings.background == nil ? nil : try PersonSegmentation.mask(frame.pixelBuffer)
        var source: CVPixelBuffer?
        if #available(macOS 26.0, *), let d = denoiser as? Denoiser { source = try d.source(frame) }
        return Prepared(frame: frame, mask: mask, denoiseSource: source)
    }

    /// Frame `i`'s inputs. `window` holds at least frames max(shot.first, i − before)
    /// ... min(shot.last, i + after), and from `chain` on when that is given.
    /// `chain` nil: the export, which calls this for every frame in order and
    /// starts a denoise chain at each shot's first frame. Otherwise a new chain
    /// from frame `chain` (in the shot, ≤ i) is run up to `i`.
    func inputs(_ i: Int, window: [Int: Prepared], analysis: Analysis, chain: Int? = nil) throws -> EnhancedFrame {
        let k = analysis.shotIndex(forFrame: i), shot = analysis.shots[k]
        guard let centre = window[i] else { throw VideoError.reader("enhancement window lacks frame \(i)") }
        func range(_ back: Int, _ ahead: Int) throws -> [Prepared] {
            try (max(shot.first, i - back)...min(shot.last, i + ahead)).map {
                guard let p = window[$0] else { throw VideoError.reader("enhancement window lacks frame \($0)") }
                return p
            }
        }
        var graded = centre.frame
        if #available(macOS 26.0, *), let d = denoiser as? Denoiser, let strength = settings.denoise {
            let start = chain ?? shot.first
            precondition(start >= shot.first && start <= i)
            // one frame of a chain from `start`: neighbours in the shot, none before the chain
            func step(_ j: Int) throws -> DecodedFrame {
                guard let p = window[j], let source = p.denoiseSource else { throw VideoError.reader("enhancement window lacks frame \(j)") }
                func pairs(_ r: ClosedRange<Int>) throws -> [(CVPixelBuffer, CMTime)] {
                    try r.map {
                        guard let q = window[$0], let b = q.denoiseSource else { throw VideoError.reader("enhancement window lacks frame \($0)") }
                        return (b, q.frame.presentationTime)
                    }
                }
                let back = max(start, j - denoiseReach.previous), ahead = min(shot.last, j + denoiseReach.next)
                return try d.process(p.frame, source: source,
                                     previous: back < j ? try pairs(back...(j - 1)) : [],
                                     next: j < ahead ? try pairs((j + 1)...ahead) : [],
                                     startsChain: j == start, strength: strength)
            }
            if chain != nil || i == shot.first { try d.restart() }
            if chain != nil { for j in start..<i { _ = try step(j) } }
            graded = try step(i)
        }
        var background: (MaskImage, BackgroundScratch)?
        if let scratch, settings.backgroundShots?[k] ?? true {
            let masks = try range(PersonSegmentation.radius, PersonSegmentation.radius).compactMap(\.mask)
            background = (try PersonSegmentation.combine(masks, frameWidth: width, frameHeight: height, kernels: kernels), scratch)
        }
        return EnhancedFrame(source: centre.frame, frame: graded, background: background)
    }
}

/// Decoded frames in order from `start`, each with its enhancement inputs:
/// reads ahead `enhancer.after` frames within the shot and keeps `before`
/// behind. From frame 0 (the render) every shot's denoise chain starts at its
/// first frame; from a later frame (playback) the first chain starts
/// `Enhancer.previewWarmUp` frames back, like a preview, and then continues.
public final class EnhancedFrameStream {
    private let reader: VideoReader
    private let analysis: Analysis
    private let enhancer: Enhancer?
    private var window: [Int: Enhancer.Prepared] = [:]
    private var decoded = -1
    private var ended = false
    private var current: Int
    private var firstChain: Int?

    init(reader: VideoReader, analysis: Analysis, enhancer: Enhancer?, start: Int = 0, firstChain: Int? = nil) {
        self.reader = reader
        self.analysis = analysis
        self.enhancer = enhancer
        current = start
        self.firstChain = firstChain
    }

    public func next() throws -> EnhancedFrame? {
        guard let enhancer else {
            while let f = try reader.next() { if f.index >= current { return EnhancedFrame(f) } }
            return nil
        }
        guard current < analysis.frameCount else { return nil }
        let shot = analysis.shots[analysis.shotIndex(forFrame: current)]
        let needed = min(shot.last, current + enhancer.after)
        while decoded < needed && !ended {
            guard let frame = try reader.next() else { ended = true; break }
            window[frame.index] = try enhancer.prepare(frame)
            decoded = frame.index
        }
        guard window[current] != nil else { return nil }   // fewer frames than analysed: render reports it
        let out = try enhancer.inputs(current, window: window, analysis: analysis, chain: firstChain)
        firstChain = nil
        for k in window.keys where k <= current - enhancer.before { window[k] = nil }
        current += 1
        return out
    }
}

extension AutoGrader {
    /// Random access with enhancements: decode frame `index` and its window in
    /// its shot, and prepare it as `render` does. With noise reduction the
    /// preview's chain starts `Enhancer.previewWarmUp` frames back (close to the
    /// export, not equal); `exact` starts it at the shot's first frame, which is
    /// the export's bytes (ExportCheck; CLAUDE.md 降噪).
    public func decodeFrame(_ url: URL, analysis: Analysis, index: Int, enhancer: Enhancer?,
                            exact: Bool = false) throws -> EnhancedFrame {
        guard let enhancer else { return EnhancedFrame(try decodeFrame(url, analysis: analysis, index: index)) }
        let shot = analysis.shots[analysis.shotIndex(forFrame: index)]
        let chain = enhancer.settings.denoise == nil ? nil
            : exact ? shot.first : max(shot.first, index - Enhancer.previewWarmUp)
        let first = min(chain ?? index, max(shot.first, index - enhancer.before)), last = min(shot.last, index + enhancer.after)
        let reader = try VideoReader(url: url, device: metal.device, timeRange: analysis.timeRange(first: first, last: last),
                                     frameTimes: analysis.frameTimes)
        var window: [Int: Enhancer.Prepared] = [:]
        while let frame = try reader.next() {
            if frame.index > last { break }
            window[frame.index] = try enhancer.prepare(frame)
        }
        return try enhancer.inputs(index, window: window, analysis: analysis, chain: chain)
    }

    /// Frames from `index` on, prepared as `render` does except that the first
    /// denoise chain starts at the preview's warm-up (playback; CLAUDE.md 降噪).
    public func frameStream(_ url: URL, analysis: Analysis, from index: Int, enhancer: Enhancer?) throws -> EnhancedFrameStream {
        let shot = analysis.shots[analysis.shotIndex(forFrame: index)]
        let chain = enhancer?.settings.denoise == nil ? nil : max(shot.first, index - Enhancer.previewWarmUp)
        let first = min(chain ?? index, max(shot.first, index - (enhancer?.before ?? 0)))
        let reader = try VideoReader(url: url, device: metal.device, timeRange: analysis.timeRange(first: first, last: analysis.frameCount - 1),
                                     frameTimes: analysis.frameTimes)
        return EnhancedFrameStream(reader: reader, analysis: analysis, enhancer: enhancer, start: index, firstChain: chain)
    }
}

extension AutoGrader {
    /// Every frame's person-mask coverage (0–1), for `PersonSegmentation.shotsWithPeople`.
    /// One pass over the video, about 11 ms a frame at 1080p (2026-11-04).
    public func personCoverage(_ url: URL, analysis: Analysis, cancel: CancelToken? = nil,
                               progress: ((Int) -> Void)? = nil) throws -> [Float] {
        let reader = try VideoReader(url: url, device: metal.device)
        var out: [Float] = []
        out.reserveCapacity(analysis.frameCount)
        while let frame = try reader.next() {
            if cancel?.isCancelled == true { throw Cancelled() }
            out.append(PersonSegmentation.coverage(try PersonSegmentation.mask(frame.pixelBuffer)))
            progress?(frame.index)
        }
        guard out.count == analysis.frameCount else {
            throw VideoError.reader("person pass decoded \(out.count) frames, analysis saw \(analysis.frameCount)")
        }
        return out
    }
}
