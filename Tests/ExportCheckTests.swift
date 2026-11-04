import AutoGradeCore
import AVFoundation
import XCTest

/// The check after every export (CLAUDE.md 导出) passes a good file and names
/// what is wrong with a bad one.
final class ExportCheckTests: XCTestCase {
    var engine: AutoGrader!
    var dir: URL!
    let synthetic = Fixtures.url("synthetic_shots.mp4")
    let av = Fixtures.url("synthetic_av.mp4")

    override func setUpWithError() throws {
        engine = try AutoGrader(stylesDirectory: nil)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("autograde-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)   // this test's own temporary directory
    }

    private func analyze(_ url: URL) throws -> Analysis {
        try engine.analyze(url, lutSize: 33, cutThreshold: Fixtures.manifest.cut_threshold)
    }

    private func render(_ source: URL, _ a: Analysis, luts: [LUT3D]? = nil, codec: OutputCodec = .hevc,
                        audio: Bool = true) throws -> (URL, RenderResult) {
        let out = dir.appendingPathComponent("\(UUID().uuidString).mov")
        return (out, try engine.render(source, analysis: a, luts: luts ?? a.luts, to: out, codec: codec, audio: audio))
    }

    /// 29.97 fps with a 1/30000 time scale, as DJI and GoPro write it: the export
    /// keeps every frame at the source's time and passes the check (2026-11-04:
    /// the writer's default time scale 600 rounded 1001/30000 s and the check failed).
    func testNTSCFrameTimesSurviveTheExport() throws {
        let ntsc = Fixtures.url("synthetic_ntsc.mp4")
        let a = try analyze(ntsc)
        XCTAssertEqual(a.frameCount, 30)
        XCTAssertEqual(a.frameTimes[1], CMTime(value: 1001, timescale: 30000))
        XCTAssertEqual(a.info.timeScale, 30000)
        for codec in OutputCodec.allCases {
            let (out, result) = try render(ntsc, a, codec: codec)
            let report = try engine.checkExport(out, source: ntsc, analysis: a, luts: a.luts, render: result)
            log("ntsc \(codec)", report)
            XCTAssertTrue(report.passed, "\(codec): \(report.failures)")
            let reader = try VideoReader(url: out, device: engine.metal.device, checkingFormat: false)
            var times: [CMTime] = []
            while let f = try reader.next() { times.append(f.presentationTime) }
            XCTAssertEqual(times, a.frameTimes, "\(codec): frames moved off the source's times")
        }
    }

    private func log(_ name: String, _ r: ExportReport) {
        for f in r.frames {
            print(String(format: "%@ shot %d frame %d: mean %.2f, bias %+.2f %+.2f %+.2f", name, f.shot, f.frame,
                         f.meanAbs, f.bias[0], f.bias[1], f.bias[2]))
        }
        print("\(name): \(r.passed ? "passed" : "failed \(r.failures)") in \(r.seconds) s")
    }

    func testGoodExportsPass() throws {
        for codec in OutputCodec.allCases {
            let a = try analyze(synthetic)
            let (out, result) = try render(synthetic, a, codec: codec)
            let report = try engine.checkExport(out, source: synthetic, analysis: a, luts: a.luts, render: result)
            log("good \(codec)", report)
            XCTAssertTrue(report.passed, "\(codec): \(report.failures)")
            XCTAssertEqual(report.videoSamples, 90)
            XCTAssertEqual(report.frames.map(\.frame), [14, 44, 74], "each shot's middle frame")
            XCTAssertNil(report.audioPackets)
        }
        let a = try analyze(av)
        let (out, result) = try render(av, a)
        let report = try engine.checkExport(out, source: av, analysis: a, luts: a.luts, render: result)
        log("good av", report)
        XCTAssertTrue(report.passed, "\(report.failures)")
        XCTAssertEqual(report.audioPackets, 470)
        XCTAssertLessThanOrEqual(report.audioMaxDiff ?? .infinity, ExportCheck.maxAudioDiff, "decoded audio is the source's")
        XCTAssertEqual(report.audioFrames?.export, report.audioFrames?.source)
        XCTAssertGreaterThan(report.audioFrames?.source ?? 0, 479_000, "10 s at 48 kHz, not trimmed to the 3 s video")
    }

    func testWrongLUTInOneShotIsNamed() throws {
        let a = try analyze(synthetic)
        var wrong = a.luts
        wrong[1] = try engine.kernels.blend(a.luts[1], strength: 0)    // shot 2 left ungraded
        let (out, result) = try render(synthetic, a, luts: wrong)
        let report = try engine.checkExport(out, source: synthetic, analysis: a, luts: a.luts, render: result)
        log("wrong lut", report)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.failures.count, 1, "\(report.failures)")
        XCTAssertTrue(report.failures[0].hasPrefix("shot 2 (frame 44) does not match its grade"), report.failures[0])
    }

