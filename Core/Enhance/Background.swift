import CoreVideo
import Foundation
import Metal
import Vision

/// What replaces the background behind people (CLAUDE.md 画质增强 / 背景).
public enum BackgroundEffect: Sendable, Hashable {
    /// Gaussian blur, σ = frame height × `blurFraction` × strength (0–1).
    case blur(strength: Float)
    /// A flat colour, display-encoded RGB in [0, 1] (the planar image's space).
    case colour(SIMD3<Float>)

    public static let blurFraction: Float = 0.03
    public static let defaultBlurStrength: Float = 0.6
    public static let white = BackgroundEffect.colour(SIMD3(1, 1, 1))
    public static let black = BackgroundEffect.colour(SIMD3(0, 0, 0))
    public static let green = BackgroundEffect.colour(SIMD3(0, 0xB1, 0x40) / 255)

    /// "blur", "white", "black", "green" or "#RRGGBB".
    public init?(name: String, strength: Float = BackgroundEffect.defaultBlurStrength) {
        switch name.lowercased() {
        case "blur": self = .blur(strength: min(max(strength, 0), 1))
        case "white": self = .white
        case "black": self = .black
        case "green": self = .green
        default:
            let hex = name.hasPrefix("#") ? String(name.dropFirst()) : name
            guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
            self = .colour(SIMD3(Float((v >> 16) & 0xFF), Float((v >> 8) & 0xFF), Float(v & 0xFF)) / 255)
        }
    }

    /// The blur σ in pixels for a frame `height` pixels tall (0 for a colour).
    public func sigma(height: Int) -> Float {
        if case .blur(let s) = self { return Float(height) * Self.blurFraction * s }
        return 0
    }
}

/// A segmenter-sized person mask, one byte per pixel (255 = person).
public struct PersonMask: Sendable {
    public let bytes: [UInt8]
    public let width: Int
    public let height: Int

    public init(bytes: [UInt8], width: Int, height: Int) {
        precondition(bytes.count == width * height)
        self.bytes = bytes
        self.width = width
        self.height = height
    }
}

/// The float mask the compositing kernels sample: averaged, feathered, at the
/// segmenter's size.
public struct MaskImage {
    public let buffer: MTLBuffer
    public let width: Int
    public let height: Int
}

public enum PersonSegmentation {
    /// Feather σ as a fraction of the frame height (CLAUDE.md 背景).
    public static let featherFraction: Float = 0.005
    /// Masks averaged on each side of a frame, within its shot.
    public static let radius = 2
    /// A shot gets the background effect only if in at least half its frames
    /// the mask covers this share of the picture; otherwise nobody was found and
    /// the effect would swallow the whole frame (CLAUDE.md 背景, 2026-11-04: the
    /// gym's wide shot, a player 5% of the height, mask 0.0004; one stray frame
    /// of 0.0083 in the car-window clip must not turn all 563 frames green).
    public static let minCoverage: Float = 0.005

    /// The share of the picture the mask covers, 0–1.
    public static func coverage(_ mask: PersonMask) -> Float {
        Float(mask.bytes.reduce(0) { $0 + Int($1) }) / Float(255 * max(mask.bytes.count, 1))
    }

    /// Per shot: whether someone was found in at least half its frames (`minCoverage`).
    public static func shotsWithPeople(coverage: [Float], shots: [Shot]) -> [Bool] {
        shots.map { s in 2 * (s.first...s.last).filter { coverage[$0] >= minCoverage }.count >= s.frames }
    }

