import AutoGradeCore
import AVFoundation
import Metal
import XCTest

/// Phase 3 Core: strength, cut editing, range reads, cancellation, and the
/// preview/export agreement (CLAUDE.md 架构原则 5).
final class EditTests: XCTestCase {
    var engine: AutoGrader!
    var kernels: GradeKernels { engine.kernels }
    let synthetic = Fixtures.url("synthetic_shots.mp4")

    override func setUpWithError() throws {
        engine = try AutoGrader()
    }

    private func analyze(_ url: URL, cut: Float = Fixtures.manifest.cut_threshold) throws -> Analysis {
        try engine.analyze(url, lutSize: 33, cutThreshold: cut)
    }

    // MARK: strength

    func testStrengthEndsAreExact() throws {
        let lut = try kernels.makeLUT(size: 33, floats: try Fixtures.floats("gym_shot33").values)
        XCTAssertEqual(try kernels.blend(lut, strength: 1).floats(), lut.floats(), "s = 1 is the shot LUT bit for bit")

        let identity = try kernels.blend(lut, strength: 0)
        let out = try kernels.applyLUT(try Fixtures.planarImage("gym_a_in", kernels: kernels), identity)
        let d = try lsbDifference(out, "gym_a_in")
        print("strength 0 vs input: max \(d.max) LSB, \(d.differing) px differ")
        XCTAssertEqual(d.max, 0, "s = 0 is the original picture")
    }

    func testStrengthHalfMatchesFormula() throws {
        let n = 33
        let values = try Fixtures.floats("gym_shot33").values
        let got = try kernels.blend(try kernels.makeLUT(size: n, floats: values), strength: 0.5).floats()
        let step = Float(1) / Float(n - 1)
        func lin(_ i: Int) -> Float { i < n / 2 ? Float(i) * step : 1 - Float(n - 1 - i) * step }
        var worst: Float = 0
        let n3 = n * n * n
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = (b * n + g) * n + r
            for (c, id) in [lin(r), lin(g), lin(b)].enumerated() {
                worst = max(worst, abs(got[i + c * n3] - (0.5 * values[i + c * n3] + 0.5 * id)))
            }
        } } }
        print("strength 0.5 vs formula: max \(worst)")
        XCTAssertLessThanOrEqual(worst, 1e-6)
    }

    // MARK: cut editing

    func testRemoveCutEqualsAnalysingTheMergedShot() throws {
        let three = try analyze(synthetic)
        XCTAssertEqual(three.shots.count, 3)
        let merged = try engine.removeCut(three, beforeShot: 1)
        XCTAssertEqual(merged.shots, [Shot(first: 0, last: 59), Shot(first: 60, last: 89)])

        // Reference: no cuts at all (L1 distance never exceeds 2), then one cut at 60.
        let whole = try analyze(synthetic, cut: 3)
        XCTAssertEqual(whole.shots, [Shot(first: 0, last: 89)])
        let reference = try engine.addCut(whole, source: synthetic, atFrame: 60)
        let err = maxAbsDifference(merged.luts[0].floats(), reference.luts[0].floats())
        print("removeCut vs one-pass shot 0-59: max \(err)")
        XCTAssertLessThanOrEqual(err, 1e-6)
        XCTAssertEqual(merged.luts[1].floats(), three.luts[2].floats(), "untouched shot is unchanged")
    }

    func testAddCutEqualsFreshAnalysisAndRoundTrips() throws {
        let three = try analyze(synthetic)
        let restored = try engine.addCut(try engine.removeCut(three, beforeShot: 1), source: synthetic, atFrame: 30)
        XCTAssertEqual(restored.shots, three.shots)
        for k in 0..<3 {
            let err = maxAbsDifference(restored.luts[k].floats(), three.luts[k].floats())
            print("addCut round trip shot \(k): max \(err)")
            XCTAssertLessThanOrEqual(err, 1e-6)
        }
    }

    // MARK: range reads

    func testRangeReadFindsFramesByTimestampOnVariableFrameRate() throws {
        let vfr = Fixtures.url("synthetic_vfr.mp4")
        let analysis = try analyze(vfr)
        let expected = Fixtures.manifest.vfr_frame_times
        XCTAssertEqual(analysis.frameCount, expected.count)
        for (i, t) in expected.enumerated() {
            XCTAssertEqual(analysis.frameTimes[i].seconds, t, accuracy: 1e-6, "frame \(i)")
        }
        // Sequential luma planes, then random access must return the same picture.
        var sequential: [Int: [UInt8]] = [:]
        let probe = [0, 2, 3, 17, 30, expected.count - 1]
        let reader = try VideoReader(url: vfr, device: engine.metal.device)
        while let f = try reader.next() {
            if probe.contains(f.index) { sequential[f.index] = lumaBytes(f) }
        }
        for i in probe {
            let f = try engine.decodeFrame(vfr, analysis: analysis, index: i)
            XCTAssertEqual(f.index, i)
            XCTAssertEqual(f.presentationTime, analysis.frameTimes[i])
            XCTAssertEqual(lumaBytes(f), sequential[i], "frame \(i) pixels")
        }
    }

    // MARK: cancellation

    func testCancelledRenderLeavesNoFile() throws {
        let analysis = try analyze(synthetic)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("autograde-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }   // test's own temp directory
        let out = dir.appendingPathComponent("cancelled.mov")
        let token = CancelToken()
        XCTAssertThrowsError(try engine.render(synthetic, analysis: analysis, luts: analysis.luts, to: out,
                                               cancel: token, progress: { if $0 == 10 { token.cancel() } })) {
            XCTAssertTrue($0 is Cancelled, "\($0)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: preview == export

    func testPreviewIsByteIdenticalToExport() throws {
        let analysis = try analyze(synthetic)
        let luts = try engine.finalLUTs(analysis, strengths: [1, 0.4, 0])
        let probe: Set = [0, 29, 45, 89]
        var exported: [Int: [UInt8]] = [:]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("autograde-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try engine.render(synthetic, analysis: analysis, luts: luts, to: dir.appendingPathComponent("o.mov"),
                              frameHook: { i, pb in if probe.contains(i) { exported[i] = bgraBytes(pb) } })
        let targets = try PreviewTargets(kernels: kernels, width: analysis.info.width, height: analysis.info.height)
        for i in probe.sorted() {
            let frame = try engine.decodeFrame(synthetic, analysis: analysis, index: i)
            try engine.preview(frame, lut: luts[analysis.shotIndex(forFrame: i)], into: targets)
            let preview = textureBytes(targets.graded)
            XCTAssertEqual(preview.count, exported[i]?.count)
            XCTAssertTrue(preview == exported[i], "frame \(i): preview differs from export")
        }
    }
}

// MARK: byte readers

private func lumaBytes(_ f: DecodedFrame) -> [UInt8] {
    let pb = f.pixelBuffer
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
    let row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    return (0..<h).flatMap { y in Array(UnsafeBufferPointer(start: base + y * row, count: w)) }
}

private func bgraBytes(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    return (0..<h).flatMap { y in Array(UnsafeBufferPointer(start: base + y * row, count: w * 4)) }
}

private func textureBytes(_ t: MTLTexture) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: t.width * t.height * 4)
    t.getBytes(&bytes, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
    return bytes
}
