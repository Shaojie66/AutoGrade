import Foundation
import Metal

/// float[3][h][w] in a shared MTLBuffer — the layout every kernel and fixture uses.
public struct PlanarImage {
    public let buffer: MTLBuffer
    public let width: Int
    public let height: Int
    public var pixels: Int { width * height }

    /// Copy of the contents (CPU side). Only valid after the producing command completed.
    public func floats() -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: Float.self, capacity: 3 * pixels),
                                  count: 3 * pixels))
    }
}

/// A uniform 3D LUT, float[3][n][n][n], lut[c][b][g][r] with r fastest.
public struct LUT3D {
    public let buffer: MTLBuffer
    public let size: Int
    public var count: Int { 3 * size * size * size }

    public func floats() -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: Float.self, capacity: count), count: count))
    }
}

/// The network's per-image output: a 33^3 LUT on non-uniform per-channel vertices.
public struct AiLUT {
    public let lut: MTLBuffer        // float[3][d][d][d]
    public let vertices: MTLBuffer   // float[3][d]
    public let size: Int
}

/// Typed wrappers over Grade.metal.
///
/// Each operation comes in two forms: `encodeX(into:)` adds the dispatch to an
/// encoder the caller owns (so a preview frame is one command buffer), and the
/// plain form runs it alone and waits. Both forms are the same dispatch; the
/// plain form exists so tests and the analysis pass can read results back.
public final class GradeKernels: @unchecked Sendable {
    public let metal: MetalContext

    public init(metal: MetalContext) {
        self.metal = metal
    }

    // MARK: allocation

    public func makeImage(width: Int, height: Int) throws -> PlanarImage {
        PlanarImage(buffer: try makeBuffer(floats: 3 * width * height), width: width, height: height)
    }

    public func makeImage(width: Int, height: Int, floats: [Float]) throws -> PlanarImage {
        precondition(floats.count == 3 * width * height)
        let buffer = try XUnwrap(metal.device.makeBuffer(bytes: floats, length: floats.count * 4,
                                                         options: .storageModeShared), "image buffer")
        return PlanarImage(buffer: buffer, width: width, height: height)
    }

    public func makeLUT(size: Int, floats: [Float]? = nil) throws -> LUT3D {
        let count = 3 * size * size * size
        if let floats {
            precondition(floats.count == count)
            let buffer = try XUnwrap(metal.device.makeBuffer(bytes: floats, length: count * 4,
                                                             options: .storageModeShared), "lut buffer")
            return LUT3D(buffer: buffer, size: size)
        }
        return LUT3D(buffer: try makeBuffer(floats: count), size: size)
    }

    public func makeAiLUT(lut: [Float], vertices: [Float], size: Int) throws -> AiLUT {
        precondition(lut.count == 3 * size * size * size && vertices.count == 3 * size)
        let device = metal.device
        return AiLUT(lut: try XUnwrap(device.makeBuffer(bytes: lut, length: lut.count * 4, options: .storageModeShared), "ailut"),
                     vertices: try XUnwrap(device.makeBuffer(bytes: vertices, length: vertices.count * 4,
                                                             options: .storageModeShared), "vertices"),
                     size: size)
    }

    /// A BGRA8 texture the GPU writes and the display samples (preview frames).
    public func makeDisplayTexture(width: Int, height: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared   // tests read the bytes back (PreviewExportTests)
        return try XUnwrap(metal.device.makeTexture(descriptor: d), "display texture")
    }

    // MARK: decode

    /// `fullRange`: the planes' range, from the decoder's pixel format (`DecodedFrame.fullRange`;
    /// CLAUDE.md 架构原则 4). Required on purpose: a guess would shift every colour.
    public func encodeYUVToRGB(into enc: MTLComputeCommandEncoder, luma: MTLTexture, chroma: MTLTexture,
                               fullRange: Bool, output: PlanarImage) throws {
        precondition(output.width == luma.width && output.height == luma.height)
        var range: UInt32 = fullRange ? 1 : 0
        enc.setComputePipelineState(try metal.pipeline("yuv420_to_rgb"))
        enc.setTexture(luma, index: 0)
        enc.setTexture(chroma, index: 1)
        enc.setBuffer(output.buffer, offset: 0, index: 0)
        enc.setBytes(&range, length: 4, index: 1)
        enc.dispatchThreads(MTLSize(width: luma.width, height: luma.height, depth: 1), threadsPerThreadgroup: tile2D)
    }

    /// Decoder planes (r8Unorm luma, rg8Unorm CbCr) -> planar RGB, BT.709 limited or full range.
    public func yuvToRGB(luma: MTLTexture, chroma: MTLTexture, fullRange: Bool) throws -> PlanarImage {
        let out = try makeImage(width: luma.width, height: luma.height)
        try metal.run { try encodeYUVToRGB(into: $0, luma: luma, chroma: chroma, fullRange: fullRange, output: out) }
        return out
    }

