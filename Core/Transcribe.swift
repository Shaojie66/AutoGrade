import AVFoundation
import Foundation
import Speech

/// On-device speech recognition for subtitles (CLAUDE.md 字幕): Speech's
/// SpeechAnalyzer + SpeechTranscriber, macOS 26 and later only. Downloading a
/// language's model is the owner's decision (a red line): nothing here
/// downloads unless `downloadModel` is called.
@available(macOS 26.0, *)
public enum Transcriber {
    public enum ModelState: String, Sendable { case installed, needsDownload, unsupported }

    static func module(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    /// The supported locale equivalent to `identifier` ("zh-CN", "en_US", …), if any.
    public static func locale(for identifier: String) throws -> Locale? {
        try blocking { Unchecked(await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))) }.value
    }

    public static func supportedLanguages() throws -> [String] {
        try blocking { await SpeechTranscriber.supportedLocales.map(\.identifier).sorted() }
    }

    public static func modelState(_ locale: Locale) throws -> ModelState {
        let status = try blocking { Unchecked(await AssetInventory.status(forModules: [module(locale)])) }.value
        switch status {
        case .installed: return .installed
        case .supported, .downloading: return .needsDownload
        default: return .unsupported
        }
    }

    /// Reserve the locale and download its model (network; system-managed, shared
    /// with other apps). Only call after the owner agreed (CLAUDE.md 字幕).
    public static func downloadModel(_ locale: Locale, progress: (@Sendable (Double) -> Void)? = nil) throws {
        try blocking {
            try await AssetInventory.reserve(locale: locale)
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module(locale)]) else { return }
            let watch = Task {
                while !Task.isCancelled {
                    progress?(request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { watch.cancel() }
            try await request.downloadAndInstall()
            progress?(1)
        }
    }

    /// Recognise the first audio track of `url`: every word (Chinese: as the
    /// recogniser splits it) with its time in the source's timeline.
    public static func transcribe(_ url: URL, locale: Locale, cancel: CancelToken? = nil,
                                  progress: (@Sendable (Double) -> Void)? = nil) throws -> [SubtitleToken] {
        try blocking { try await run(url, locale: locale, cancel: cancel, progress: progress) }
    }

    private static func run(_ url: URL, locale: Locale, cancel: CancelToken?,
                            progress: (@Sendable (Double) -> Void)?) async throws -> [SubtitleToken] {
        let transcriber = module(locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VideoError.unsupported("no audio format for speech recognition in \(locale.identifier)")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        let collect = Task {
            var tokens: [SubtitleToken] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    tokens.append(SubtitleToken(text: text, start: range.start.seconds, end: range.end.seconds,
                                                confidence: run.transcriptionConfidence.map(Float.init)))
                }
            }
            return tokens
        }
        try await analyzer.start(inputSequence: input)

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            feed.finish()
            await analyzer.cancelAndFinishNow()
            throw VideoError.unsupported("\(url.lastPathComponent) has no audio track")
        }
        let duration = try await asset.load(.duration).seconds
        // AVAssetReader resamples straight to the recogniser's format (and honours
        // the edit list, as the export does).
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: format.commonFormat == .pcmFormatInt16 ? 16 : 32,
            AVLinearPCMIsFloatKey: format.commonFormat != .pcmFormatInt16,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw VideoError.reader(reader.error?.localizedDescription ?? "audio for speech") }
        while let sample = output.copyNextSampleBuffer() {
            if cancel?.isCancelled == true {
                reader.cancelReading()
                feed.finish()
                await analyzer.cancelAndFinishNow()
                collect.cancel()
                throw Cancelled()
            }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                                      into: buffer.mutableAudioBufferList)
            guard status == noErr else { throw VideoError.reader("audio for speech: \(status)") }
            let start = CMSampleBufferGetPresentationTimeStamp(sample)
            feed.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
            progress?(min(1, (start.seconds + Double(frames) / format.sampleRate) / max(duration, 1e-3)))
        }
        if reader.status == .failed { throw VideoError.reader(reader.error?.localizedDescription ?? "audio for speech") }
        feed.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collect.value
    }
}
