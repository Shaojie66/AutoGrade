import AutoGradeCore
import CoreVideo
import XCTest

/// Background compositing against research/make_fixtures.py's numpy reference,
/// and the person segmenter on a real face (CLAUDE.md 画质增强 / 背景).
final class BackgroundTests: XCTestCase {
    func testCompositeMatchesReference() throws {
        let kernels = GradeKernels(metal: try MetalContext())
        let m = try Fixtures.floats("bg_mask")
        let mask = try kernels.makeMask(floats: m.values, width: m.shape[1], height: m.shape[0])
        XCTAssertEqual(Fixtures.manifest.background_cases.count, 2)
        for c in Fixtures.manifest.background_cases {
            let img = try kernels.makeImage(width: 160, height: 90, floats: try Fixtures.floats("bg_image").values)
            let effect: BackgroundEffect = c.effect == "blur" ? .blur(strength: 1) : .colour(SIMD3(c.colour[0], c.colour[1], c.colour[2]))
            let scratch = try BackgroundScratch(effect: effect, width: img.width, height: img.height,
                                                device: kernels.metal.device, sigma: c.sigma)
            try kernels.background(img, mask: mask, scratch: scratch)
            let err = maxAbsDifference(img.floats(), try Fixtures.floats(c.name).values)
            print("background \(c.name): max \(err)")
            XCTAssertLessThanOrEqual(err, 1e-5, c.name)
        }
    }

    func testMaskAverageAndFeatherMatchReference() throws {
        let raw = try Fixtures.bytes("bg_masks")
        let (n, h, w) = (raw.shape[0], raw.shape[1], raw.shape[2])
        let masks = (0..<n).map { k in PersonMask(bytes: Array(raw.values[(k * w * h)..<((k + 1) * w * h)]), width: w, height: h) }
        let kernels = GradeKernels(metal: try MetalContext())
        let combined = try PersonSegmentation.combine(masks, frameWidth: 640, frameHeight: 360, kernels: kernels)
        let floats = Array(UnsafeBufferPointer(start: combined.buffer.contents().bindMemory(to: Float.self, capacity: w * h), count: w * h))
        let err = maxAbsDifference(floats, try Fixtures.floats("bg_combined").values)
        print("mask combine: max \(err)")
        XCTAssertLessThanOrEqual(err, 1e-5)
    }

    func testGaussianTaps() {
        XCTAssertEqual(PersonSegmentation.gaussianWeights(sigma: 0.2), [1])
        let k = PersonSegmentation.gaussianWeights(sigma: 2)
        XCTAssertEqual(k.count, 13)
        XCTAssertEqual(k.reduce(0, +), 1, accuracy: 1e-6)
        XCTAssertEqual(k[6], k.max())
    }

    func testEffectNames() {
        XCTAssertEqual(BackgroundEffect(name: "green"), .green)
        XCTAssertEqual(BackgroundEffect(name: "#FF8000"), .colour(SIMD3(1, 128.0 / 255, 0)))
        XCTAssertEqual(BackgroundEffect(name: "blur", strength: 2), .blur(strength: 1))
        XCTAssertNil(BackgroundEffect(name: "#12345"))
        XCTAssertEqual(BackgroundEffect.blur(strength: 0.5).sigma(height: 1080), 1080 * 0.03 * 0.5, accuracy: 1e-4)
    }

    func testPersonIsFoundOnAFace() throws {
        let png = try Fixtures.rgb8("gym_b_in")
        let mask = try PersonSegmentation.mask(try pixelBuffer(png.rgb, width: png.width, height: png.height))
        func mean(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Double {
            var s = 0, n = 0
            for y in Int(y0 * Double(mask.height))..<Int(y1 * Double(mask.height)) {
                for x in Int(x0 * Double(mask.width))..<Int(x1 * Double(mask.width)) { s += Int(mask.bytes[y * mask.width + x]); n += 1 }
            }
            return Double(s) / Double(n) / 255
        }
        // gym_b: the face is right of centre, the gym's back wall and floor on the left
        let face = mean(0.5, 0.3, 0.7, 0.6)
        let background = [mean(0, 0, 0.1, 0.1), mean(0, 0.85, 0.1, 1), mean(0.05, 0.3, 0.25, 0.6)]
        print("person mask \(mask.width)x\(mask.height): face \(face), background \(background)")
        XCTAssertGreaterThan(face, 0.8)
        XCTAssertTrue(background.allSatisfy { $0 < 0.2 }, "\(background)")
    }
}

/// An RGB8 picture as a BGRA pixel buffer (what Vision reads in these tests).
func pixelBuffer(_ rgb: [UInt8], width: Int, height: Int) throws -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &pb)
    let buffer = try XCTUnwrap(pb)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let row = CVPixelBufferGetBytesPerRow(buffer), base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let s = (y * width + x) * 3, d = y * row + x * 4
            base[d] = rgb[s + 2]; base[d + 1] = rgb[s + 1]; base[d + 2] = rgb[s]; base[d + 3] = 255
        }
    }
    return buffer
}

/// Which shots get the background effect (CLAUDE.md 背景).
final class PeopleShotTests: XCTestCase {
    func testHalfTheFramesMustHaveSomeone() {
        let shots = [Shot(first: 0, last: 3), Shot(first: 4, last: 7), Shot(first: 8, last: 11)]
        let coverage: [Float] = [0, 0.0083, 0, 0.0009,        // one stray frame: nobody
                                 0.4, 0.3, 0.002, 0.001,      // two of four: someone
                                 0.006, 0.004, 0.003, 0.002]  // one of four: nobody
        XCTAssertEqual(PersonSegmentation.shotsWithPeople(coverage: coverage, shots: shots), [false, true, false])
    }
}
