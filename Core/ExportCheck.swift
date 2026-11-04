import AVFoundation
import CryptoKit
import Foundation
import Metal

/// What the check after an export found (CLAUDE.md 导出). `failures` empty = passed.
public struct ExportReport: Sendable {
    /// One sampled frame: the export decoded with our BT.709 convention vs the
    /// bytes the grading kernel produces for the same source frame and LUT.
    public struct Frame: Sendable {
        public let frame: Int
        public let shot: Int
        public let meanAbs: Double         // 8-bit levels, all channels
        public let bias: [Double]          // per R, G, B: mean(export - expected)
    }

    public var failures: [String] = []
    /// Not failures: why audio was not (fully) copied, from the render.
    public var warnings: [String] = []
    public var frames: [Frame] = []
    public var videoSamples = 0
    public var audioPackets: Int?
    /// Burnt-in subtitles: share of the subtitle band's pixels far off, per sampled frame.
    public var subtitleBands: [Double] = []
    /// Decoded audio: largest sample difference, and (source, export) length in frames.
    public var audioMaxDiff: Float?
    public var audioFrames: (source: Int, export: Int)?
    public var seconds = 0.0
    public var passed: Bool { failures.isEmpty }
}

public enum ExportCheck {
    /// Frames sampled at most: each shot's middle frame, evenly spread if there are more shots.
    public static let maxFrames = 12
    /// Thresholds in 8-bit levels (CLAUDE.md 容差表). Measured 2026-11-03: good
    /// exports at most mean 2.40 / bias 1.27 (synthetic, ProRes) and 2.27 / 0.87
    /// on the owner's clips; one shot ungraded by mistake: mean 12.1 / bias -12.4.
    public static let maxMeanAbs = 4.0
    public static let maxBias = 3.0
    /// Subtitle band: the share of pixels off by more than `subtitleFarLevels` (text vs
    /// no text differs by ~200 levels; codec noise rarely by 64). Measured: see CLAUDE.md 容差表.
    public static let subtitleFarLevels = 64
    public static let maxSubtitleFarFraction = 0.01
    /// Decoded audio, export vs source (CLAUDE.md 容差表; measured 1.5e-7 on the owner's gym clip).
    public static let maxAudioDiff: Float = 1e-6

    /// Rows where a subtitle can sit in a `width` x `height` output (SubtitleRenderer's
    /// placement, two lines plus margins), for the per-frame subtitle comparison.
    static func subtitleBand(width w: Int, height h: Int) -> Range<Int> {
        let vertical = h > w
        let size = Double(vertical ? w : h) * Double(SubtitleRenderer.sizeFraction)
        let span = Int((size * 3.2).rounded(.up))                     // two lines + stroke, shadow, padding
        if vertical {
            let c = Int((Double(h) * Double(SubtitleRenderer.verticalCentre)).rounded())
            return max(c - span / 2, 0)..<min(c + span / 2, h)
        }
        let bottom = h - Int((Double(h) * Double(SubtitleRenderer.bottomMargin)).rounded())
        return max(bottom - span, 0)..<bottom
    }

    /// The shots whose middle frames are sampled.
    static func sampledShots(_ count: Int) -> [Int] {
        guard count > maxFrames else { return Array(0..<count) }
        return (0..<maxFrames).map { Int((Double($0) * Double(count - 1) / Double(maxFrames - 1)).rounded()) }
    }
}

extension AutoGrader {
    /// Check an export `render` just wrote against the analysis it was made from.
    /// Never touches the file; a failed check is reported, not acted on.
    /// `expectedHook` sees each sampled frame's expected BGRA bytes before they are
    /// compared (tests: the expectation must be the export's own bytes).
    public func checkExport(_ output: URL, source: URL, analysis: Analysis, luts: [LUT3D],
                            render: RenderResult, expectedHook: ((Int, [UInt8]) -> Void)? = nil) throws -> ExportReport {
        let start = CFAbsoluteTimeGetCurrent()
        var report = ExportReport()
        try check(output, source: source, analysis: analysis, luts: luts, render: render, expectedHook: expectedHook, into: &report)
        report.seconds = CFAbsoluteTimeGetCurrent() - start
        return report
    }

