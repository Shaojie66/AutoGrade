import AutoGradeCore
import AVFoundation
import Metal
import XCTest

/// Enhancements in the render: the preview is the export's bytes (windows in
/// the shot, CLAUDE.md 原则 5), noise reduction really reduces noise, and the
/// export check catches an enhancement that was not applied (CLAUDE.md 画质增强).
final class EnhanceRenderTests: XCTestCase {
    var engine: AutoGrader!
    var dir: URL!
    let person = Fixtures.url("synthetic_person.mp4")
    let noisy = Fixtures.url("synthetic_noisy.mp4")
    let clean = Fixtures.url("synthetic_clean.mp4")
    /// Both ends of both shots and the frames next to them, and the middle.
    let probe: Set = [0, 1, 5, 10, 11, 12, 13, 22, 23]

    override func setUpWithError() throws {
        engine = try AutoGrader(stylesDirectory: nil)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("autograde-enhance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)   // this test's own temporary directory
    }

    private func analyze(_ url: URL) throws -> Analysis {
        try engine.analyze(url, lutSize: 33, cutThreshold: Fixtures.manifest.cut_threshold)
    }

    /// Render with `settings`, then preview every probed frame through a fresh
    /// enhancer; returns the exported bytes of the probed frames.
    /// `exact`: frames as ExportCheck prepares them (a denoise chain from the shot's start).
    @discardableResult
    private func assertPreviewMatchesExport(_ url: URL, _ settings: EnhanceSettings, probe: Set<Int>, exact: Bool = false,
                                            file: StaticString = #filePath, line: UInt = #line) throws -> [Int: [UInt8]] {
        let a = try analyze(url)
        var exported: [Int: [UInt8]] = [:]
        _ = try engine.render(url, analysis: a, luts: a.luts, to: dir.appendingPathComponent("\(UUID()).mov"), enhance: settings,
                              frameHook: { i, pb in if probe.contains(i) { exported[i] = bgra(pb) } })
        let enhancer = try Enhancer(settings: settings, width: a.info.width, height: a.info.height, kernels: engine.kernels)
        let targets = try PreviewTargets(kernels: engine.kernels, width: a.info.width, height: a.info.height)
        for i in probe.sorted() {
            let frame = try engine.decodeFrame(url, analysis: a, index: i, enhancer: enhancer, exact: exact)
            try engine.preview(frame, lut: a.luts[a.shotIndex(forFrame: i)], into: targets)
            XCTAssertTrue(texture(targets.graded) == exported[i], "frame \(i): preview differs from the export", file: file, line: line)
        }
        return exported
    }

    func testPersonClipHasTheCut() throws {
        XCTAssertEqual(try analyze(person).shots, [Shot(first: 0, last: 11), Shot(first: 12, last: 23)])
    }

    func testBackgroundPreviewIsByteIdenticalToExport() throws {
        for effect in [BackgroundEffect.blur(strength: 0.6), .green] {
            let exported = try assertPreviewMatchesExport(person, EnhanceSettings(background: effect), probe: probe)
            // the background really changed: frame 5 differs from a plain grade
            let a = try analyze(person)
            let plain = try PreviewTargets(kernels: engine.kernels, width: 320, height: 180)
            try engine.preview(try engine.decodeFrame(person, analysis: a, index: 5), lut: a.luts[0], into: plain)
            XCTAssertNotEqual(texture(plain.graded), exported[5], "\(effect)")
        }
    }

    /// The mask is the average of frames i-2 ... i+2, cut off at the shot's ends
    /// (CLAUDE.md 背景): built here by hand from single-frame masks.
    func testMaskIsTheAverageOfItsWindowInTheShot() throws {
        let a = try analyze(person)
        let settings = EnhanceSettings(background: .green)
        let enhancer = try Enhancer(settings: settings, width: 320, height: 180, kernels: engine.kernels)
        let scratch = try BackgroundScratch(effect: .green, width: 320, height: 180, device: engine.metal.device)
        let targets = try PreviewTargets(kernels: engine.kernels, width: 320, height: 180)
        let manual = try PreviewTargets(kernels: engine.kernels, width: 320, height: 180)
        let planes = (try engine.kernels.makeImage(width: 320, height: 180), try engine.kernels.makeImage(width: 320, height: 180))
        for (i, window) in [(5, 3...7), (1, 0...3), (11, 9...11), (12, 12...14)] {
            let masks = try window.map { try PersonSegmentation.mask(try engine.decodeFrame(person, analysis: a, index: $0).pixelBuffer) }
            let mask = try PersonSegmentation.combine(masks, frameWidth: 320, frameHeight: 180, kernels: engine.kernels)
            let frame = try engine.decodeFrame(person, analysis: a, index: i)
            let lut = a.luts[a.shotIndex(forFrame: i)]
            try engine.metal.run { enc in
                try engine.kernels.encodeGradeFrame(into: enc, luma: frame.luma, chroma: frame.chroma, fullRange: frame.fullRange, lut: lut, scratch: planes,
                                                    graded: manual.graded, original: nil, background: (mask, scratch))
            }
            try engine.preview(try engine.decodeFrame(person, analysis: a, index: i, enhancer: enhancer), lut: lut, into: targets)
            XCTAssertTrue(texture(targets.graded) == texture(manual.graded), "frame \(i): mask is not the average of \(window)")
        }
    }

    func testShotsWithoutPeopleAreLeftAlone() throws {
        let a = try analyze(person)
        let people = PersonSegmentation.shotsWithPeople(coverage: try engine.personCoverage(person, analysis: a), shots: a.shots)
        XCTAssertEqual(people, [true, false], "the face shot has someone, the comic crop no one")
        let exported = try assertPreviewMatchesExport(person, EnhanceSettings(background: .green, backgroundShots: people), probe: [5, 12, 20])
        let plain = try PreviewTargets(kernels: engine.kernels, width: 320, height: 180)
        for i in [5, 12, 20] {
            try engine.preview(try engine.decodeFrame(person, analysis: a, index: i), lut: a.luts[a.shotIndex(forFrame: i)], into: plain)
            if i < 12 { XCTAssertNotEqual(texture(plain.graded), exported[i], "frame \(i)") }
            else { XCTAssertEqual(texture(plain.graded), exported[i], "frame \(i): no one in this shot, nothing replaced") }
        }
    }

    func testBackgroundReframedPreviewIsByteIdenticalToExport() throws {
        let a = try analyze(person)
        let settings = EnhanceSettings(background: .green)
        let path = Reframe.path(track: SubtitleTrackless.centred(a.frameCount), shots: a.shots, frameTimes: a.frameTimes,
                                width: 320, height: 180, aspect: .vertical9x16, overrides: Array(repeating: nil, count: a.shots.count))
        var exported: [Int: [UInt8]] = [:]
        _ = try engine.render(person, analysis: a, luts: a.luts, to: dir.appendingPathComponent("r.mov"), reframe: path,
                              enhance: settings, frameHook: { i, pb in if i == 5 || i == 12 { exported[i] = bgra(pb) } })
        let enhancer = try Enhancer(settings: settings, width: 320, height: 180, kernels: engine.kernels)
        let targets = try ReframeTargets(kernels: engine.kernels, sourceWidth: 320, sourceHeight: 180, aspect: .vertical9x16)
        for i in [5, 12] {
            try engine.previewReframed(try engine.decodeFrame(person, analysis: a, index: i, enhancer: enhancer),
                                       lut: a.luts[a.shotIndex(forFrame: i)], path: path, into: targets)
            XCTAssertTrue(texture(targets.output) == exported[i], "frame \(i): 成片 preview differs from the export")
        }
    }

    /// What ExportCheck compares against is the export's bytes (CLAUDE.md 降噪: chain from the shot's start).
    func testDenoisedExactFrameIsByteIdenticalToExport() throws {
        guard EnhanceSettings.denoiseAvailable else { throw XCTSkip("noise reduction needs macOS 26") }
        try assertPreviewMatchesExport(noisy, EnhanceSettings(denoise: 0.5), probe: [0, 1, 9, 18, 19], exact: true)
        try assertPreviewMatchesExport(person, EnhanceSettings(denoise: 1, background: .blur(strength: 1)), probe: probe, exact: true)
    }

    /// The preview's chain starts 8 frames back: equal to the export in a shot's
    /// first 9 frames, close after (CLAUDE.md 原则 5 的例外, 容差表).
    func testDenoisedPreviewIsCloseToExport() throws {
        guard EnhanceSettings.denoiseAvailable else { throw XCTSkip("noise reduction needs macOS 26") }
        for (url, settings) in [(noisy, EnhanceSettings(denoise: 1)), (person, EnhanceSettings(denoise: 1, background: .green))] {
            let a = try analyze(url)
            var exported: [Int: [UInt8]] = [:]
            _ = try engine.render(url, analysis: a, luts: a.luts, to: dir.appendingPathComponent("\(UUID()).mov"), enhance: settings,
                                  frameHook: { i, pb in exported[i] = bgra(pb) })
            let enhancer = try Enhancer(settings: settings, width: 320, height: 180, kernels: engine.kernels)
            let targets = try PreviewTargets(kernels: engine.kernels, width: 320, height: 180)
            var worst = (mean: 0.0, max: 0)
            for i in 0..<a.frameCount {
                try engine.preview(try engine.decodeFrame(url, analysis: a, index: i, enhancer: enhancer),
                                   lut: a.luts[a.shotIndex(forFrame: i)], into: targets)
                let got = texture(targets.graded), want = exported[i]!
                if i - a.shots[a.shotIndex(forFrame: i)].first <= Enhancer.previewWarmUp {
                    XCTAssertTrue(got == want, "frame \(i): the chain reaches the shot's start, preview must equal the export")
                    continue
                }
                var sum = 0, top = 0
                for j in stride(from: 0, to: got.count, by: 4) {
                    for c in 0..<3 { let d = abs(Int(got[j + c]) - Int(want[j + c])); sum += d; top = max(top, d) }
                }
                let mean = Double(sum) / Double(got.count / 4 * 3)
                worst = (max(worst.mean, mean), max(worst.max, top))
                XCTAssertLessThanOrEqual(mean, 1.5, "frame \(i): denoised preview too far from the export")   // CLAUDE.md 容差表
            }
            print(String(format: "denoised preview vs export, frames past the warm-up: worst mean %.3f, worst max %d levels", worst.mean, worst.max)
                  + " (\(url.lastPathComponent))")
        }
    }

    /// A preview of a frame must not depend on what was previewed before, and
    /// previewing the same frame again must not hang (a session refuses a repeated
    /// timestamp; each preview chain gets a new one, CLAUDE.md 降噪).
    func testDenoiseDoesNotDependOnHistory() throws {
        guard EnhanceSettings.denoiseAvailable else { throw XCTSkip("noise reduction needs macOS 26") }
        let a = try analyze(noisy)
        let settings = EnhanceSettings(denoise: 0.5)
        var originals: [[UInt8]] = []
        func bytes(_ e: Enhancer, _ i: Int) throws -> [UInt8] {
            let targets = try PreviewTargets(kernels: engine.kernels, width: 320, height: 180)
            try engine.preview(try engine.decodeFrame(noisy, analysis: a, index: i, enhancer: e), lut: a.luts[0], into: targets)
            if i == 9 { originals.append(texture(targets.original)) }
            return texture(targets.graded)
        }
        func fresh() throws -> Enhancer { try Enhancer(settings: settings, width: 320, height: 180, kernels: engine.kernels) }
        let one = try fresh()
        let first = try bytes(one, 9), again = try bytes(one, 9), elsewhere = try bytes(try fresh(), 9)
        let other = try fresh()
        for i in 0..<9 { _ = try bytes(other, i) }
        let afterHistory = try bytes(other, 9)
        let plain = try bytes(try Enhancer(settings: EnhanceSettings(), width: 320, height: 180, kernels: engine.kernels), 9)
        func diff(_ x: [UInt8], _ y: [UInt8]) -> Int { zip(x, y).map { abs(Int($0) - Int($1)) }.max()! }
        print("denoise frame 9: again \(diff(first, again)), another enhancer \(diff(first, elsewhere)), after frames 0-8 \(diff(first, afterHistory)), vs unfiltered \(diff(first, plain))")
        XCTAssertGreaterThan(diff(first, plain), 0, "the filter did something")
        XCTAssertTrue(originals.allSatisfy { $0 == originals.last! }, "原片 shows the decoder's frame, not the filtered one")
        XCTAssertEqual(first, again, "the same frame again")
        XCTAssertEqual(first, elsewhere, "the same frame in another enhancer")
        XCTAssertEqual(first, afterHistory, "the same window after other frames")
    }

    /// Playback's stream: from frame 0 it is the export; from a later frame its
    /// first frame is that frame's preview, and its next shot is the export again.
    func testFrameStreamMatchesPreviewAndExport() throws {
        guard EnhanceSettings.denoiseAvailable else { throw XCTSkip("noise reduction needs macOS 26") }
        let a = try analyze(person)
        let settings = EnhanceSettings(denoise: 1, background: .blur(strength: 0.6))
        var exported: [Int: [UInt8]] = [:]
        _ = try engine.render(person, analysis: a, luts: a.luts, to: dir.appendingPathComponent("\(UUID()).mov"), enhance: settings,
                              frameHook: { i, pb in exported[i] = bgra(pb) })
        let enhancer = try Enhancer(settings: settings, width: 320, height: 180, kernels: engine.kernels)
        let targets = try PreviewTargets(kernels: engine.kernels, width: 320, height: 180)
        func grade(_ f: EnhancedFrame) throws -> [UInt8] {
            try engine.preview(f, lut: a.luts[a.shotIndex(forFrame: f.frame.index)], into: targets)
            return texture(targets.graded)
        }
        let whole = try engine.frameStream(person, analysis: a, from: 0, enhancer: enhancer)
        var n = 0
        while let f = try whole.next() {
            XCTAssertEqual(f.frame.index, n)
            XCTAssertTrue(try grade(f) == exported[n], "stream from 0, frame \(n) differs from the export")
            n += 1
        }
        XCTAssertEqual(n, a.frameCount)
        let preview = try grade(try engine.decodeFrame(person, analysis: a, index: 10, enhancer: enhancer))
        let late = try engine.frameStream(person, analysis: a, from: 10, enhancer: enhancer)
        XCTAssertTrue(try grade(try XCTUnwrap(late.next())) == preview, "the stream's first frame is that frame's preview")
        for i in 11...23 {
            let f = try XCTUnwrap(late.next())
            XCTAssertEqual(f.frame.index, i)
            if i >= 12 { XCTAssertTrue(try grade(f) == exported[i], "frame \(i): a new shot's chain starts at its first frame") }
        }
        XCTAssertNil(try late.next())
    }

    func testDenoiseReducesNoise() throws {
        guard EnhanceSettings.denoiseAvailable else { throw XCTSkip("noise reduction needs macOS 26") }
        // identity LUTs: the export is the decoded (and filtered) picture itself
        func frames(_ url: URL, _ settings: EnhanceSettings?) throws -> [[UInt8]] {
            let a = try analyze(url)
            let identity = try engine.finalLUTs(a, strengths: Array(repeating: 0, count: a.shots.count))
            var out = [[UInt8]](repeating: [], count: a.frameCount)
            _ = try engine.render(url, analysis: a, luts: identity, to: dir.appendingPathComponent("\(UUID()).mov"),
                                  enhance: settings, frameHook: { i, pb in out[i] = bgra(pb) })
            return out
        }
        let truth = try frames(clean, nil), before = try frames(noisy, nil)
        var gains: [Double] = []
        for strength: Float in [0.5, 1] {
            let after = try frames(noisy, EnhanceSettings(denoise: strength))
            let p0 = psnr(before, truth), p1 = psnr(after, truth)
            print(String(format: "denoise %.1f: PSNR vs clean %.2f -> %.2f dB (%+.2f)", strength, p0, p1, p1 - p0))
            XCTAssertGreaterThan(p1 - p0, 3, "strength \(strength)")
            gains.append(p1 - p0)
        }
        XCTAssertGreaterThan(gains[1] - gains[0], 2, "strength 1 filters clearly more than 0.5 (measured +9.05 vs +3.45 dB)")
    }

    /// The check's expected picture for a denoised export is the export's own
    /// bytes: its chain starts at the shot's first frame, not at the preview's
    /// warm-up (CLAUDE.md 降噪). synthetic_noisy is one 20-frame shot, so the
    /// sampled frame is 9, one past the warm-up: the two chains differ there.
    func testExportCheckRecomputesDenoiseExactly() throws {
        guard EnhanceSettings.denoiseAvailable else { throw XCTSkip("noise reduction needs macOS 26") }
        let a = try analyze(noisy)
        XCTAssertEqual(a.shots, [Shot(first: 0, last: 19)])
        let settings = EnhanceSettings(denoise: 1)
        var exported: [Int: [UInt8]] = [:]
        let out = dir.appendingPathComponent("\(UUID()).mov")
        let result = try engine.render(noisy, analysis: a, luts: a.luts, to: out, enhance: settings,
                                       frameHook: { i, pb in exported[i] = bgra(pb) })
        var expected: [Int: [UInt8]] = [:]
        let report = try engine.checkExport(out, source: noisy, analysis: a, luts: a.luts, render: result,
                                            expectedHook: { i, bytes in expected[i] = bytes })
        XCTAssertTrue(report.passed, "\(report.failures)")
        XCTAssertEqual(Array(expected.keys), [9])
        XCTAssertTrue(expected[9] == exported[9], "the check's frame 9 is not the export's bytes")
        // and the preview's chain really is different there, so this test can tell them apart
        let enhancer = try Enhancer(settings: settings, width: 320, height: 180, kernels: engine.kernels)
        let targets = try PreviewTargets(kernels: engine.kernels, width: 320, height: 180)
        try engine.preview(try engine.decodeFrame(noisy, analysis: a, index: 9, enhancer: enhancer), lut: a.luts[0], into: targets)
        XCTAssertFalse(texture(targets.graded) == exported[9], "preview and export agree at frame 9: the test would not see a wrong chain")
    }

    func testExportCheckCatchesAMissingEnhancement() throws {
        var cases: [(URL, EnhanceSettings)] = [(person, EnhanceSettings(background: .green)),
                                               (person, EnhanceSettings(background: .blur(strength: 1)))]
        if EnhanceSettings.denoiseAvailable { cases.append((noisy, EnhanceSettings(denoise: 1))) }
        for (url, settings) in cases {
            let a = try analyze(url)
            let out = dir.appendingPathComponent("c.mov")
            try? FileManager.default.removeItem(at: out)   // this test's own previous output
            let result = try engine.render(url, analysis: a, luts: a.luts, to: out, enhance: settings)
            let good = try engine.checkExport(out, source: url, analysis: a, luts: a.luts, render: result)
            let claimed = RenderResult(times: result.times, codec: result.codec, audioPackets: result.audioPackets,
                                       warnings: result.warnings, reframe: nil)
            let bad = try engine.checkExport(out, source: url, analysis: a, luts: a.luts, render: claimed)
            print("\(settings): with \(good.frames.map { String(format: "%.2f", $0.meanAbs) }), "
                  + "claimed none \(bad.frames.map { String(format: "%.2f/%.2f", $0.meanAbs, $0.bias.map(abs).max()!) })")
            XCTAssertTrue(good.passed, "\(settings): \(good.failures)")
            XCTAssertFalse(bad.passed, "\(settings): an export without the enhancement passed")
        }
    }
}

private func psnr(_ a: [[UInt8]], _ b: [[UInt8]]) -> Double {
    var sq = 0.0, n = 0
    for (x, y) in zip(a, b) {
        for i in stride(from: 0, to: x.count, by: 4) {
            for c in 0..<3 { let d = Double(x[i + c]) - Double(y[i + c]); sq += d * d }
            n += 3
        }
    }
    return 10 * log10(255 * 255 / (sq / Double(n)))
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
