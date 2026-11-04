import AutoGradeCore
import XCTest

/// The reframe crop-and-resize kernel against the numpy reference in
/// research/make_fixtures.py (CLAUDE.md 重构图的裁切缩放): up, down, fractional
/// origins, and a portrait source cropped to 16:9.
final class CropResizeTests: XCTestCase {
    func testCropResizeMatchesReference() throws {
        let kernels = GradeKernels(metal: try MetalContext())
        XCTAssertEqual(Fixtures.manifest.crop_cases.count, 5)
        for c in Fixtures.manifest.crop_cases {
            var src = try source(c.input, kernels: kernels)
            if c.transposed { src = try transpose(src, kernels: kernels) }
            let out = try kernels.cropResize(src, origin: SIMD2(c.origin[0], c.origin[1]), length: SIMD2(c.length[0], c.length[1]),
                                             width: c.output[0], height: c.output[1]).floats()
            let expected = try Fixtures.floats(c.name).values
            let err = maxAbsDifference(out, expected)
            var worst = 0, off = 0
            for i in 0..<out.count {
                let d = abs(Int(quantize8(out[i])) - Int(quantize8(expected[i])))
                worst = max(worst, d)
                if d > 0 { off += 1 }
            }
            print("crop \(c.name): max \(err), 8-bit max \(worst) (\(off)/\(out.count) samples differ)")
            XCTAssertLessThanOrEqual(err, 1e-5, c.name)
            XCTAssertLessThanOrEqual(worst, 1, c.name)
        }
    }

    func testRefusesCropOutsideTheFrame() throws {
        let kernels = GradeKernels(metal: try MetalContext())
        let src = try kernels.makeImage(width: 64, height: 36)
        XCTAssertThrowsError(try kernels.cropResize(src, origin: SIMD2(50, 0), length: SIMD2(20.25, 36), width: 9, height: 16))
        XCTAssertThrowsError(try kernels.cropResize(src, origin: SIMD2(-1, 0), length: SIMD2(20.25, 36), width: 9, height: 16))
    }

    private func source(_ name: String, kernels: GradeKernels) throws -> PlanarImage {
        if name.hasSuffix("_in") { return try Fixtures.planarImage(name, kernels: kernels) }
        return try kernels.makeImage(width: 256, height: 256, floats: try Fixtures.floats(name).values)
    }

    private func transpose(_ img: PlanarImage, kernels: GradeKernels) throws -> PlanarImage {
        let w = img.width, h = img.height, f = img.floats()
        var t = [Float](repeating: 0, count: f.count)
        for c in 0..<3 { for y in 0..<h { for x in 0..<w { t[c * w * h + x * h + y] = f[c * w * h + y * w + x] } } }
        return try kernels.makeImage(width: h, height: w, floats: t)
    }
}