    private func check(_ output: URL, source: URL, analysis: Analysis, luts: [LUT3D], render: RenderResult,
                       expectedHook: ((Int, [UInt8]) -> Void)?, into report: inout ExportReport) throws {

        // 1. video samples: every timestamp, without decoding
        let video = try Samples.read(output, .video)
        report.videoSamples = video.times.count
        let sorted = video.times.sorted()
        let timesMatch = sorted == analysis.frameTimes
        if !timesMatch {
            let firstBad = (0..<min(sorted.count, analysis.frameCount)).first { sorted[$0] != analysis.frameTimes[$0] }
            report.failures.append("video timestamps: \(video.times.count) frames, the analysis has \(analysis.frameCount)"
                                   + (firstBad.map { "; first difference at frame \($0)" } ?? ""))
        }

        // 2. size, codec, BT.709 tags
        if let format = video.format {
            let size = CMVideoFormatDescriptionGetDimensions(format)
            let expectedSize = render.reframe?.outputSize ?? (analysis.info.width, analysis.info.height)
            if Int(size.width) != expectedSize.0 || Int(size.height) != expectedSize.1 {
                report.failures.append("size \(size.width)x\(size.height), expected \(expectedSize.0)x\(expectedSize.1)")
            }
            let codec = CMFormatDescriptionGetMediaSubType(format)
            let want = render.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_AppleProRes422
            if codec != want { report.failures.append("codec \(fourCC(codec)), expected \(fourCC(want))") }
            let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
            for (key, value) in [(kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2),
                                 (kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_709_2),
                                 (kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)] {
                let got = ext[key as String] as? String
                if got != value as String { report.failures.append("\(key) is \(got ?? "missing"), expected \(value)") }
            }
        } else {
            report.failures.append("no video format description")
        }

        // 3. audio: there exactly when it was copied, and it plays back as the source does.
        // Compared decoded (Apple's decoder, what QuickTime plays), not as packets:
        // the writer rebuilds AAC priming its own way (CLAUDE.md 导出).
        let audio = try Samples.read(output, .audio)
        if let copied = render.audioPackets {
            report.audioPackets = audio.count
            if audio.format == nil {
                report.failures.append("no audio track, but \(copied) packets were copied")
            } else {
                let c = try DecodedAudio.compare(source, output)
                report.audioMaxDiff = c.maxDiff
                report.audioFrames = (c.source, c.export)
                if c.channels.source != c.channels.export {
                    report.failures.append("audio has \(c.channels.export) channels, the source \(c.channels.source)")
                }
                if c.maxDiff > ExportCheck.maxAudioDiff {
                    report.failures.append(String(format: "audio differs from the source: max %.2e", c.maxDiff))
                }
                if abs(c.source - c.export) > c.allowedFrames {
                    report.failures.append("audio length: \(c.export) frames, the source \(c.source) "
                                           + "(allowed difference \(c.allowedFrames))")
                }
            }
        } else if audio.format != nil {
            report.failures.append("an audio track is present, but none was copied")
        }

        // 4. pixels: each sampled shot's middle frame, export vs the grading kernel
        guard timesMatch else {
            report.failures.append("frames not sampled: timestamps do not match")
            return
        }
        let (w, h) = render.reframe?.outputSize ?? (analysis.info.width, analysis.info.height)
        let targets = try PreviewTargets(kernels: kernels, width: analysis.info.width, height: analysis.info.height)
        let reframed = try render.reframe.map {
            try ReframeTargets(kernels: kernels, sourceWidth: analysis.info.width, sourceHeight: analysis.info.height, aspect: $0.aspect)
        }
        // the same enhancements, prepared from the same window as the render did
        let enhancer = try render.enhance.map {
            try Enhancer(settings: $0, width: analysis.info.width, height: analysis.info.height, kernels: kernels)
        }
        for k in ExportCheck.sampledShots(analysis.shots.count) {
            // one pool per sample: at 5.3K each sample's buffers are ~0.6 GB and a command-line
            // process has no run loop to drain them (2026-11-04: check peaked at 3.6 GB)
            try autoreleasepool {
            let shot = analysis.shots[k], index = (shot.first + shot.last) / 2
            let sourceFrame = try decodeFrame(source, analysis: analysis, index: index, enhancer: enhancer, exact: true)
            let texture: MTLTexture
            if let path = render.reframe, let reframed {
                try previewReframed(sourceFrame, lut: luts[k], path: path, into: reframed, subtitles: render.subtitles)
                texture = reframed.output
            } else {
                try preview(sourceFrame, lut: luts[k], into: targets, subtitles: render.subtitles)
                texture = targets.graded
            }
            var expected = [UInt8](repeating: 0, count: w * h * 4)
            texture.getBytes(&expected, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            expectedHook?(index, expected)

            let reader = try VideoReader(url: output, device: metal.device, timeRange: analysis.timeRange(first: index, last: index),
                                         frameTimes: analysis.frameTimes, checkingFormat: false)
            guard let decoded = try reader.next(), decoded.index == index else {
                report.failures.append("shot \(k + 1): frame \(index) could not be decoded from the export")
                return
            }
            let rgb = try kernels.yuvToRGB(luma: decoded.luma, chroma: decoded.chroma, fullRange: decoded.fullRange).floats()
            let n = w * h
            var sumAbs = 0.0, bias = [0.0, 0.0, 0.0]
            for i in 0..<n {
                for (c, byte) in [(0, 2), (1, 1), (2, 0)] {   // BGRA byte order
                    let d = Double(quantize8(rgb[c * n + i])) - Double(expected[i * 4 + byte])
                    sumAbs += abs(d)
                    bias[c] += d
                }
            }
            let frame = ExportReport.Frame(frame: index, shot: k, meanAbs: sumAbs / Double(3 * n),
                                           bias: bias.map { $0 / Double(n) })
            report.frames.append(frame)
            // Subtitles are a small part of the frame: a missing or wrong cue hardly moves the
            // whole-frame mean, so the band where any subtitle would sit is compared on its own.
            if render.subtitles != nil {
                let band = ExportCheck.subtitleBand(width: w, height: h)
                var far = 0, count = 0
                for y in band.lowerBound..<band.upperBound {
                    for x in 0..<w {
                        let i = y * w + x
                        let d = [(0, 2), (1, 1), (2, 0)].map { c, byte in
                            abs(Int(quantize8(rgb[c * n + i])) - Int(expected[i * 4 + byte]))
                        }.max()!
                        if d > ExportCheck.subtitleFarLevels { far += 1 }
                        count += 1
                    }
                }
                let fraction = Double(far) / Double(max(count, 1))
                report.subtitleBands.append(fraction)
                if fraction > ExportCheck.maxSubtitleFarFraction {
                    report.failures.append(String(format: "shot %d (frame %d): the subtitle area does not match "
                                                  + "(%.2f%% of its pixels off by more than %d levels)", k + 1, index,
                                                  100 * fraction, ExportCheck.subtitleFarLevels))
                }
            }
            if frame.meanAbs > ExportCheck.maxMeanAbs || frame.bias.contains(where: { abs($0) > ExportCheck.maxBias }) {
                report.failures.append(String(format: "shot %d (frame %d) does not match its grade: mean %.2f levels, "
                                              + "bias R %+.2f G %+.2f B %+.2f", k + 1, index, frame.meanAbs,
                                              frame.bias[0], frame.bias[1], frame.bias[2]))
            }
            }
        }
    }
}

/// Two files' first audio tracks decoded by Apple's decoder (float32, native
/// channels) and compared sample by sample, streamed so long files stay small.
enum DecodedAudio {
    struct Comparison {
        var maxDiff: Float = 0
        var source = 0, export = 0             // frames
        var channels = (source: 0, export: 0)
        var allowedFrames = 0                  // one compressed packet (AAC 1024), 0 for PCM
    }

