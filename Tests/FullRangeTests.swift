import AutoGradeCore
import AVFoundation
import Metal
import XCTest

/// Full-range 8-bit sources (GoPro writes them): read as coded ('420f'),
/// converted with the H.273 full-range formula, and the rest of the pipeline
/// unchanged (CLAUDE.md 架构原则 4). fixtures/synthetic_fullrange.mp4 has luma
/// 7…238, so the two ranges give different pictures.
final class FullRangeTests: XCTestCase {
    var engine: AutoGrader!
    var dir: URL!
    let full = Fixtures.url("synthetic_fullrange.mp4")

    override func setUpWithError() throws {
        engine = try AutoGrader(stylesDirectory: nil)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("autograde-fullrange-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)   // this test's own temporary directory
    }

    private func frame(_ url: URL, _ index: Int) throws -> DecodedFrame {
        let reader = try VideoReader(url: url, device: engine.metal.device)
        while let f = try reader.next() { if f.index == index { return f } }
        throw XCTSkip("frame \(index) not decoded")
    }

    private func analyze(_ url: URL) throws -> Analysis {
        try engine.analyze(url, lutSize: 33, cutThreshold: Fixtures.manifest.cut_threshold)
    }

    func testReaderKeepsTheSourceRange() throws {
        let fullReader = try VideoReader(url: full, device: engine.metal.device)
        XCTAssertTrue(fullReader.info.fullRange)
        let f = try XCTUnwrap(try fullReader.next())
        XCTAssertTrue(f.fullRange)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(f.pixelBuffer), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                       "read as coded, not range-converted to '420v' by the system")
        let limited = try VideoReader(url: Fixtures.url("synthetic_shots.mp4"), device: engine.metal.device)
        XCTAssertFalse(limited.info.fullRange)
        let g = try XCTUnwrap(try limited.next())
        XCTAssertFalse(g.fullRange)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(g.pixelBuffer), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    /// The decoder's full-range planes are the coded bytes ffmpeg extracted as yuvj420p.
    func testDecoderPlanesMatchFfmpeg() throws {
        let pb = try frame(full, 15).pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let (y, yShape) = try Fixtures.bytes("fullrange_f15_y")
        let (cb, _) = try Fixtures.bytes("fullrange_f15_cb")
        let (cr, cShape) = try Fixtures.bytes("fullrange_f15_cr")
        let h = yShape[0], w = yShape[1], hc = cShape[0], wc = cShape[1]
        var mismatched = 0
        let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for r in 0..<h { for c in 0..<w where yBase[r * yRow + c] != y[r * w + c] { mismatched += 1 } }
        let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for r in 0..<hc {
            for c in 0..<wc {
                if cBase[r * cRow + 2 * c] != cb[r * wc + c] { mismatched += 1 }
                if cBase[r * cRow + 2 * c + 1] != cr[r * wc + c] { mismatched += 1 }
            }
        }
        print("full-range decoder planes vs ffmpeg: \(mismatched) mismatched samples")
        XCTAssertEqual(mismatched, 0)
    }

    func testFullRangeToRGBMatchesConvention() throws {
        let f = try frame(full, 15)
        let rgb = try engine.kernels.yuvToRGB(luma: f.luma, chroma: f.chroma, fullRange: true).floats()
        let want = try Fixtures.floats("fullrange_f15_rgb").values
        let err = maxAbsDifference(rgb, want)
        print("full-range yuv→rgb frame 15: max \(err)")
        XCTAssertLessThanOrEqual(err, 1e-5)
        // and reading it as limited would be visibly wrong: the test tells the formulas apart
        let wrong = try engine.kernels.yuvToRGB(luma: f.luma, chroma: f.chroma, fullRange: false).floats()
        XCTAssertGreaterThan(maxAbsDifference(wrong, want), 0.02)
    }

    func testPreviewIsByteIdenticalToExport() throws {
        let a = try analyze(full)
        XCTAssertTrue(a.info.fullRange)
        let probe: Set = [0, 15, 29]
        var exported: [Int: [UInt8]] = [:]
        let out = dir.appendingPathComponent("f.mov")
        let result = try engine.render(full, analysis: a, luts: a.luts, to: out,
                                       frameHook: { i, pb in if probe.contains(i) { exported[i] = bgra(pb) } })
        let targets = try PreviewTargets(kernels: engine.kernels, width: 320, height: 180)
        for i in probe.sorted() {
            try engine.preview(try engine.decodeFrame(full, analysis: a, index: i), lut: a.luts[a.shotIndex(forFrame: i)], into: targets)
            XCTAssertTrue(texture(targets.graded) == exported[i], "frame \(i): preview differs from the export")
        }
        let report = try engine.checkExport(out, source: full, analysis: a, luts: a.luts, render: result)
        print("full-range export check: \(report.frames.map { String(format: "%.2f", $0.meanAbs) }) \(report.failures)")
        XCTAssertTrue(report.passed, "\(report.failures)")
    }

    func testReframedPreviewIsByteIdenticalToExport() throws {
        let a = try analyze(full)
        let path = Reframe.path(track: SubtitleTrackless.centred(a.frameCount), shots: a.shots, frameTimes: a.frameTimes,
                                width: 320, height: 180, aspect: .vertical9x16, overrides: Array(repeating: nil, count: a.shots.count))
        var exported: [UInt8]?
        _ = try engine.render(full, analysis: a, luts: a.luts, to: dir.appendingPathComponent("r.mov"), reframe: path,
                              frameHook: { i, pb in if i == 15 { exported = bgra(pb) } })
        let targets = try ReframeTargets(kernels: engine.kernels, sourceWidth: 320, sourceHeight: 180, aspect: .vertical9x16)
        try engine.previewReframed(try engine.decodeFrame(full, analysis: a, index: 15), lut: a.luts[0], path: path, into: targets)
        XCTAssertTrue(texture(targets.output) == exported, "成片 preview of a full-range source differs from the export")
    }

    /// Noise reduction keeps the range ('&8f0' in, '420f' out): the check's exact frame is the export's bytes.
    func testDenoisedExactFrameIsTheExport() throws {
        guard EnhanceSettings.denoiseAvailable else { throw XCTSkip("noise reduction needs macOS 26") }
        let a = try analyze(full)
        let settings = EnhanceSettings(denoise: 1)
        var exported: [Int: [UInt8]] = [:]
        _ = try engine.render(full, analysis: a, luts: a.luts, to: dir.appendingPathComponent("d.mov"), enhance: settings,
                              frameHook: { i, pb in exported[i] = bgra(pb) })
        let enhancer = try Enhancer(settings: settings, width: 320, height: 180, kernels: engine.kernels)
        let targets = try PreviewTargets(kernels: engine.kernels, width: 320, height: 180)
        for i in [0, 15, 29] {
            let f = try engine.decodeFrame(full, analysis: a, index: i, enhancer: enhancer, exact: true)
            XCTAssertTrue(f.frame.fullRange, "frame \(i): the denoised frame left full range")
            try engine.preview(f, lut: a.luts[a.shotIndex(forFrame: i)], into: targets)
            XCTAssertTrue(texture(targets.graded) == exported[i], "frame \(i): denoised exact frame differs from the export")
        }
    }

    /// Noise reduction must not range-convert: at strength 0 the filter passes
    /// the frame through, so the planes come back exactly as decoded — a trip
    /// through '&8v0' would round full-range codes on the way (CLAUDE.md 降噪).
    func testDenoiseAtStrengthZeroKeepsTheCodedPlanes() throws {
        guard EnhanceSettings.denoiseAvailable else { throw XCTSkip("noise reduction needs macOS 26") }
        let a = try analyze(full)
        let enhancer = try Enhancer(settings: EnhanceSettings(denoise: 0), width: 320, height: 180, kernels: engine.kernels)
        for (url, label) in [(full, "full"), (Fixtures.url("synthetic_shots.mp4"), "limited")] {
            let b = url == full ? a : try analyze(url)
            let e = url == full ? enhancer : try Enhancer(settings: EnhanceSettings(denoise: 0), width: 320, height: 180, kernels: engine.kernels)
            let f = try engine.decodeFrame(url, analysis: b, index: 15, enhancer: e, exact: true)
            let diff = planeDifference(f.source.pixelBuffer, f.frame.pixelBuffer)
            print("denoise strength 0, \(label) range: \(diff.count) samples changed, max \(diff.max)")
            XCTAssertEqual(diff.count, 0, "\(label): planes changed at strength 0")
        }
    }

    /// Cover scoring reads luma straight from the buffer: Y / 255 for '420f'.
    func testCoverLumaUsesTheBuffersRange() throws {
        let f = try frame(full, 15)
        let (w, h, values) = Cover.luma(f.pixelBuffer)
        XCTAssertEqual(w, 320)
        XCTAssertEqual(h, 180)
        let y = try Fixtures.bytes("fullrange_f15_y").values
        let err = zip(values, y).map { abs($0 - Double($1) / 255) }.max()!
        XCTAssertLessThanOrEqual(err, 1e-12, "full-range luma is Y / 255")
    }
}

/// Samples that differ between two 4:2:0 buffers of one size, and the largest difference.
private func planeDifference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> (count: Int, max: Int) {
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    var count = 0, top = 0
    for plane in 0..<2 {
        let w = CVPixelBufferGetWidthOfPlane(a, plane) * (plane == 0 ? 1 : 2), h = CVPixelBufferGetHeightOfPlane(a, plane)
        let pa = CVPixelBufferGetBaseAddressOfPlane(a, plane)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddressOfPlane(b, plane)!.assumingMemoryBound(to: UInt8.self)
        let ra = CVPixelBufferGetBytesPerRowOfPlane(a, plane), rb = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
        for y in 0..<h { for x in 0..<w { let d = abs(Int(pa[y * ra + x]) - Int(pb[y * rb + x])); if d > 0 { count += 1; top = max(top, d) } } }
    }
    return (count, top)
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
