import AutoGradeCore
import AVFoundation
import Metal
import XCTest

/// Burnt-in subtitles: the preview is the export's bytes, the export passes the
/// check, and the check catches a cue that should not be there (CLAUDE.md 字幕).
final class SubtitleBurnTests: XCTestCase {
    var engine: AutoGrader!
    var dir: URL!
    let synthetic = Fixtures.url("synthetic_shots.mp4")
    let cues = [SubtitleCue(start: 0.2, end: 1.5, lines: ["第一条字幕"]), SubtitleCue(start: 2.0, end: 2.8, lines: ["Second", "two lines"])]

    override func setUpWithError() throws {
        engine = try AutoGrader(stylesDirectory: nil)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("autograde-subs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)   // this test's own temporary directory
    }

    private func analyze() throws -> Analysis {
        try engine.analyze(synthetic, lutSize: 33, cutThreshold: Fixtures.manifest.cut_threshold)
    }

    func testBurntPreviewIsByteIdenticalToExport() throws {
        let a = try analyze()
        let burn = SubtitleBurn(cues: cues, width: 320, height: 180, kernels: engine.kernels)
        let probe: Set = [3, 30, 50, 70, 89]          // in cue 1, in cue 1, between, in cue 2, after
        var exported: [Int: [UInt8]] = [:]
        _ = try engine.render(synthetic, analysis: a, luts: a.luts, to: dir.appendingPathComponent("s.mov"), subtitles: burn,
                              frameHook: { i, pb in if probe.contains(i) { exported[i] = bgra(pb) } })
        let targets = try PreviewTargets(kernels: engine.kernels, width: 320, height: 180)
        for i in probe.sorted() {
            try engine.preview(try engine.decodeFrame(synthetic, analysis: a, index: i), lut: a.luts[a.shotIndex(forFrame: i)],
                               into: targets, subtitles: burn)
            XCTAssertTrue(texture(targets.graded) == exported[i], "frame \(i): preview differs from the export")
        }
        // the subtitle is really there: frame 30 differs from an unsubtitled grade
        let plain = try PreviewTargets(kernels: engine.kernels, width: 320, height: 180)
        try engine.preview(try engine.decodeFrame(synthetic, analysis: a, index: 30), lut: a.luts[1], into: plain)
        XCTAssertNotEqual(texture(plain.graded), exported[30])
        try engine.preview(try engine.decodeFrame(synthetic, analysis: a, index: 50), lut: a.luts[1], into: plain)
        XCTAssertEqual(texture(plain.graded), exported[50], "no cue at frame 50: nothing burnt")
    }

    func testBurntReframedPreviewIsByteIdenticalToExport() throws {
        let a = try analyze()
        let track = SubtitleTrackless.centred(a.frameCount)
        let path = Reframe.path(track: track, shots: a.shots, frameTimes: a.frameTimes, width: 320, height: 180,
                                aspect: .vertical9x16, overrides: Array(repeating: nil, count: a.shots.count))
        let burn = SubtitleBurn(cues: cues, width: 1080, height: 1920, kernels: engine.kernels)
        var exported: [Int: [UInt8]] = [:]
        _ = try engine.render(synthetic, analysis: a, luts: a.luts, to: dir.appendingPathComponent("r.mov"), reframe: path,
                              subtitles: burn, frameHook: { i, pb in if i == 30 { exported[i] = bgra(pb) } })
        let targets = try ReframeTargets(kernels: engine.kernels, sourceWidth: 320, sourceHeight: 180, aspect: .vertical9x16)
        try engine.previewReframed(try engine.decodeFrame(synthetic, analysis: a, index: 30), lut: a.luts[1], path: path,
                                   into: targets, subtitles: burn)
        XCTAssertTrue(texture(targets.output) == exported[30], "成片 preview with subtitles differs from the export")
    }

    func testBurntExportPassesAndAMissingCueIsCaught() throws {
        let a = try analyze()
        let burn = SubtitleBurn(cues: cues, width: 320, height: 180, kernels: engine.kernels)
        let out = dir.appendingPathComponent("s.mov")
        let result = try engine.render(synthetic, analysis: a, luts: a.luts, to: out, subtitles: burn)
        let good = try engine.checkExport(out, source: synthetic, analysis: a, luts: a.luts, render: result)
        print("burnt: frames \(good.frames.map { String(format: "%.2f", $0.meanAbs) }), far-off share in the band \(good.subtitleBands.map { String(format: "%.4f", $0) })")
        XCTAssertTrue(good.passed, "\(good.failures)")
        XCTAssertEqual(good.subtitleBands.count, 3)

        // claim nothing was burnt: the whole-frame mean barely moves, the band check catches it
        let claimed = RenderResult(times: result.times, codec: result.codec, audioPackets: result.audioPackets, warnings: result.warnings,
                                   reframe: nil, subtitles: SubtitleBurn(cues: [], width: 320, height: 180, kernels: engine.kernels))
        let bad = try engine.checkExport(out, source: synthetic, analysis: a, luts: a.luts, render: claimed)
        print("missing cue: frames \(bad.frames.map { String(format: "%.2f", $0.meanAbs) }), far-off share in the band \(bad.subtitleBands.map { String(format: "%.4f", $0) })")
        XCTAssertEqual(bad.failures.filter { $0.contains("subtitle area does not match") }.count, 3, "\(bad.failures)")
    }
}

/// A track with the subject centred in every frame (no detection needed).
enum SubtitleTrackless {
    static func centred(_ n: Int) -> SubjectTrack {
        SubjectTrack(samples: Array(repeating: .init(center: SIMD2(0.5, 0.5), size: SIMD2(0.2, 0.2), source: .face), count: n))
    }
}

private func bgra(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    return (0..<h).flatMap { y in Array(UnsafeBufferPointer(start: base + y * row, count: w * 4)) }
}

private func texture(_ t: MTLTexture) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: t.width * t.height * 4)
    t.getBytes(&bytes, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
    return bytes
}