    private final class Stream {
        let reader: AVAssetReader, output: AVAssetReaderTrackOutput
        var samples: [Float] = [], channels = 0, framesPerPacket = 1, frames = 0, ended = false

        init(_ url: URL) throws {
            let asset = AVURLAsset(url: url)
            // AVAssetTrack is not Sendable: load it and its formats in one go (as VideoReader does).
            let loaded = try blocking { () -> Unchecked<(AVAssetTrack, [CMFormatDescription])?> in
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return Unchecked(nil) }
                return Unchecked((track, try await track.load(.formatDescriptions)))
            }
            guard let (track, formats) = loaded.value else { throw VideoError.reader("\(url.lastPathComponent) has no audio") }
            if let f = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                framesPerPacket = Int(max(asbd.mFramesPerPacket, 1))
            }
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            ])
            reader.add(output)
            guard reader.startReading() else { throw VideoError.reader(reader.error?.localizedDescription ?? "audio decode") }
        }

        /// Decode until at least `count` samples are buffered or the track ends.
        func fill(_ count: Int) throws {
            while !ended && samples.count < count {
                guard let buffer = output.copyNextSampleBuffer() else {
                    if reader.status == .failed { throw VideoError.reader(reader.error?.localizedDescription ?? "audio decode") }
                    ended = true
                    return
                }
                if channels == 0, let f = CMSampleBufferGetFormatDescription(buffer),
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                    channels = Int(asbd.mChannelsPerFrame)
                }
                guard let data = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let n = CMBlockBufferGetDataLength(data) / 4
                let start = samples.count
                samples += [Float](repeating: 0, count: n)
                samples.withUnsafeMutableBytes { dst in
                    _ = CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: n * 4, destination: dst.baseAddress! + start * 4)
                }
            }
        }
    }

    static func compare(_ source: URL, _ export: URL) throws -> Comparison {
        let a = try Stream(source), b = try Stream(export)
        var result = Comparison()
        let chunk = 1 << 16
        while true {
            try a.fill(chunk)
            try b.fill(chunk)
            let n = min(a.samples.count, b.samples.count)
            for i in 0..<n { result.maxDiff = max(result.maxDiff, abs(a.samples[i] - b.samples[i])) }
            a.samples.removeFirst(n)
            b.samples.removeFirst(n)
            a.frames += n; b.frames += n
            if (a.ended && a.samples.isEmpty) || (b.ended && b.samples.isEmpty) { break }
        }
        // whatever is left on one side only counts toward the length difference
        try a.fill(.max); try b.fill(.max)
        a.frames += a.samples.count; b.frames += b.samples.count
        result.channels = (a.channels, b.channels)
        let ch = max(a.channels, 1)
        result.source = a.frames / ch
        result.export = b.frames / ch
        result.allowedFrames = a.framesPerPacket > 1 ? a.framesPerPacket : 0
        return result
    }
}