    func testOtherVideosAnalysisFailsOnTimestamps() throws {
        let a = try analyze(synthetic), vfr = try analyze(Fixtures.url("synthetic_vfr.mp4"))
        let (out, result) = try render(synthetic, a)
        let report = try engine.checkExport(out, source: synthetic, analysis: vfr, luts: vfr.luts, render: result)
        log("wrong analysis", report)
        XCTAssertTrue(report.failures.contains { $0.hasPrefix("video timestamps: 90 frames, the analysis has \(vfr.frameCount)") },
                      "\(report.failures)")
        XCTAssertTrue(report.frames.isEmpty, "no frames compared once timestamps differ")
    }

    func testSameFrameCountButDifferentTimestampsFails() throws {
        // 90 frames like the export, but at 25 fps instead of 30: counting alone would pass.
        let retimed = dir.appendingPathComponent("retimed.mov")
        let writer = try VideoWriter(url: retimed, width: 320, height: 180, codec: .hevc, device: engine.metal.device)
        for i in 0..<90 {
            let (pixels, _, _) = try writer.makeFrame()
            try writer.append(pixels, at: CMTime(value: CMTimeValue(i), timescale: 25))
        }
        try writer.finish()
        let other = try engine.analyze(retimed, lutSize: 33, cutThreshold: 3)
        XCTAssertEqual(other.frameCount, 90)

        let a = try analyze(synthetic)
        let (out, result) = try render(synthetic, a)
        let report = try engine.checkExport(out, source: synthetic, analysis: other, luts: other.luts, render: result)
        log("same count", report)
        XCTAssertTrue(report.failures.contains("video timestamps: 90 frames, the analysis has 90; first difference at frame 1"),
                      "\(report.failures)")
    }

    func testDifferentAudioIsCaught() throws {
        // Same video bytes, 880 Hz instead of 440 Hz: only the audio comparison can tell.
        let a = try analyze(av)
        let (out, result) = try render(av, a)
        let other = Fixtures.url("synthetic_av_880.mp4")
        let report = try engine.checkExport(out, source: other, analysis: a, luts: a.luts, render: result)
        log("other audio", report)
        XCTAssertEqual(report.failures.count, 1, "\(report.failures)")
        XCTAssertTrue(report.failures.first?.hasPrefix("audio differs from the source") == true, "\(report.failures)")
    }

    func testAudioPresenceMustMatchWhatWasCopied() throws {
        let a = try analyze(av)
        let (with, copied) = try render(av, a, audio: true)
        let (without, none) = try render(av, a, audio: false)
        let missing = try engine.checkExport(without, source: av, analysis: a, luts: a.luts, render: copied)
        XCTAssertEqual(missing.failures, ["no audio track, but 470 packets were copied"])
        let extra = try engine.checkExport(with, source: av, analysis: a, luts: a.luts, render: none)
        XCTAssertEqual(extra.failures, ["an audio track is present, but none was copied"])
    }
}
