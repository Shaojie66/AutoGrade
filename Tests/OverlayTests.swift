import AutoGradeCore
import XCTest

/// The subtitle compositing kernel against research/make_fixtures.py's numpy
/// reference (CLAUDE.md 字幕叠加): clear, half and opaque areas, inside and
/// partly outside the frame.
final class OverlayTests: XCTestCase {
    func testOverlayMatchesReference() throws {
        let kernels = GradeKernels(metal: try MetalContext())
        let rgba = try Fixtures.bytes("overlay_rgba")
        let patch = try kernels.makeOverlay(rgba: rgba.values, width: rgba.shape[1], height: rgba.shape[0])
        XCTAssertEqual(Fixtures.manifest.overlay_cases.count, 2)
        for c in Fixtures.manifest.overlay_cases {
            let img = try kernels.makeImage(width: 256, height: 256, floats: try Fixtures.floats("demo_resized256").values)
            try kernels.overlay(img, patch, origin: SIMD2(c.origin[0], c.origin[1]))
            let err = maxAbsDifference(img.floats(), try Fixtures.floats(c.name).values)
            print("overlay \(c.name): max \(err)")
            XCTAssertLessThanOrEqual(err, 1e-6, c.name)
        }
    }
}
