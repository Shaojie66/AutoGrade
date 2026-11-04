import AutoGradeCore
import AVFoundation
import Metal
import XCTest

/// Reframed export: the "成片" preview is the export's bytes, the file is the
/// platform size, and the check catches a crop that is not the one asked for
/// (CLAUDE.md 重构图).
final class ReframeRenderTests: XCTestCase {
    var engine: AutoGrader!
    var dir: URL!
    let subject = Fixtures.url("synthetic_subject.mp4")

    override func setUpWithError() throws {
        engine = try AutoGrader(stylesDirectory: nil)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("autograde-reframe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)   // this test's own temporary directory
    }

    /// The subject clip cut in two at frame 45, so the path has two shots.
    private func setup() throws -> (Analysis, CropPath) {
        let whole = try engine.analyze(subject, lutSize: 17, cutThreshold: 3)
        let a = try engine.addCut(whole, source: subject, atFrame: 45)
        let track = try engine.detectSubjects(subject, analysis: a)
        let path = Reframe.path(track: track, shots: a.shots, frameTimes: a.frameTimes, width: 320, height: 180,
                                aspect: .vertical9x16, overrides: [nil, nil])
        return (a, path)
    }

    func testReframedPreviewIsByteIdenticalToExport() throws {
        let (a, path) = try setup()
        let probe: Set = [0, 44, 45, 89]
        var exported: [Int: [UInt8]] = [:]
        let out = dir.appendingPathComponent("r.mov")
        let result = try engine.render(subject, analysis: a, luts: a.luts, to: out, reframe: path,
                                       frameHook: { i, pb in if probe.contains(i) { exported[i] = bgra(pb) } })
        XCTAssertNotNil(result.reframe)
        let targets = try ReframeTargets(kernels: engine.kernels, sourceWidth: 320, sourceHeight: 180, aspect: .vertical9x16)
        for i in probe.sorted() {
            try engine.previewReframed(try engine.decodeFrame(subject, analysis: a, index: i),
                                       lut: a.luts[a.shotIndex(forFrame: i)], path: path, into: targets)
            var bytes = [UInt8](repeating: 0, count: 1080 * 1920 * 4)
            targets.output.getBytes(&bytes, bytesPerRow: 1080 * 4, from: MTLRegionMake2D(0, 0, 1080, 1920), mipmapLevel: 0)
            XCTAssertEqual(bytes.count, exported[i]?.count)
            XCTAssertTrue(bytes == exported[i], "frame \(i): 成片 preview differs from the export")
        }
    }

    func testReframedExportIsPlatformSizeAndPassesTheCheck() throws {
        let (a, path) = try setup()
        print("reframe test path: modes \(path.modes), centres \(path.centers.first!)...\(path.centers.last!)")
        let out = dir.appendingPathComponent("r.mov")
        let result = try engine.render(subject, analysis: a, luts: a.luts, to: out, reframe: path)
        let report = try engine.checkExport(out, source: subject, analysis: a, luts: a.luts, render: result)
        for f in report.frames { print(String(format: "reframed shot %d frame %d: mean %.2f", f.shot, f.frame, f.meanAbs)) }
        XCTAssertTrue(report.passed, "\(report.failures)")
        let check = try VideoReader(url: out, device: engine.metal.device, checkingFormat: false)
        XCTAssertEqual(check.info.width, 1080)
        XCTAssertEqual(check.info.height, 1920)
    }

    func testCheckCatchesTheWrongCrop() throws {
        let (a, path) = try setup()
        let out = dir.appendingPathComponent("r.mov")
        let result = try engine.render(subject, analysis: a, luts: a.luts, to: out, reframe: path)
        // claim shot 2 was cropped at the far left instead
        let track = try engine.detectSubjects(subject, analysis: a)
        let other = Reframe.path(track: track, shots: a.shots, frameTimes: a.frameTimes, width: 320, height: 180,
                                 aspect: .vertical9x16, overrides: [nil, 0])
        let claimed = RenderResult(times: result.times, codec: result.codec, audioPackets: result.audioPackets,
                                   warnings: result.warnings, reframe: other)
        let report = try engine.checkExport(out, source: subject, analysis: a, luts: a.luts, render: claimed)
        for f in report.frames { print(String(format: "wrong crop shot %d frame %d: mean %.2f", f.shot, f.frame, f.meanAbs)) }
        XCTAssertEqual(report.failures.count, 1, "\(report.failures)")
        XCTAssertTrue(report.failures.first?.hasPrefix("shot 2 (frame 67) does not match its grade") == true, "\(report.failures)")
    }
}

private func bgra(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    return (0..<h).flatMap { y in Array(UnsafeBufferPointer(start: base + y * row, count: w * 4)) }
}