    /// Vision's `.balanced` 8-bit person mask of a decoded frame.
    public static func mask(_ pixelBuffer: CVPixelBuffer) throws -> PersonMask {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up).perform([request])
        guard let out = request.results?.first?.pixelBuffer else { throw VideoError.reader("person segmentation gave no mask") }
        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        let w = CVPixelBufferGetWidth(out), h = CVPixelBufferGetHeight(out), row = CVPixelBufferGetBytesPerRow(out)
        guard let base = CVPixelBufferGetBaseAddress(out) else { throw VideoError.reader("person mask has no pixels") }
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { dst in
            for y in 0..<h { dst.baseAddress!.advanced(by: y * w).copyMemory(from: base.advanced(by: y * row), byteCount: w) }
        }
        return PersonMask(bytes: bytes, width: w, height: h)
    }

    /// Mean of `masks` (all one size) in [0, 1], then a separable Gaussian
    /// feather of `featherFraction` × frame height, converted to mask pixels per
    /// axis, edge clamped (CLAUDE.md 背景). On the GPU: the same `blur_separable`.
    public static func combine(_ masks: [PersonMask], frameWidth: Int, frameHeight: Int,
                               kernels: GradeKernels) throws -> MaskImage {
        precondition(!masks.isEmpty)
        let w = masks[0].width, h = masks[0].height
        precondition(masks.allSatisfy { $0.width == w && $0.height == h })
        let device = kernels.metal.device
        let bytes = masks.flatMap(\.bytes)
        let input = try XUnwrap(device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared), "masks")
        let out = try kernels.makeMask(floats: [Float](repeating: 0, count: w * h), width: w, height: h)
        let tmp = try XUnwrap(device.makeBuffer(length: w * h * 4, options: .storageModeShared), "mask scratch")
        let feather = featherFraction * Float(frameHeight)
        let tx = gaussianWeights(sigma: feather * Float(w) / Float(frameWidth))
        let ty = gaussianWeights(sigma: feather * Float(h) / Float(frameHeight))
        try kernels.metal.run { enc in
            struct Mean { var w, h, count: UInt32 }
            var mp = Mean(w: UInt32(w), h: UInt32(h), count: UInt32(masks.count))
            enc.setComputePipelineState(try kernels.metal.pipeline("mask_mean"))
            enc.setBuffer(input, offset: 0, index: 0)
            enc.setBuffer(out.buffer, offset: 0, index: 1)
            enc.setBytes(&mp, length: MemoryLayout<Mean>.size, index: 2)
            enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            try kernels.encodeBlur(into: enc, out.buffer, tmp, width: w, height: h, planes: 1, taps: tx, vertical: false)
            try kernels.encodeBlur(into: enc, tmp, out.buffer, width: w, height: h, planes: 1, taps: ty, vertical: true)
        }
        return out
    }

    /// Normalised Gaussian taps for -r ... r, r = ⌈3σ⌉; [1] below σ 0.3.
    public static func gaussianWeights(sigma: Float) -> [Float] {
        guard sigma >= 0.3 else { return [1] }
        let r = Int((3 * Double(sigma)).rounded(.up))
        let k = (-r...r).map { j in exp(-Double(j * j) / (2 * Double(sigma) * Double(sigma))) }
        let total = k.reduce(0, +)
        return k.map { Float($0 / total) }
    }
}

/// Frame-size scratch for one background effect: the blur's two four-plane
/// buffers and its taps.
public final class BackgroundScratch {
    public let effect: BackgroundEffect
    public let width: Int
    public let height: Int
    let planes: (MTLBuffer, MTLBuffer)?
    let weights: MTLBuffer?
    let radius: Int

    /// `sigma` overrides the effect's blur σ in pixels (parity tests).
    public init(effect: BackgroundEffect, width: Int, height: Int, device: MTLDevice, sigma: Float? = nil) throws {
        self.effect = effect
        self.width = width
        self.height = height
        if case .blur = effect {
            let length = 4 * width * height * 4
            planes = (try XUnwrap(device.makeBuffer(length: length, options: .storageModeShared), "background planes"),
                      try XUnwrap(device.makeBuffer(length: length, options: .storageModeShared), "background planes"))
            let taps = PersonSegmentation.gaussianWeights(sigma: sigma ?? effect.sigma(height: height))
            weights = try XUnwrap(device.makeBuffer(bytes: taps, length: taps.count * 4, options: .storageModeShared), "blur taps")
            radius = taps.count / 2
        } else {
            planes = nil
            weights = nil
            radius = 0
        }
    }
}

extension GradeKernels {
    public func makeMask(floats: [Float], width: Int, height: Int) throws -> MaskImage {
        precondition(floats.count == width * height)
        let buffer = try XUnwrap(metal.device.makeBuffer(bytes: floats, length: floats.count * 4, options: .storageModeShared),
                                 "mask of \(width)x\(height)")
        return MaskImage(buffer: buffer, width: width, height: height)
    }