/// Compressed samples of a file's first track of one media type, read as stored.
struct Samples {
    var format: CMFormatDescription?
    var times: [CMTime] = []      // per sample, in decode order
    var count = 0
    var digest = ""               // sha256 of every sample's bytes, in order

    static func read(_ url: URL, _ type: AVMediaType) throws -> Samples {
        let asset = AVURLAsset(url: url)
        let loaded = try blocking { Unchecked(try await asset.loadTracks(withMediaType: type).first) }
        guard let track = loaded.value else { return Samples() }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw VideoError.reader("cannot read \(type.rawValue) samples") }
        reader.add(output)
        guard reader.startReading() else { throw VideoError.reader(reader.error?.localizedDescription ?? "startReading") }
        var result = Samples(), hash = SHA256()
        while let buffer = output.copyNextSampleBuffer() {
            let n = CMSampleBufferGetNumSamples(buffer)
            guard n > 0 else { continue }
            result.format = result.format ?? CMSampleBufferGetFormatDescription(buffer)
            var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: n)
            var entries = 0
            CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: n, arrayToFill: &timing, entriesNeededOut: &entries)
            if entries == n {
                result.times += timing.map(\.presentationTimeStamp)
            } else {   // one entry for the whole buffer: samples of equal duration
                let first = CMSampleBufferGetPresentationTimeStamp(buffer), step = timing[0].duration
                result.times += (0..<n).map { CMTimeAdd(first, CMTimeMultiply(step, multiplier: Int32($0))) }
            }
            result.count += n
            if let data = CMSampleBufferGetDataBuffer(buffer) {
                let length = CMBlockBufferGetDataLength(data)
                var bytes = [UInt8](repeating: 0, count: length)
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: length, destination: &bytes)
                hash.update(data: bytes)
            }
        }
        if reader.status == .failed { throw VideoError.reader(reader.error?.localizedDescription ?? "failed") }
        result.digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return result
    }
}

private func fourCC(_ code: FourCharCode) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .macOSRoman) ?? "\(code)"
}
