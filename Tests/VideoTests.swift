import AutoGradeCore
import AVFoundation
import Metal
import XCTest

/// Decode, colour conversion, shot detection and the whole two-pass pipeline
/// on fixtures/synthetic_shots.mp4 (three synthetic shots, cuts at 30 and 60).
final class VideoTests: XCTestCase {
    var metal: MetalContext!
    var kernels: GradeKernels!

    override func setUpWithError() throws {
        metal = try MetalContext()
        kernels = GradeKernels(metal: metal)
    }

    private func frame(_ index: Int) throws -> DecodedFrame {
        let reader = try VideoReader(url: Fixtures.url("synthetic_shots.mp4"), device: metal.device)
        while let f = try reader.next() {
            if f.index == index { return f }
        }
        throw XCTSkip("frame \(index) not decoded")
    }

    /// AVFoundation's planes must be the same bytes ffmpeg decoded (H.264 decoding is bit-exact).
    func testDecoderPlanesMatchFfmpeg() throws {
        let f = try frame(15)
        let pb = f.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let (y, yShape) = try Fixtures.bytes("synthetic_f15_y")
        let (cb, _) = try Fixtures.bytes("synthetic_f15_cb")
        let (cr, cShape) = try Fixtures.bytes("synthetic_f15_cr")
        let h = yShape[0], w = yShape[1], hc = cShape[0], wc = cShape[1]
        XCTAssertEqual(CVPixelBufferGetWidthOfPlane(pb, 0), w)
        XCTAssertEqual(CVPixelBufferGetHeightOfPlane(pb, 0), h)
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
        print("decoder planes vs ffmpeg: \(mismatched) mismatched samples")
        XCTAssertEqual(mismatched, 0)
    }

    func testYUVToRGBMatchesConvention() throws {
        let f = try frame(15)
        let rgb = try kernels.yuvToRGB(luma: f.luma, chroma: f.chroma).floats()
        let err = maxAbsDifference(rgb, try Fixtures.floats("synthetic_f15_rgb").values)
        print("yuv→rgb frame 15: max \(err)")
        XCTAssertLessThanOrEqual(err, 1e-5)
    }

    func testRefusesExistingOutput() throws {
        let existing = Fixtures.url("synthetic_shots.mp4")
        XCTAssertThrowsError(try VideoWriter(url: existing, width: 320, height: 180, codec: .hevc, device: metal.device))
    }

    func testTwoPassPipelineOnSyntheticShots() throws {
        let engine = try AutoGrader(stylesDirectory: nil)
        let analysis = try engine.analyze(Fixtures.url("synthetic_shots.mp4"), lutSize: 33,
                                          cutThreshold: Fixtures.manifest.cut_threshold)
        let shots = analysis.shots.map { [$0.first, $0.last] }
        print("synthetic shots: \(shots)")
        XCTAssertEqual(shots, Fixtures.manifest.synthetic_shots)
        XCTAssertEqual(analysis.frameCount, 90)
        XCTAssertEqual(analysis.luts.count, 3)
        for lut in analysis.luts {
            let v = lut.floats()
            XCTAssertTrue(v.allSatisfy { $0 >= 0 && $0 <= 1 }, "shot LUTs are clamped")
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("autograde-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }   // test's own temp directory
        let out = dir.appendingPathComponent("graded.mov")
        let times = try engine.render(Fixtures.url("synthetic_shots.mp4"), analysis: analysis, luts: analysis.luts, to: out)
        XCTAssertEqual(times.frames, 90)

        let check = try VideoReader(url: out, device: metal.device)
        var frames = 0
        while try check.next() != nil { frames += 1 }
        XCTAssertEqual(frames, 90, "written file decodes to the same frame count")
        XCTAssertEqual(check.info.width, 320)
        XCTAssertEqual(check.info.height, 180)
        XCTAssertTrue(check.warnings.isEmpty, "output is tagged BT.709: \(check.warnings)")

        let cubes = try engine.writeCubes(analysis, luts: analysis.luts, to: dir, prefix: "synthetic")
        XCTAssertEqual(cubes.count, 3)
    }
}
