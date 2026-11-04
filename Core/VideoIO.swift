import AVFoundation
import CoreVideo
import Foundation
import Metal
import Synchronization

public enum VideoError: Error, CustomStringConvertible {
    case noVideoTrack
    case unsupported(String)
    case reader(String)
    case writer(String)

    public var description: String {
        switch self {
        case .noVideoTrack: "the file has no video track"
        case .unsupported(let why): "unsupported input: \(why)"
        case .reader(let why): "reading failed: \(why)"
        case .writer(let why): "writing failed: \(why)"
        }
    }
}

/// Runs an async AVFoundation load from synchronous code (the CLI and the
/// two-pass pipeline are deliberately synchronous).
private final class ResultBox<T>: @unchecked Sendable {   // written once, before the semaphore signals
    var result: Result<T, Error>?
}

struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

func blocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    // Inherit the waiter's priority, or a user-interactive caller waits on a
    // default-QoS task (Thread Performance Checker: priority inversion).
    Task.detached(priority: Task.currentPriority) {
        do { box.result = .success(try await operation()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}

public struct VideoInfo: Sendable {
    public let width: Int
    public let height: Int
    public let nominalFrameRate: Float
    public let duration: CMTime
    /// The video track's own time scale; the export writes its track in it (CLAUDE.md 导出).
    public let timeScale: CMTimeScale
    /// Full-range ('420f') planes; false is limited ('420v'), also when untagged (CLAUDE.md 架构原则 4).
    public let fullRange: Bool
}

/// One decoded frame: the decoder's own 4:2:0 planes as Metal textures.
/// Hold it until the GPU work reading `luma`/`chroma` has completed.
public struct DecodedFrame {
    public let index: Int
    public let presentationTime: CMTime
    public let pixelBuffer: CVPixelBuffer
    public let luma: MTLTexture
    public let chroma: MTLTexture
    /// The planes' range, from the buffer's pixel format: '420f' full, '420v' limited.
    public let fullRange: Bool
    let lumaRef: CVMetalTexture
    let chromaRef: CVMetalTexture

    /// Metal views of a '420v' or '420f' buffer's two planes.
    init(index: Int, presentationTime: CMTime, pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache) throws {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            throw VideoError.reader("unexpected pixel format \(format)")
        }
        fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        func texture(_ plane: Int, _ format: MTLPixelFormat) throws -> CVMetalTexture {
            var tex: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixelBuffer, nil, format,
                CVPixelBufferGetWidthOfPlane(pixelBuffer, plane), CVPixelBufferGetHeightOfPlane(pixelBuffer, plane), plane, &tex)
            guard status == kCVReturnSuccess, let tex else { throw VideoError.reader("plane \(plane) texture: \(status)") }
            return tex
        }
        self.index = index
        self.presentationTime = presentationTime
        self.pixelBuffer = pixelBuffer
        lumaRef = try texture(0, .r8Unorm)
        chromaRef = try texture(1, .rg8Unorm)
        luma = CVMetalTextureGetTexture(lumaRef)!
        chroma = CVMetalTextureGetTexture(chromaRef)!
    }
}

/// Sequential decoder. Accepts only 8-bit 4:2:0 BT.709, limited or full range (or
/// untagged, treated as BT.709); anything else is refused rather than guessed
/// (CLAUDE.md 架构原则 4). Output is the decoder's native '420v' / '420f' planes, so no
/// colour conversion happens before our own kernel.
///
/// Reading from the start numbers frames by count. Reading a `timeRange`
/// needs the analysis' `frameTimes`: each frame's index is looked up from its
/// presentation time, never counted, because a range read on variable-frame-
/// rate footage cannot be trusted to start where a count would assume.
public final class VideoReader {
    public let info: VideoInfo
    public private(set) var warnings: [String] = []
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let cache: CVMetalTextureCache
    private let frameTimes: [CMTime]?
    private let rangeStart: CMTime?
    private var nextIndex = 0

