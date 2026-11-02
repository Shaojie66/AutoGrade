import AutoGradeCore
import Metal
import XCTest

/// Each numeric stage against fixtures/ (CLAUDE.md 容差表). Every test prints
/// its measured error so a pass also records the margin.
final class ParityTests: XCTestCase {
    static let inputs = ["demo", "gym_a", "gym_b", "comic"]
    var kernels: GradeKernels!

    override func setUpWithError() throws {
        kernels = GradeKernels(metal: try MetalContext())
    }

    // MARK: network input

    func testResizeTo256MatchesPyTorch() throws {
        for name in Self.inputs {
            let img = try Fixtures.planarImage("\(name)_in", kernels: kernels)
            let got = try kernels.resize(img, width: 256, height: 256).floats()
            let err = maxAbsDifference(got, try Fixtures.floats("\(name)_resized256").values)
            print("resize \(name): max \(err)")
            XCTAssertLessThanOrEqual(err, 1e-5, name)
        }
    }

    func testCoreMLMatchesPyTorch() throws {
        let grader = try Grader(kernels: kernels)
        for name in Self.inputs {
            let resized = try kernels.makeImage(width: 256, height: 256,
                                                floats: try Fixtures.floats("\(name)_resized256").values)
            let ai = try grader.predict(resized)
            let lut = Array(UnsafeBufferPointer(start: ai.lut.contents().bindMemory(to: Float.self, capacity: 3 * 33 * 33 * 33),
                                                count: 3 * 33 * 33 * 33))
            let ver = Array(UnsafeBufferPointer(start: ai.vertices.contents().bindMemory(to: Float.self, capacity: 99), count: 99))
            let errLUT = maxAbsDifference(lut, try Fixtures.floats("\(name)_lut").values)
            let errVer = maxAbsDifference(ver, try Fixtures.floats("\(name)_vertices").values)
            print("coreml \(name): lut max \(errLUT), vertices max \(errVer)")
            XCTAssertLessThanOrEqual(errLUT, 1e-4, name)
            XCTAssertLessThanOrEqual(errVer, 1e-4, name)
        }
    }

    // MARK: AiLUT

    func testAiLUTApplyMatchesUpstreamKernel() throws {
        for name in Self.inputs {
            let img = try Fixtures.planarImage("\(name)_in", kernels: kernels)
            let out = try kernels.applyAiLUT(img, try Fixtures.aiLUT(name, kernels: kernels))
            let d = try lsbDifference(out, "\(name)_ailut_out")
            print("ailut apply \(name): max \(d.max) LSB, \(d.differing)/\(d.pixels) px differ")
            XCTAssertEqual(d.max, 0, name)
        }
    }

    func testBakeMatchesUpstreamKernel() throws {
        let baked = try kernels.bake(try Fixtures.aiLUT("demo", kernels: kernels), size: 33).floats()
        let err = maxAbsDifference(baked, try Fixtures.floats("demo_bake33").values)
        print("bake33 demo: max \(err)")
        XCTAssertLessThanOrEqual(err, 1e-5)
    }

    // MARK: shot LUT

    func testShotAverageAt33() throws {
        let acc = try kernels.makeLUT(size: 33)
        for name in ["gym_a", "gym_b"] {
            try kernels.accumulate(acc, try kernels.bake(try Fixtures.aiLUT(name, kernels: kernels), size: 33))
        }
        let err = maxAbsDifference(try kernels.mean(acc, frames: 2).floats(), try Fixtures.floats("gym_shot33").values)
        print("shot33 gym: max \(err)")
        XCTAssertLessThanOrEqual(err, 1e-5)
    }

    func testShotLUTAt65AppliedMatchesUpstream() throws {
        let acc = try kernels.makeLUT(size: 65)
        for name in ["gym_a", "gym_b"] {
            try kernels.accumulate(acc, try kernels.bake(try Fixtures.aiLUT(name, kernels: kernels), size: 65))
        }
        let out = try kernels.applyLUT(try Fixtures.planarImage("gym_a_in", kernels: kernels), try kernels.mean(acc, frames: 2))
        let d = try lsbDifference(out, "gym_a_shot65_out")
        print("shot65 apply gym_a: max \(d.max) LSB, \(d.differing)/\(d.pixels) px differ")
        // 0, not 1: at <= 1 LSB a 0.1% error in one trilinear weight still passed.
        XCTAssertEqual(d.max, 0)
    }

    func testCubeWriterIsByteIdenticalToResearch() throws {
        let lut = try kernels.makeLUT(size: 33, floats: try Fixtures.floats("gym_shot33").values)
        let text = Data(CubeWriter.text(lut, title: "AutoGrade gym shot").utf8)
        XCTAssertEqual(text.count, try Fixtures.text("gym_shot33.cube").count)
        XCTAssertEqual(sha256(text), Fixtures.manifest.files["gym_shot33.cube"]!.sha256)
    }

    /// ffmpeg is a test-only reader of our .cube (never a runtime dependency).
    func testFfmpegReadsOurCubeTheSameWay() throws {
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("ffmpeg not installed")
        }
        let cube = Fixtures.url("gym_shot33.cube"), input = Fixtures.url("gym_a_in")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-nostdin", "-v", "error", "-i", input.path, "-vf",
                       "lut3d=file='\(cube.path)':interp=trilinear", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        let lut = try kernels.makeLUT(size: 33, floats: try Fixtures.floats("gym_shot33").values)
        let ours = try kernels.applyLUT(try Fixtures.planarImage("gym_a_in", kernels: kernels), lut).floats()
        let n = ours.count / 3
        XCTAssertEqual(raw.count, n * 3)
        var worst = 0, over1 = 0
        for i in 0..<n {
            for c in 0..<3 {
                let d = abs(Int(raw[i * 3 + c]) - Int(quantize8(ours[c * n + i])))
                worst = max(worst, d)
                if d > 1 { over1 += 1 }
            }
        }
        print("ffmpeg lut3d vs metal: max \(worst) LSB, \(over1) samples > 1 LSB")
        XCTAssertLessThanOrEqual(worst, 1)
    }
}
