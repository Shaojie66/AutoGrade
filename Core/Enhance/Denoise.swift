import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox

/// VideoToolbox's temporal noise filter over decoder '420v' / '420f' frames
/// (CLAUDE.md 画质增强 / 降噪): each frame is converted losslessly to the
/// filter's format of the same range ('&8v0' / '&8f0'), filtered with its
/// neighbours in the same shot, and converted back to the decoder's format so
/// the usual `yuv420_to_rgb` reads it. The range is taken from the first frame
/// (all frames of a video share it). The filter is recursive: a frame's output
/// depends on every frame of its chain before it, so each chain gets a fresh
/// session (`restart`), started on its first frame.
@available(macOS 26.0, *)
final class Denoiser {
    let previousCount: Int
    let nextCount: Int
    private let width: Int
    private let height: Int
    private var processor = VTFrameProcessor()
    private var started = false
    private var format: Format?
    private let transfer: VTPixelTransferSession
    private let cache: CVMetalTextureCache

    /// Everything that depends on the frames' range.
    private struct Format {
        let fullRange: Bool
        let configuration: VTTemporalNoiseFilterConfiguration
        let sourcePool: CVPixelBufferPool
        let destinationPool: CVPixelBufferPool
        let outputPool: CVPixelBufferPool
    }

    init(width: Int, height: Int, device: MTLDevice) throws {
        guard VTTemporalNoiseFilterConfiguration.isSupported,
              let probe = Self.configuration(width: width, height: height, fullRange: false) else {
            throw VideoError.unsupported("noise filter for \(width)x\(height)")
        }
        self.width = width
        self.height = height
        previousCount = probe.previousFrameCount ?? 0
        nextCount = probe.nextFrameCount ?? 0
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr, let session else {
            throw VideoError.reader("VTPixelTransferSessionCreate")
        }
        transfer = session
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw VideoError.reader("CVMetalTextureCacheCreate")
        }
        self.cache = cache
    }

    deinit { if started { Self.end(processor) } }

    private static func configuration(width: Int, height: Int, fullRange: Bool) -> VTTemporalNoiseFilterConfiguration? {
        VTTemporalNoiseFilterConfiguration(
            frameWidth: width, frameHeight: height,
            sourcePixelFormat: fullRange ? kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange
                                         : kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange)
    }

    /// The pools and the first session for frames of this range; a later frame of
    /// the other range is refused rather than range-converted.
    private func format(for fullRange: Bool) throws -> Format {
        if let format {
            guard format.fullRange == fullRange else { throw VideoError.reader("noise filter: frames changed range") }
            return format
        }
        guard let configuration = Self.configuration(width: width, height: height, fullRange: fullRange) else {
            throw VideoError.unsupported("noise filter for \(width)x\(height) (\(fullRange ? "full" : "limited") range)")
        }
        let made = Format(
            fullRange: fullRange, configuration: configuration,
            sourcePool: try Self.pool(configuration.sourcePixelBufferAttributes),
            destinationPool: try Self.pool(configuration.destinationPixelBufferAttributes),
            outputPool: try Self.pool([
                kCVPixelBufferPixelFormatTypeKey as String: fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                                                      : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]))
        try processor.startSession(configuration: configuration)
        started = true
        format = made
        return made
    }

    /// A new session for a new chain: a session never accepts a repeated or
    /// earlier timestamp (it hung, 2026-11-04), and its state carries the chain.
    func restart() throws {
        guard let format else { return }   // no frame yet: the first one starts the first session
        let fresh = VTFrameProcessor()
        try fresh.startSession(configuration: format.configuration)
        Self.end(processor)
        processor = fresh
    }

    /// `endSession()` hangs on the main thread (CLAUDE.md 实测), so it runs on its own.
    private static func end(_ p: VTFrameProcessor) {
        nonisolated(unsafe) let p = p
        Thread { p.endSession() }.start()
    }

    /// `frame` in the filter's own format (lossless, so converting again gives the same bytes).
    func source(_ frame: DecodedFrame) throws -> CVPixelBuffer {
        let out = try Self.make(try format(for: frame.fullRange).sourcePool)
        let status = VTPixelTransferSessionTransferImage(transfer, from: frame.pixelBuffer, to: out)
        guard status == noErr else { throw VideoError.reader("noise filter input conversion: \(status)") }
        return out
    }

    /// The filtered frame. `previous` / `next` are the neighbours' `source`
    /// buffers with their times, nearest last / first, already limited to the shot.
    func process(_ frame: DecodedFrame, source: CVPixelBuffer, previous: [(CVPixelBuffer, CMTime)],
                 next: [(CVPixelBuffer, CMTime)], startsChain: Bool, strength: Float) throws -> DecodedFrame {
        func wrap(_ b: CVPixelBuffer, _ t: CMTime) throws -> VTFrameProcessorFrame {
            try XUnwrap(VTFrameProcessorFrame(buffer: b, presentationTimeStamp: t), "noise filter frame")
        }
        let f = try format(for: frame.fullRange)
        let destination = try wrap(try Self.make(f.destinationPool), frame.presentationTime)
        guard let parameters = VTTemporalNoiseFilterParameters(
            sourceFrame: try wrap(source, frame.presentationTime), nextFrames: try next.map(wrap),
            previousFrames: try previous.map(wrap), destinationFrame: destination,
            filterStrength: min(max(strength, 0), 1), hasDiscontinuity: startsChain) else {
            throw VideoError.reader("noise filter parameters")
        }
        // The completion-handler form: the synchronous one returned before the
        // output was written (all zeros) in the super-resolution probe.
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        processor.process(parameters: parameters) { _, error in
            failure = error
            done.signal()
        }
        // A repeated or earlier timestamp never completes (2026-11-04): fail instead of hanging.
        guard done.wait(timeout: .now() + 10) == .success else {
            throw VideoError.reader("noise filter did not finish frame \(frame.index) within 10 s")
        }
        if let failure { throw failure }
        let out = try Self.make(f.outputPool)
        let status = VTPixelTransferSessionTransferImage(transfer, from: destination.buffer, to: out)
        guard status == noErr else { throw VideoError.reader("noise filter output conversion: \(status)") }
        return try DecodedFrame(index: frame.index, presentationTime: frame.presentationTime, pixelBuffer: out, cache: cache)
    }

    private static func pool(_ attributes: [String: Any]) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw VideoError.reader("pixel buffer pool")
        }
        return pool
    }

    private static func make(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw VideoError.reader("pixel buffer")
        }
        return buffer
    }
}