    /// `checkingFormat: false` is only for reading back our own export (ExportCheck),
    /// e.g. ProRes, which is never accepted as a source.
    public init(url: URL, device: MTLDevice, timeRange: CMTimeRange? = nil, frameTimes: [CMTime]? = nil,
                checkingFormat: Bool = true) throws {
        precondition(timeRange == nil || frameTimes != nil, "a range read needs frameTimes to index frames")
        self.frameTimes = frameTimes
        self.rangeStart = timeRange?.start
        let asset = AVURLAsset(url: url)
        // AVAssetTrack is not Sendable; it is only touched inside this one load and
        // then used synchronously on this thread.
        let loaded = try blocking {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoError.noVideoTrack }
            return Unchecked((track, try await track.load(.naturalSize), try await track.load(.nominalFrameRate),
                              try await track.load(.formatDescriptions), try await asset.load(.duration),
                              try await track.load(.naturalTimeScale)))
        }
        let (track, size, rate, formats, duration, timeScale) = loaded.value
        guard let format = formats.first else { throw VideoError.unsupported("no format description") }
        warnings = checkingFormat ? try Self.checkFormat(format) : []
        let fullRange = Self.isFullRange(format)
        info = VideoInfo(width: Int(size.width), height: Int(size.height), nominalFrameRate: rate, duration: duration,
                         timeScale: timeScale, fullRange: fullRange)
        guard info.width % 2 == 0, info.height % 2 == 0 else {
            throw VideoError.unsupported("odd frame size \(info.width)x\(info.height)")
        }

        reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        // the decoder's own range: a full-range source read as '420v' is range-converted
        // by the system first, one more lossy step (CLAUDE.md 架构原则 4)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                                                  : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoError.reader("cannot add track output") }
        reader.add(output)
        guard reader.startReading() else { throw VideoError.reader(reader.error?.localizedDescription ?? "startReading") }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw VideoError.reader("CVMetalTextureCacheCreate")
        }
        self.cache = cache
    }

    private static func checkFormat(_ format: CMFormatDescription) throws -> [String] {
        var warnings: [String] = []
        let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        if let depth = ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int, depth != 8 {
            throw VideoError.unsupported("\(depth)-bit video (only 8-bit 4:2:0 BT.709 is supported)")
        }
        let codec = CMFormatDescriptionGetMediaSubType(format)
        if codec == kCMVideoCodecType_AppleProRes4444 || codec == kCMVideoCodecType_AppleProRes422HQ
            || codec == kCMVideoCodecType_AppleProRes422 || codec == kCMVideoCodecType_AppleProRes422LT
            || codec == kCMVideoCodecType_AppleProRes422Proxy || codec == kCMVideoCodecType_AppleProResRAW {
            throw VideoError.unsupported("ProRes sources (10-bit / 4:2:2) are not supported yet")
        }
        if let matrix = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String {
            guard matrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String) else {
                throw VideoError.unsupported("colour matrix \(matrix) (only BT.709 is supported)")
            }
        } else {
            warnings.append("no colour matrix tag; assuming BT.709")
        }
        if let transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
           transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
            throw VideoError.unsupported("HDR transfer \(transfer)")
        }
        return warnings
    }

    /// The format description's full-range flag; untagged is limited.
    static func isFullRange(_ format: CMFormatDescription) -> Bool {
        let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        return ext[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool ?? false
    }

    /// The next frame in decode-output (presentation) order, or nil at the end.
    public func next() throws -> DecodedFrame? {
        guard let sample = output.copyNextSampleBuffer() else {
            if reader.status == .failed { throw VideoError.reader(reader.error?.localizedDescription ?? "failed") }
            return nil
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return try next() }  // non-image sample
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        // A range read may hand back a frame that only overlaps the start.
        if let rangeStart, pts < rangeStart { return try next() }
        let index: Int
        if let frameTimes {
            guard let found = Self.index(of: pts, in: frameTimes) else {
                throw VideoError.reader("frame at \(pts.seconds) s is not in the analysed frame list")
            }
            index = found
        } else {
            index = nextIndex
            nextIndex += 1
        }
        return try DecodedFrame(index: index, presentationTime: pts, pixelBuffer: pixelBuffer, cache: cache)
    }

    static func index(of time: CMTime, in times: [CMTime]) -> Int? {
        var lo = 0, hi = times.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if times[mid] == time { return mid }
            if times[mid] < time { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }
}

public enum OutputCodec: String, CaseIterable, Sendable {
    case hevc, prores

    var avCodec: AVVideoCodecType { self == .hevc ? .hevc : .proRes422 }
}

/// Writes BGRA frames, tagged BT.709, at the source presentation times.
public final class VideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let cache: CVMetalTextureCache
    private let audio: AudioPassthrough?
    /// Why audio was not (fully) copied, if it was not.
    public private(set) var warnings: [String] = []
    /// Audio packets written, or nil when the file has no audio track.
    public var audioPackets: Int? { audio?.packets }

    /// `audioFrom`: copy that file's first audio track as it is (CLAUDE.md 导出).
    /// `timeScale`: the video track's time scale, the source's (CLAUDE.md 导出): the
    /// writer's default 600 cannot hold 1001/30000 s, so 29.97 / 59.94 fps frames
    /// were rounded and no longer at the source's times (2026-11-04, DJI clip).
    public init(url: URL, width: Int, height: Int, codec: OutputCodec, device: MTLDevice, audioFrom: URL? = nil,
                timeScale: CMTimeScale? = nil) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw VideoError.writer("\(url.path) already exists (refusing to overwrite)")
        }
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if codec == .hevc {
            settings[AVVideoCompressionPropertiesKey] = [AVVideoQualityKey: 0.9]
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        if let timeScale, timeScale > 0 {
            input.mediaTimeScale = timeScale
            writer.movieTimeScale = timeScale
        }
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        guard writer.canAdd(input) else { throw VideoError.writer("cannot add video input") }
        writer.add(input)
        var warnings: [String] = []
        var audio = try audioFrom.flatMap { try AudioPassthrough.make(from: $0, warnings: &warnings) }
        if let a = audio {
            if writer.canAdd(a.input) {
                writer.add(a.input)
            } else {
                warnings.append("the audio track cannot be copied into a .mov as it is; exported without audio")
                audio = nil
            }
        }
        self.audio = audio
        self.warnings = warnings
        guard writer.startWriting() else { throw VideoError.writer(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)
        try audio?.start()

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw VideoError.writer("CVMetalTextureCacheCreate")
        }
        self.cache = cache
    }

    /// A pooled BGRA buffer and its Metal view; fill it, then `append`.
    public func makeFrame() throws -> (CVPixelBuffer, MTLTexture, CVMetalTexture) {
        guard let pool = adaptor.pixelBufferPool else { throw VideoError.writer("no pixel buffer pool") }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw VideoError.writer("pixel buffer pool exhausted")
        }
        var tex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm,
                                                        CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
                                                        0, &tex) == kCVReturnSuccess, let tex else {
            throw VideoError.writer("BGRA texture")
        }
        return (buffer, CVMetalTextureGetTexture(tex)!, tex)
    }

    /// Waiting longer than this for either input is a stall, reported rather than waited out.
    static let stallLimit: TimeInterval = 10

    public func append(_ buffer: CVPixelBuffer, at time: CMTime) throws {
        let deadline = Date().addingTimeInterval(Self.stallLimit)
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw VideoError.writer(writer.error?.localizedDescription ?? "failed") }
            try audio?.pump()   // the writer may be waiting for audio to interleave
            if Date() > deadline { throw VideoError.writer("video input stalled for \(Int(Self.stallLimit)) s at \(time.seconds) s") }
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw VideoError.writer(writer.error?.localizedDescription ?? "append failed at \(time.seconds) s")
        }
        try audio?.pump()
    }

    /// Abandon the file. Only ever called on a file this writer created
    /// (`init` refuses an existing path), so removing it removes nothing else.
    public func cancel() {
        audio?.cancel()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: writer.outputURL)
    }

    public func finish() throws {
        input.markAsFinished()
        try audio?.drain { writer.status == .failed ? VideoError.writer(writer.error?.localizedDescription ?? "failed") : nil }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw VideoError.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }
}

/// Cooperative cancellation for analyze / render: set from any thread, checked once per frame.
public final class CancelToken: Sendable {
    private let flag = Atomic<Bool>(false)
    public init() {}
    public func cancel() { flag.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

public struct Cancelled: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "cancelled" }
}
