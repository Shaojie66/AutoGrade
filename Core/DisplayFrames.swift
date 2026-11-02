import AVFoundation
import CoreVideo
import Foundation
import Metal

public enum CompareLayout: UInt32, Sendable {
    case split = 0, original = 1, graded = 2
}

/// Turns the preview's two BGRA8 textures into the sample buffers an
/// AVSampleBufferDisplayLayer shows (CLAUDE.md 架构原则 5): '420v' frames with
/// the attachments the H.264/HEVC decoder puts on QuickTime's frames — BT.709
/// primaries, transfer, matrix, chroma location Left and the CGColorSpace
/// derived from them. Measured 2026-11-02: BGRA with only the three tags was
/// shown brighter than QuickTime on the same display; this is the decoder's
/// own format, so the system has nothing left to interpret differently.
public final class DisplayFrameMaker {
    nonisolated(unsafe) public static let colourAttachments: [CFString: CFString] = [   // immutable constants
        kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        kCVImageBufferChromaLocationTopFieldKey: kCVImageBufferChromaLocation_Left,
        kCVImageBufferChromaLocationBottomFieldKey: kCVImageBufferChromaLocation_Left,
    ]
    /// What CoreVideo derives from those tags (the decoder attaches the same: CoreMedia709 / "HDTV").
    nonisolated(unsafe) public static let colourSpace: CGColorSpace? =
        CVImageBufferCreateColorSpaceFromAttachments(colourAttachments as CFDictionary)?.takeRetainedValue()

    private let kernels: GradeKernels
    private let pool: CVPixelBufferPool
    private let cache: CVMetalTextureCache
    public let width: Int
    public let height: Int

    public init(kernels: GradeKernels, width: Int, height: Int) throws {
        self.kernels = kernels
        self.width = width
        self.height = height
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw VideoError.writer("display pixel buffer pool")
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, kernels.metal.device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw VideoError.writer("display texture cache")
        }
        self.pool = pool
        self.cache = cache
    }

    /// The composited, tagged pixel buffer (exposed for tests).
    public func pixelBuffer(original: MTLTexture, graded: MTLTexture, split: Double,
                            layout: CompareLayout) throws -> CVPixelBuffer {
        precondition(original.width == width && graded.width == width && original.height == height)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw VideoError.writer("display pixel buffer")
        }
        for (key, value) in Self.colourAttachments {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
        if let space = Self.colourSpace {
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        }
        let luma = try planeTexture(buffer, plane: 0, format: .r8Unorm)
        let chroma = try planeTexture(buffer, plane: 1, format: .rg8Unorm)
        // even, so a 2x2 chroma block never straddles the split
        let column = UInt32(min(max(Int((split * Double(width) / 2).rounded()) * 2, 0), width))
        try kernels.compositeNV12(original: original, graded: graded,
                                  luma: CVMetalTextureGetTexture(luma)!, chroma: CVMetalTextureGetTexture(chroma)!,
                                  splitColumn: column, layout: layout)
        withExtendedLifetime((luma, chroma)) {}
        return buffer
    }

    private func planeTexture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) throws -> CVMetalTexture {
        var tex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format,
                                                        CVPixelBufferGetWidthOfPlane(buffer, plane),
                                                        CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &tex)
                == kCVReturnSuccess, let tex else { throw VideoError.writer("display plane \(plane)") }
        return tex
    }

    /// A sample buffer to enqueue for immediate display.
    public func sampleBuffer(original: MTLTexture, graded: MTLTexture, split: Double,
                             layout: CompareLayout) throws -> CMSampleBuffer {
        let buffer = try pixelBuffer(original: original, graded: graded, split: split, layout: layout)
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                           formatDescriptionOut: &format) == noErr, let format else {
            throw VideoError.writer("display format description")
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else {
            throw VideoError.writer("display sample buffer")
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

extension GradeKernels {
    /// Split-select two BGRA8 textures into '420v' planes, BT.709 limited (Display.metal).
    public func compositeNV12(original: MTLTexture, graded: MTLTexture, luma: MTLTexture, chroma: MTLTexture,
                              splitColumn: UInt32, layout: CompareLayout) throws {
        var params = SIMD2<UInt32>(splitColumn, layout.rawValue)
        let pipeline = try metal.pipeline("display_composite_nv12")
        try metal.run { enc in
            enc.setComputePipelineState(pipeline)
            enc.setTexture(original, index: 0)
            enc.setTexture(graded, index: 1)
            enc.setTexture(luma, index: 2)
            enc.setTexture(chroma, index: 3)
            enc.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 0)
            enc.dispatchThreads(MTLSize(width: chroma.width, height: chroma.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
    }
}
