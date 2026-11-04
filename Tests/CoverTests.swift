import AutoGradeCore
import AVFoundation
import Metal
import XCTest

/// Cover frames (CLAUDE.md 封面): the scan and scores against make_fixtures.py,
/// the pick on a clip with known good and bad stretches, framing, and the
/// written file being the pixels of the export's frame.
final class CoverTests: XCTestCase {
    var engine: AutoGrader!
    var dir: URL!
    let clip = Fixtures.url("synthetic_cover.mp4")
    let cover = Fixtures.manifest.cover

    override func setUpWithError() throws {
        engine = try AutoGrader(stylesDirectory: nil)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("autograde-cover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)   // this test's own temporary directory
    }

    private var shots: [Shot] { cover.shots.map { Shot(first: $0[0], last: $0[1]) } }

    private func analyze(_ url: URL) throws -> Analysis {
        try engine.analyze(url, lutSize: 33, cutThreshold: Fixtures.manifest.cut_threshold)
    }

    /// The scan without Vision (an empty track), so the features alone are compared.
    private func scan() throws -> (Analysis, CoverScan) {
        let a = try analyze(clip)
        let none = SubjectTrack(samples: Array(repeating: nil, count: a.frameCount))
        return (a, try engine.coverScan(clip, analysis: a, track: none))
    }

    private func faces(_ n: Int) -> [SubjectTrack.Sample?] {
        var out = [SubjectTrack.Sample?](repeating: nil, count: n)
        for f in cover.faces {
            out[Int(f[0])] = .init(center: SIMD2(Float(f[1]), Float(f[2])), size: SIMD2(Float(f[3]), Float(f[4])), source: .face)
        }
        return out
    }

    // MARK: parity with make_fixtures.py

    func testResizeMatchesPyTorch() throws {
        let reader = try VideoReader(url: clip, device: engine.metal.device)
        let frame = try XCTUnwrap(try reader.next())
        let (w, h, y) = Cover.luma(frame.pixelBuffer)
        XCTAssertEqual([w, h], [320, 180], "180 high: not resized for analysis")
        let (tw, th) = (cover.resize[0], cover.resize[1])
        let out = Cover.resize(width: w, height: h, toWidth: tw, toHeight: th) { x, yy in y[yy * w + x] }
        let ref = try Fixtures.floats("cover_resized")
        XCTAssertEqual(ref.shape, [th, tw])
        let err = maxAbsDifference(out.map(Float.init), ref.values)
        print("cover resize vs PyTorch: max \(err)")
        XCTAssertLessThanOrEqual(err, 1e-5)
        XCTAssertEqual(Cover.analysisSize(width: 1920, height: 1080).width, 640)
        XCTAssertEqual(Cover.analysisSize(width: 607, height: 1080).width, 202)   // 202.33
        XCTAssertEqual(Cover.analysisSize(width: 1080, height: 1920).width, 203)  // 202.5 rounds up
    }

    func testFeaturesMatchNumpy() throws {
        let (a, s) = try scan()
        let ref = try Fixtures.floats("cover_features")
        XCTAssertEqual(ref.shape, [a.frameCount, 6])
        let f = s.features
        var worst = 0.0
        for i in 0..<a.frameCount {
            let mine = [f.sharpness[i], f.hi[i], f.lo[i], f.mean[i], f.diffPrevious[i], f.diffNext[i]]
            for c in 0..<6 {
                let r = Double(ref.values[i * 6 + c])
                // relative 1e-5, with a floor for values near zero (the fixture is float32)
                let rel = abs(mine[c] - r) / max(abs(r), 1e-4)
                worst = max(worst, rel)
            }
        }
        print("cover features vs numpy: worst relative \(worst)")
        XCTAssertLessThanOrEqual(worst, 1e-5)
    }

    func testScoresMatchNumpy() throws {
        let (a, s) = try scan()
        let ref = try Fixtures.floats("cover_scores")
        let n = a.frameCount
        XCTAssertEqual(ref.shape, [3, n])
        let with = Cover.scores(s.features, faces: faces(n), shots: shots, frameTimes: a.frameTimes)
        let without = Cover.scores(s.features, faces: Array(repeating: nil, count: n), shots: shots, frameTimes: a.frameTimes)
        for (row, values) in [(0, with.pick), (1, with.rank), (2, without.pick)] {
            let err = maxAbsDifference(values.map(Float.init), Array(ref.values[(row * n)..<((row + 1) * n)]))
            print("cover scores row \(row) vs numpy: max \(err)")
            XCTAssertLessThanOrEqual(err, 1e-5, "row \(row)")
        }
    }

    // MARK: the pick

    func testPicksTheExpectedFrames() throws {
        let (a, s) = try scan()
        let n = a.frameCount
        let with = Cover.candidates(Cover.scores(s.features, faces: faces(n), shots: shots, frameTimes: a.frameTimes),
                                    shots: shots, frameTimes: a.frameTimes)
        XCTAssertEqual(with.map(\.frame), cover.best)
        let without = Cover.candidates(Cover.scores(s.features, faces: Array(repeating: nil, count: n), shots: shots,
                                                    frameTimes: a.frameTimes), shots: shots, frameTimes: a.frameTimes)
        XCTAssertEqual(without.map(\.frame), cover.best_without_faces)
        // the gym shot picks a sharp frame, not the blurred or overexposed stretch; the comic its still part
        let gym = try XCTUnwrap(without.first { $0.shot == 0 }), comic = try XCTUnwrap(without.first { $0.shot == 1 })
        XCTAssertTrue((20...39).contains(gym.frame), "gym pick \(gym.frame)")
        XCTAssertTrue((75...104).contains(comic.frame), "comic pick \(comic.frame)")
        // the 0.5 s pan does not compete
        XCTAssertFalse(without.contains { $0.shot == 2 })
        // the face frames win their shot when faces are given
        XCTAssertTrue((25...35).contains(try XCTUnwrap(with.first { $0.shot == 0 }).frame))
    }

    func testTransitionWindowAndShortShots() {
        // 60 frames at 30 fps, flat features: the score only varies by the transition factor
        let n = 60, times = (0..<n).map { CMTime(value: CMTimeValue($0), timescale: 30) }
        var f = CoverFeatures()
        f.sharpness = Array(repeating: 1, count: n); f.hi = Array(repeating: 0, count: n)
        f.lo = Array(repeating: 0, count: n); f.mean = Array(repeating: 0.45, count: n)
        f.diffPrevious = Array(repeating: 0, count: n); f.diffNext = Array(repeating: 0, count: n)
        let s = Cover.scores(f, faces: Array(repeating: nil, count: n), shots: [Shot(first: 0, last: 59)], frameTimes: times)
        let full = 0.4 + 0.3 + 0.1
        XCTAssertEqual(s.pick[0], full * 0.5, accuracy: 1e-12)          // at the cut
        XCTAssertEqual(s.pick[3], full * 0.75, accuracy: 1e-9)          // half way through the 0.2 s window
        XCTAssertEqual(s.pick[6], full, accuracy: 1e-12)                // window end
        XCTAssertEqual(s.pick[59], full * 0.5, accuracy: 1e-12)
        // two 0.5 s shots: neither is long enough, so both compete
        let two = [Shot(first: 0, last: 14), Shot(first: 15, last: 29)]
        let t30 = Array(times[0..<30])
        var g = CoverFeatures()
        g.sharpness = Array(f.sharpness[0..<30]); g.hi = Array(f.hi[0..<30]); g.lo = Array(f.lo[0..<30])
        g.mean = Array(f.mean[0..<30]); g.diffPrevious = Array(f.diffPrevious[0..<30]); g.diffNext = Array(f.diffNext[0..<30])
        let c = Cover.candidates(Cover.scores(g, faces: Array(repeating: nil, count: 30), shots: two, frameTimes: t30),
                                 shots: two, frameTimes: t30)
        XCTAssertEqual(Set(c.map(\.shot)), [0, 1])
    }

    // MARK: framing and naming

    func testCropSlidesAlongOneAxisInsideTheFrame() {
        var c = Cover.crop(center: SIMD2(0.9, 0.5), aspect: .portrait3x4, width: 320, height: 180)
        XCTAssertEqual(c.length, SIMD2(135, 180))
        XCTAssertEqual(c.origin, SIMD2(185, 0))                          // 0.9·320 − 67.5 = 220.5, held at 320 − 135
        c = Cover.crop(center: SIMD2(0.5, 0.5), aspect: .portrait3x4, width: 320, height: 180)
        XCTAssertEqual(c.origin, SIMD2(92.5, 0))
        c = Cover.crop(center: SIMD2(0.2, 0.2), aspect: .landscape16x9, width: 320, height: 180)
        XCTAssertEqual(c.length, SIMD2(320, 180))                        // the whole frame: nothing to slide
        XCTAssertEqual(c.origin, SIMD2(0, 0))
        c = Cover.crop(center: SIMD2(0.5, 0.1), aspect: .landscape4x3, width: 1080, height: 1920)
        XCTAssertEqual(c.length, SIMD2(1080, 810))                       // a vertical clip slides vertically
        XCTAssertEqual(c.origin, SIMD2(0, 0))
        c = Cover.crop(center: SIMD2(0.3, 0.3), aspect: .original, width: 320, height: 180)
        XCTAssertEqual(c.length, SIMD2(320, 180))
        XCTAssertEqual(c.origin, SIMD2(0, 0))
    }

    func testCentreFallsBackToTheShotMedianThenTheMiddle() {
        let s = SubjectTrack.Sample(center: SIMD2(0.2, 0.3), size: SIMD2(0.1, 0.1), source: .human)
        let t = SubjectTrack(samples: [nil, s, .init(center: SIMD2(0.4, 0.5), size: SIMD2(0.1, 0.1), source: .saliency),
                                       .init(center: SIMD2(0.9, 0.9), size: SIMD2(0.1, 0.1), source: .saliency), nil])
        XCTAssertEqual(Cover.center(frame: 1, track: t, shot: Shot(first: 0, last: 3)), SIMD2(0.2, 0.3))
        XCTAssertEqual(Cover.center(frame: 0, track: t, shot: Shot(first: 0, last: 3)), SIMD2(0.4, 0.5))
        XCTAssertEqual(Cover.center(frame: 4, track: t, shot: Shot(first: 4, last: 4)), SIMD2(0.5, 0.5))
    }

    func testFileName() {
        XCTAssertEqual(Cover.fileName(prefix: "gym_1080p", rank: 1, shot: 1, frame: 87, aspect: .portrait3x4, format: .png),
                       "gym_1080p_cover1_shot01_f0087_3x4.png")
        XCTAssertEqual(Cover.fileName(prefix: "a", rank: 2, shot: 10, frame: 12345, aspect: .original, format: .jpeg),
                       "a_cover2_shot10_f12345_orig.jpg")
    }

    // MARK: pixels and files

    /// `original` is the preview's graded bytes, which are the export's (原则 5).
    func testOriginalCoverIsThePreviewFrame() throws {
        let a = try analyze(clip)
        let targets = try PreviewTargets(kernels: engine.kernels, width: a.info.width, height: a.info.height)
        let covers = try CoverTargets(kernels: engine.kernels, sourceWidth: a.info.width, sourceHeight: a.info.height,
                                      aspect: .original)
        for i in [30, 90] {
            let frame = try engine.decodeFrame(clip, analysis: a, index: i)
            let lut = a.luts[a.shotIndex(forFrame: i)]
            try engine.preview(frame, lut: lut, into: targets)
            let bytes = try engine.renderCover(EnhancedFrame(frame), lut: lut, aspect: .original,
                                               center: SIMD2(0.5, 0.5), into: covers)
            XCTAssertTrue(bytes == texture(targets.graded), "frame \(i)")
        }
    }

    /// With a background effect, the cover is the frame ExportCheck rebuilds for the export.
    func testCoverKeepsTheEnhancements() throws {
        let url = Fixtures.url("synthetic_person.mp4")
        let a = try analyze(url)
        let settings = EnhanceSettings(background: .green)
        let enhancer = try Enhancer(settings: settings, width: a.info.width, height: a.info.height, kernels: engine.kernels)
        let targets = try PreviewTargets(kernels: engine.kernels, width: a.info.width, height: a.info.height)
        let covers = try CoverTargets(kernels: engine.kernels, sourceWidth: a.info.width, sourceHeight: a.info.height,
                                      aspect: .original)
        let frame = try engine.decodeFrame(url, analysis: a, index: 5, enhancer: enhancer, exact: true)
        try engine.preview(frame, lut: a.luts[0], into: targets)
        let bytes = try engine.renderCover(frame, lut: a.luts[0], aspect: .original, center: SIMD2(0.5, 0.5), into: covers)
        XCTAssertTrue(bytes == texture(targets.graded))
        let plain = try engine.renderCover(EnhancedFrame(try engine.decodeFrame(url, analysis: a, index: 5)), lut: a.luts[0],
                                           aspect: .original, center: SIMD2(0.5, 0.5), into: covers)
        XCTAssertFalse(bytes == plain, "the green background changed the cover")
    }

    /// The crop branch: a 16:9 cover of a 16:9 clip is the reframed preview at 16:9
    /// (the same 1920x1080 size, the whole frame as the crop) byte for byte.
    func testCroppedCoverIsTheReframedPreview() throws {
        let a = try analyze(clip)
        let (w, h) = (a.info.width, a.info.height)
        let path = Reframe.path(track: SubjectTrack(samples: Array(repeating: nil, count: a.frameCount)), shots: a.shots,
                                frameTimes: a.frameTimes, width: w, height: h, aspect: .horizontal16x9,
                                overrides: Array(repeating: nil, count: a.shots.count))
        let reframed = try ReframeTargets(kernels: engine.kernels, sourceWidth: w, sourceHeight: h, aspect: .horizontal16x9)
        let covers = try CoverTargets(kernels: engine.kernels, sourceWidth: w, sourceHeight: h, aspect: .landscape16x9)
        let frame = try engine.decodeFrame(clip, analysis: a, index: 90)
        let lut = a.luts[a.shotIndex(forFrame: 90)]
        try engine.previewReframed(frame, lut: lut, path: path, into: reframed)
        let bytes = try engine.renderCover(EnhancedFrame(frame), lut: lut, aspect: .landscape16x9, center: SIMD2(0.3, 0.5),
                                           into: covers)
        XCTAssertEqual(bytes.count, 1920 * 1080 * 4)
        XCTAssertTrue(bytes == texture(reframed.output))
        // and a 3:4 crop really slides with the centre
        let tall = try CoverTargets(kernels: engine.kernels, sourceWidth: w, sourceHeight: h, aspect: .portrait3x4)
        let left = try engine.renderCover(EnhancedFrame(frame), lut: lut, aspect: .portrait3x4, center: SIMD2(0, 0.5), into: tall)
        let right = try engine.renderCover(EnhancedFrame(frame), lut: lut, aspect: .portrait3x4, center: SIMD2(1, 0.5), into: tall)
        XCTAssertEqual(left.count, 1080 * 1440 * 4)
        XCTAssertFalse(left == right)
    }

    func testPNGIsExactAndTaggedSRGB() throws {
        let (w, h) = (64, 40)
        var bgra = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { bgra[i * 4] = UInt8(i % 256); bgra[i * 4 + 1] = UInt8((i / 7) % 256); bgra[i * 4 + 2] = UInt8((i * 3) % 256) }
        let url = dir.appendingPathComponent("c.png")
        let check = try CoverWriter.write(bgra: bgra, width: w, height: h, to: url, format: .png)
        XCTAssertTrue(check.passed, "\(check.failures)")
        XCTAssertEqual(check.maxAbs, 0)
        XCTAssertEqual(CoverWriter.readRGB(url)?.colourSpace, CGColorSpace.sRGB as String)
        XCTAssertThrowsError(try CoverWriter.write(bgra: bgra, width: w, height: h, to: url, format: .png))
        XCTAssertNoThrow(try CoverWriter.write(bgra: bgra, width: w, height: h, to: url, format: .png, overwrite: true))
    }

    /// A real frame as JPEG: within the mean tolerance (CLAUDE.md 容差表).
    func testJPEGWithinTolerance() throws {
        let a = try analyze(clip)
        let covers = try CoverTargets(kernels: engine.kernels, sourceWidth: a.info.width, sourceHeight: a.info.height,
                                      aspect: .original)
        let bytes = try engine.renderCover(EnhancedFrame(try engine.decodeFrame(clip, analysis: a, index: 90)), lut: a.luts[1],
                                           aspect: .original, center: SIMD2(0.5, 0.5), into: covers)
        let check = try CoverWriter.write(bgra: bytes, width: a.info.width, height: a.info.height,
                                          to: dir.appendingPathComponent("c.jpg"), format: .jpeg)
        print(String(format: "cover JPEG q%.2f: mean %.3f, max %d levels", Cover.jpegQuality, check.meanAbs, check.maxAbs))
        XCTAssertTrue(check.passed, "\(check.failures)")
    }

    /// The check fails on a file that is not what was written.
    func testCheckCatchesAWrongFile() throws {
        let (w, h) = (16, 16)
        let bgra = [UInt8](repeating: 100, count: w * h * 4)
        let url = dir.appendingPathComponent("w.png")
        _ = try CoverWriter.write(bgra: bgra, width: w, height: h, to: url, format: .png)
        var other = bgra
        other[0] = 101
        let bad = try CoverWriter.write(bgra: other, width: w, height: h, to: dir.appendingPathComponent("x.png"), format: .png)
        XCTAssertTrue(bad.passed)
        // compare the first file against `other`: one level off in one sample
        let report = CoverWriter.recheck(url, bgra: other, width: w, height: h, format: .png)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.maxAbs, 1)
    }
}

private func texture(_ t: MTLTexture) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: t.width * t.height * 4)
    t.getBytes(&out, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
    return out
}