    // MARK: network input

    public func encodeResize(into enc: MTLComputeCommandEncoder, _ src: PlanarImage, output: PlanarImage) throws {
        var params = SIMD4<UInt32>(UInt32(src.width), UInt32(src.height), UInt32(output.width), UInt32(output.height))
        enc.setComputePipelineState(try metal.pipeline("resize_bilinear"))
        enc.setBuffer(src.buffer, offset: 0, index: 0)
        enc.setBuffer(output.buffer, offset: 0, index: 1)
        enc.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 2)
        enc.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 3),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }

    public func resize(_ src: PlanarImage, width: Int, height: Int) throws -> PlanarImage {
        let out = try makeImage(width: width, height: height)
        try metal.run { try encodeResize(into: $0, src, output: out) }
        return out
    }

    // MARK: reframe

    /// Crop `length` (x, y) at `origin` (x, y) of `src` and resize it to `output`'s
    /// size (CLAUDE.md 重构图的裁切缩放). Origin and length may be fractional.
    public func encodeCropResize(into enc: MTLComputeCommandEncoder, _ src: PlanarImage, origin: SIMD2<Float>,
                                 length: SIMD2<Float>, output: PlanarImage) throws {
        let scale = length / SIMD2(Float(output.width), Float(output.height))
        guard scale.max() <= 31, origin.min() >= 0, origin.x + length.x <= Float(src.width) + 1e-3,
              origin.y + length.y <= Float(src.height) + 1e-3 else {
            throw MetalError.badArgument("crop \(origin)+\(length) of \(src.width)x\(src.height) -> \(output.width)x\(output.height)")
        }
        struct Params { var sw, sh, dw, dh: UInt32; var ox, oy, lx, ly: Float }
        var params = Params(sw: UInt32(src.width), sh: UInt32(src.height), dw: UInt32(output.width), dh: UInt32(output.height),
                            ox: origin.x, oy: origin.y, lx: length.x, ly: length.y)
        enc.setComputePipelineState(try metal.pipeline("crop_resize_aa"))
        enc.setBuffer(src.buffer, offset: 0, index: 0)
        enc.setBuffer(output.buffer, offset: 0, index: 1)
        enc.setBytes(&params, length: MemoryLayout<Params>.size, index: 2)
        enc.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 3),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }

    public func cropResize(_ src: PlanarImage, origin: SIMD2<Float>, length: SIMD2<Float>,
                           width: Int, height: Int) throws -> PlanarImage {
        let out = try makeImage(width: width, height: height)
        try metal.run { try encodeCropResize(into: $0, src, origin: origin, length: length, output: out) }
        return out
    }

    // MARK: overlay

    /// A premultiplied sRGB RGBA8 patch, row-major (a rasterised subtitle).
    public func makeOverlay(rgba: [UInt8], width: Int, height: Int) throws -> OverlayImage {
        precondition(rgba.count == width * height * 4)
        let buffer = try XUnwrap(rgba.withUnsafeBytes {
            metal.device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 4), options: .storageModeShared)
        }, "overlay of \(width)x\(height)")
        return OverlayImage(buffer: buffer, width: width, height: height)
    }

    /// `overlay` composited onto `img` in place with its top-left at `origin` (CLAUDE.md 字幕叠加).
    public func encodeOverlay(into enc: MTLComputeCommandEncoder, _ img: PlanarImage, _ overlay: OverlayImage,
                              origin: SIMD2<Int32>) throws {
        guard overlay.width > 0, overlay.height > 0 else { return }
        struct Params { var iw, ih, ow, oh: UInt32; var ox, oy: Int32 }
        var params = Params(iw: UInt32(img.width), ih: UInt32(img.height), ow: UInt32(overlay.width), oh: UInt32(overlay.height),
                            ox: origin.x, oy: origin.y)
        enc.setComputePipelineState(try metal.pipeline("overlay_premultiplied"))
        enc.setBuffer(img.buffer, offset: 0, index: 0)
        enc.setBuffer(overlay.buffer, offset: 0, index: 1)
        enc.setBytes(&params, length: MemoryLayout<Params>.size, index: 2)
        enc.dispatchThreads(MTLSize(width: overlay.width, height: overlay.height, depth: 1), threadsPerThreadgroup: tile2D)
    }

    public func overlay(_ img: PlanarImage, _ overlay: OverlayImage, origin: SIMD2<Int32>) throws {
        try metal.run { try encodeOverlay(into: $0, img, overlay, origin: origin) }
    }

    // MARK: AiLUT

    public func applyAiLUT(_ img: PlanarImage, _ ai: AiLUT) throws -> PlanarImage {
        let out = try makeImage(width: img.width, height: img.height)
        var params = SIMD2<UInt32>(UInt32(img.pixels), UInt32(ai.size))
        let pipeline = try metal.pipeline("ailut_apply")
        try metal.run { enc in
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(img.buffer, offset: 0, index: 0)
            enc.setBuffer(ai.lut, offset: 0, index: 1)
            enc.setBuffer(ai.vertices, offset: 0, index: 2)
            enc.setBuffer(out.buffer, offset: 0, index: 3)
            enc.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 4)
            enc.dispatchThreads(MTLSize(width: img.pixels, height: 1, depth: 1), threadsPerThreadgroup: tile1D)
        }
        return out
    }

    /// The AiLUT sampled on a uniform size^3 lattice (unclamped).
    public func bake(_ ai: AiLUT, size: Int) throws -> LUT3D {
        let out = try makeLUT(size: size)
        var params = SIMD2<UInt32>(UInt32(size), UInt32(ai.size))
        let pipeline = try metal.pipeline("ailut_bake")
        try metal.run { enc in
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(ai.lut, offset: 0, index: 0)
            enc.setBuffer(ai.vertices, offset: 0, index: 1)
            enc.setBuffer(out.buffer, offset: 0, index: 2)
            enc.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 3)
            enc.dispatchThreads(MTLSize(width: size, height: size, depth: size),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
        }
        return out
    }

    // MARK: shot LUTs

    /// acc += lut, element-wise.
    public func accumulate(_ acc: LUT3D, _ lut: LUT3D) throws {
        precondition(acc.size == lut.size)
        var count = UInt32(acc.count)
        let pipeline = try metal.pipeline("lut_accumulate")
        try metal.run { enc in
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(acc.buffer, offset: 0, index: 0)
            enc.setBuffer(lut.buffer, offset: 0, index: 1)
            enc.setBytes(&count, length: 4, index: 2)
            enc.dispatchThreads(MTLSize(width: acc.count, height: 1, depth: 1), threadsPerThreadgroup: tile1D)
        }
    }

    /// clamp(sum / frames, 0, 1) as a new LUT; `sum` is left untouched (CLAUDE.md, 切点编辑).
    public func mean(_ sum: LUT3D, frames: Int) throws -> LUT3D {
        precondition(frames > 0)
        let out = try makeLUT(size: sum.size)
        var params = SIMD2<UInt32>(UInt32(sum.count), UInt32(frames))
        let pipeline = try metal.pipeline("lut_mean")
        try metal.run { enc in
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(sum.buffer, offset: 0, index: 0)
            enc.setBuffer(out.buffer, offset: 0, index: 1)
            enc.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 2)
            enc.dispatchThreads(MTLSize(width: sum.count, height: 1, depth: 1), threadsPerThreadgroup: tile1D)
        }
        return out
    }

    /// s * lut + (1 - s) * identity, s in [0, 1] (CLAUDE.md, 强度).
    public func blend(_ lut: LUT3D, strength: Float) throws -> LUT3D {
        let out = try makeLUT(size: lut.size)
        var s = min(max(strength, 0), 1)
        var n = UInt32(lut.size)
        let pipeline = try metal.pipeline("lut_blend")
        try metal.run { enc in
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(lut.buffer, offset: 0, index: 0)
            enc.setBuffer(out.buffer, offset: 0, index: 1)
            enc.setBytes(&s, length: 4, index: 2)
            enc.setBytes(&n, length: 4, index: 3)
            enc.dispatchThreads(MTLSize(width: lut.size, height: lut.size, depth: lut.size),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
        }
        return out
    }

    // MARK: grading and output

    public func encodeApplyLUT(into enc: MTLComputeCommandEncoder, _ img: PlanarImage, _ lut: LUT3D,
                               output: PlanarImage) throws {
        var params = SIMD2<UInt32>(UInt32(img.pixels), UInt32(lut.size))
        enc.setComputePipelineState(try metal.pipeline("lut_apply"))
        enc.setBuffer(img.buffer, offset: 0, index: 0)
        enc.setBuffer(lut.buffer, offset: 0, index: 1)
        enc.setBuffer(output.buffer, offset: 0, index: 2)
        enc.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 3)
        enc.dispatchThreads(MTLSize(width: img.pixels, height: 1, depth: 1), threadsPerThreadgroup: tile1D)
    }

    public func applyLUT(_ img: PlanarImage, _ lut: LUT3D) throws -> PlanarImage {
        let out = try makeImage(width: img.width, height: img.height)
        try metal.run { try encodeApplyLUT(into: $0, img, lut, output: out) }
        return out
    }

    /// Quantized write into a bgra8Unorm texture (an encoder pixel buffer or a display texture).
    public func encodeWriteBGRA8(into enc: MTLComputeCommandEncoder, _ img: PlanarImage, to texture: MTLTexture) throws {
        precondition(texture.width == img.width && texture.height == img.height)
        enc.setComputePipelineState(try metal.pipeline("planar_to_bgra8"))
        enc.setBuffer(img.buffer, offset: 0, index: 0)
        enc.setTexture(texture, index: 0)
        enc.dispatchThreads(MTLSize(width: img.width, height: img.height, depth: 1), threadsPerThreadgroup: tile2D)
    }

    public func writeBGRA8(_ img: PlanarImage, to texture: MTLTexture) throws {
        try metal.run { try encodeWriteBGRA8(into: $0, img, to: texture) }
    }

    /// The one grading path shared by preview and export (CLAUDE.md 架构原则 5):
    /// decoder planes -> RGB -> final LUT -> (background) -> (subtitle) -> BGRA8 in `graded`; optionally the
    /// ungraded RGB -> BGRA8 in `original`. `scratch` must match the frame size.
    public func encodeGradeFrame(into enc: MTLComputeCommandEncoder, luma: MTLTexture, chroma: MTLTexture,
                                 fullRange: Bool, lut: LUT3D, scratch: (rgb: PlanarImage, graded: PlanarImage),
                                 graded: MTLTexture, original: MTLTexture?,
                                 background: (MaskImage, BackgroundScratch)? = nil,
                                 overlay: (OverlayImage, SIMD2<Int32>)? = nil) throws {
        try encodeYUVToRGB(into: enc, luma: luma, chroma: chroma, fullRange: fullRange, output: scratch.rgb)
        if let original { try encodeWriteBGRA8(into: enc, scratch.rgb, to: original) }
        try encodeApplyLUT(into: enc, scratch.rgb, lut, output: scratch.graded)
        if let (mask, bg) = background { try encodeBackground(into: enc, scratch.graded, mask: mask, scratch: bg) }
        if let overlay { try encodeOverlay(into: enc, scratch.graded, overlay.0, origin: overlay.1) }
        try encodeWriteBGRA8(into: enc, scratch.graded, to: graded)
    }

    /// The reframed variant: grade the whole frame, then crop-and-resize it to
    /// `cropped`'s size (CLAUDE.md 重构图的裁切缩放: grade first, then resample).
    public func encodeGradeFrame(into enc: MTLComputeCommandEncoder, luma: MTLTexture, chroma: MTLTexture,
                                 fullRange: Bool, lut: LUT3D, scratch: (rgb: PlanarImage, graded: PlanarImage),
                                 crop origin: SIMD2<Float>, length: SIMD2<Float>, cropped: PlanarImage,
                                 output: MTLTexture, background: (MaskImage, BackgroundScratch)? = nil,
                                 overlay: (OverlayImage, SIMD2<Int32>)? = nil) throws {
        try encodeYUVToRGB(into: enc, luma: luma, chroma: chroma, fullRange: fullRange, output: scratch.rgb)
        try encodeApplyLUT(into: enc, scratch.rgb, lut, output: scratch.graded)
        if let (mask, bg) = background { try encodeBackground(into: enc, scratch.graded, mask: mask, scratch: bg) }
        try encodeCropResize(into: enc, scratch.graded, origin: origin, length: length, output: cropped)
        if let overlay { try encodeOverlay(into: enc, cropped, overlay.0, origin: overlay.1) }
        try encodeWriteBGRA8(into: enc, cropped, to: output)
    }

    // MARK: helpers

    private let tile1D = MTLSize(width: 256, height: 1, depth: 1)
    private let tile2D = MTLSize(width: 16, height: 16, depth: 1)

    private func makeBuffer(floats count: Int) throws -> MTLBuffer {
        try XUnwrap(metal.device.makeBuffer(length: count * 4, options: .storageModeShared), "buffer of \(count) floats")
    }
}

/// A rasterised subtitle on the GPU: premultiplied sRGB RGBA8.
public final class OverlayImage: @unchecked Sendable {
    public let buffer: MTLBuffer
    public let width: Int
    public let height: Int

    init(buffer: MTLBuffer, width: Int, height: Int) {
        self.buffer = buffer
        self.width = width
        self.height = height
    }
}

/// 8-bit quantization used everywhere a float image becomes codes:
/// clamp to [0,1], * 255, round half to even (CLAUDE.md 架构原则 4).
@inline(__always) public func quantize8(_ x: Float) -> UInt8 {
    UInt8((min(max(x, 0), 1) * 255).rounded(.toNearestOrEven))
}

func XUnwrap<T>(_ value: T?, _ what: String) throws -> T {
    guard let value else { throw MetalError.commandFailed("could not allocate \(what)") }
    return value
}
