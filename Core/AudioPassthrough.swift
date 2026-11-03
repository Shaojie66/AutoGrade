import AVFoundation
import Foundation

/// Copies the source's first audio track into a VideoWriter untouched: the
/// compressed packets as they are, same timestamps, nothing trimmed
/// (CLAUDE.md 导出). It never blocks: `pump` appends for as long as the writer
/// takes audio and keeps the rest for the next call. The writer's own
/// readiness does the interleaving — it may want audio ahead of the video it
/// has (2026-11-03: feeding audio only up to the current video time deadlocked
/// both inputs). `drain` runs once video is done.
public final class AudioPassthrough {
    let input: AVAssetWriterInput
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pending: CMSampleBuffer?
    private(set) var finished = false
    private(set) var packets = 0

    /// nil when the source has no audio; `warnings` says why a track was skipped.
    static func make(from url: URL, warnings: inout [String]) throws -> AudioPassthrough? {
        let asset = AVURLAsset(url: url)
        let loaded = try blocking {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let first = tracks.first else { return Unchecked<(AVAssetTrack, CMFormatDescription?, Int)?>(nil) }
            return Unchecked((first, try await first.load(.formatDescriptions).first, tracks.count))
        }
        guard let (track, format, count) = loaded.value else { return nil }
        if count > 1 { warnings.append("the source has \(count) audio tracks; only the first is copied") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)   // compressed, as stored
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            warnings.append("the audio track cannot be read as it is stored; exported without audio")
            return nil
        }
        reader.add(output)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        return AudioPassthrough(reader: reader, output: output, input: input)
    }

    private init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
        self.reader = reader
        self.output = output
        self.input = input
    }

    /// Call after the writer has started.
    func start() throws {
        guard reader.startReading() else {
            throw VideoError.reader("audio: " + (reader.error?.localizedDescription ?? "startReading"))
        }
    }

    /// Append audio packets for as long as the writer accepts them now.
    func pump() throws {
        while !finished {
            if pending == nil {
                pending = output.copyNextSampleBuffer()
                if pending == nil {
                    if reader.status == .failed {
                        throw VideoError.reader("audio: " + (reader.error?.localizedDescription ?? "failed"))
                    }
                    input.markAsFinished()
                    finished = true
                    return
                }
            }
            guard let buffer = pending, input.isReadyForMoreMediaData else { return }
            guard input.append(buffer) else { throw VideoError.writer("audio append failed") }
            packets += CMSampleBufferGetNumSamples(buffer)
            pending = nil
        }
    }

    /// Everything that is left; video is finished, so the writer no longer waits on it.
    func drain(writerFailed: () -> Error?) throws {
        let deadline = Date().addingTimeInterval(VideoWriter.stallLimit)
        while !finished {
            try pump()
            if finished { break }
            if let error = writerFailed() { throw error }
            if Date() > deadline { throw VideoError.writer("audio input stalled for \(Int(VideoWriter.stallLimit)) s") }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    func cancel() { reader.cancelReading() }

    /// How many audio tracks `url` has (the export copies the first).
    public static func trackCount(_ url: URL) throws -> Int {
        let asset = AVURLAsset(url: url)
        return try blocking { try await asset.loadTracks(withMediaType: .audio).count }
    }
}
