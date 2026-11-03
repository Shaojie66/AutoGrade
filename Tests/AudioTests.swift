import AutoGradeCore
import AVFoundation
import CryptoKit
import XCTest

/// Audio is copied as it is (CLAUDE.md 导出): the same compressed packets, the
/// same timestamps, nothing re-encoded or trimmed.
final class AudioTests: XCTestCase {
    var engine: AutoGrader!
    var dir: URL!
    let av = Fixtures.url("synthetic_av.mp4")

    override func setUpWithError() throws {
        engine = try AutoGrader(stylesDirectory: nil)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("autograde-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)   // this test's own temporary directory
    }

    private func render(_ source: URL, audio: Bool) throws -> (URL, RenderResult) {
        let analysis = try engine.analyze(source, lutSize: 33)
        let out = dir.appendingPathComponent("\(UUID().uuidString).mov")
        return (out, try engine.render(source, analysis: analysis, luts: analysis.luts, to: out, audio: audio))
    }

    func testAudioIsCopiedPacketForPacket() throws {
        let (out, result) = try render(av, audio: true)
        let source = try compressedAudio(av), copy = try compressedAudio(out)
        print("audio: source \(source.packets) packets \(source.start.seconds)-\(source.end.seconds) s, "
              + "copy \(copy.packets) packets \(copy.start.seconds)-\(copy.end.seconds) s")
        XCTAssertEqual(source.packets, 470)
        XCTAssertEqual(result.audioPackets, 470)
        XCTAssertEqual(copy.packets, source.packets)
        XCTAssertEqual(copy.digest, source.digest, "packet bytes are the source's")
        XCTAssertEqual(copy.codec, kAudioFormatMPEG4AAC, "not re-encoded")
        XCTAssertEqual(copy.start, source.start)
        XCTAssertEqual(copy.end, source.end, "not trimmed to the video (audio is 7 s longer)")
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
    }

    func testNoAudioWhenTurnedOff() throws {
        let (out, result) = try render(av, audio: false)
        XCTAssertNil(result.audioPackets)
        XCTAssertNil(try compressedAudio(out).codec, "no audio track")
    }

    func testSourceWithoutAudioExportsWithoutWarnings() throws {
        let (out, result) = try render(Fixtures.url("synthetic_shots.mp4"), audio: true)
        XCTAssertNil(result.audioPackets)
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
        XCTAssertNil(try compressedAudio(out).codec)
    }
}

/// The first audio track's compressed packets, read independently of Core.
func compressedAudio(_ url: URL) throws -> (codec: AudioFormatID?, packets: Int, digest: String, start: CMTime, end: CMTime) {
    final class Box: @unchecked Sendable { var track: AVAssetTrack? }   // written once, before the signal
    let asset = AVURLAsset(url: url), box = Box(), done = DispatchSemaphore(value: 0)
    Task.detached { box.track = try? await asset.loadTracks(withMediaType: .audio).first; done.signal() }
    done.wait()
    guard let track = box.track else { return (nil, 0, "", .invalid, .invalid) }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    var hash = SHA256(), packets = 0, codec: AudioFormatID?, start = CMTime.invalid, end = CMTime.invalid
    while let buffer = output.copyNextSampleBuffer() {
        let n = CMSampleBufferGetNumSamples(buffer)
        guard n > 0 else { continue }
        if codec == nil, let format = CMSampleBufferGetFormatDescription(buffer) {
            codec = CMFormatDescriptionGetMediaSubType(format)
            start = CMSampleBufferGetPresentationTimeStamp(buffer)
        }
        end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(buffer), CMSampleBufferGetDuration(buffer))
        packets += n
        if let data = CMSampleBufferGetDataBuffer(buffer) {
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(data))
            CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: bytes.count, destination: &bytes)
            hash.update(data: bytes)
        }
    }
    return (codec, packets, hash.finalize().map { String(format: "%02x", $0) }.joined(), start, end)
}