    /// One axis of `blur_separable` over `planes` planes, `src` -> `dst`. One tap ([1]) copies.
    func encodeBlur(into enc: MTLComputeCommandEncoder, _ src: MTLBuffer, _ dst: MTLBuffer, width: Int, height: Int,
                    planes: Int, taps: [Float], vertical: Bool) throws {
        struct Blur { var w, h, planes, radius, vertical: UInt32 }
        var bp = Blur(w: UInt32(width), h: UInt32(height), planes: UInt32(planes), radius: UInt32(taps.count / 2),
                      vertical: vertical ? 1 : 0)
        enc.setComputePipelineState(try metal.pipeline("blur_separable"))
        enc.setBuffer(src, offset: 0, index: 0)
        enc.setBuffer(dst, offset: 0, index: 1)
        enc.setBytes(taps, length: taps.count * 4, index: 2)
        enc.setBytes(&bp, length: MemoryLayout<Blur>.size, index: 3)
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: planes), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }

    /// The background behind the person in `mask` replaced in `img`, in place
    /// (CLAUDE.md 背景合成): out = img·m + bg·(1−m).
    public func encodeBackground(into enc: MTLComputeCommandEncoder, _ img: PlanarImage, mask: MaskImage,
                                 scratch: BackgroundScratch) throws {
        precondition(scratch.width == img.width && scratch.height == img.height)
        struct Mask { var w, h, mw, mh: UInt32 }
        var mp = Mask(w: UInt32(img.width), h: UInt32(img.height), mw: UInt32(mask.width), mh: UInt32(mask.height))
        let grid = MTLSize(width: img.width, height: img.height, depth: 1)
        let tile = MTLSize(width: 16, height: 16, depth: 1)
        var colour = SIMD3<Float>(0, 0, 0)
        var blurred: MTLBuffer?
        switch scratch.effect {
        case .colour(let c):
            colour = c
        case .blur:
            guard let (a, b) = scratch.planes, let weights = scratch.weights else { throw MetalError.badArgument("blur scratch") }
            enc.setComputePipelineState(try metal.pipeline("background_weight"))
            enc.setBuffer(img.buffer, offset: 0, index: 0)
            enc.setBuffer(mask.buffer, offset: 0, index: 1)
            enc.setBuffer(a, offset: 0, index: 2)
            enc.setBytes(&mp, length: MemoryLayout<Mask>.size, index: 3)
            enc.dispatchThreads(grid, threadsPerThreadgroup: tile)
            if scratch.radius > 0 {
                struct Blur { var w, h, planes, radius, vertical: UInt32 }
                for (src, dst, vertical) in [(a, b, UInt32(0)), (b, a, UInt32(1))] {
                    var bp = Blur(w: UInt32(img.width), h: UInt32(img.height), planes: 4, radius: UInt32(scratch.radius), vertical: vertical)
                    enc.setComputePipelineState(try metal.pipeline("blur_separable"))
                    enc.setBuffer(src, offset: 0, index: 0)
                    enc.setBuffer(dst, offset: 0, index: 1)
                    enc.setBuffer(weights, offset: 0, index: 2)
                    enc.setBytes(&bp, length: MemoryLayout<Blur>.size, index: 3)
                    enc.dispatchThreads(MTLSize(width: img.width, height: img.height, depth: 4),
                                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                }
            }
            blurred = a
        }
        struct Composite { var w, h, mw, mh: UInt32; var r, g, b: Float; var blurred: UInt32 }
        var cp = Composite(w: mp.w, h: mp.h, mw: mp.mw, mh: mp.mh, r: colour.x, g: colour.y, b: colour.z,
                           blurred: blurred == nil ? 0 : 1)
        enc.setComputePipelineState(try metal.pipeline("mask_composite"))
        enc.setBuffer(img.buffer, offset: 0, index: 0)
        enc.setBuffer(mask.buffer, offset: 0, index: 1)
        enc.setBuffer(blurred ?? mask.buffer, offset: 0, index: 2)
        enc.setBytes(&cp, length: MemoryLayout<Composite>.size, index: 3)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tile)
    }

    public func background(_ img: PlanarImage, mask: MaskImage, scratch: BackgroundScratch) throws {
        try metal.run { try encodeBackground(into: $0, img, mask: mask, scratch: scratch) }
    }
}
