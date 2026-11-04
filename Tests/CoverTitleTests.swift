import AutoGradeCore
import CoreGraphics
import Metal
import XCTest

/// Cover titles (CLAUDE.md 封面 / 版式): placements, keeping clear of the face,
/// the face box in cover pixels, shrinking, and the title only touching its block.
final class CoverTitleTests: XCTestCase {
    let tall = CGSize(width: 1080, height: 1440)
    let block = CGSize(width: 600, height: 120)

    func testPlacementsWithoutAFace() {
        // bottom: centred, its bottom edge 6% above the cover's
        var p = CoverTitleLayout.place(.bottom, canvas: tall, block: block, face: nil)
        XCTAssertEqual(p.rect, CGRect(x: 240, y: (1440 - 86.4 - 120).rounded(), width: 600, height: 120))
        XCTAssertFalse(p.overlapsFace)
        // corner: 6% in from the left and the top
        p = CoverTitleLayout.place(.corner, canvas: tall, block: block, face: nil)
        XCTAssertEqual(p.rect.origin, CGPoint(x: (1080 * 0.06).rounded(), y: (1440 * 0.06).rounded()))
        // center: in the middle
        p = CoverTitleLayout.place(.center, canvas: tall, block: block, face: nil)
        XCTAssertEqual(p.rect.origin, CGPoint(x: 240, y: 660))
    }

    func testMovesOffTheFace() {
        let lowFace = CGRect(x: 300, y: 1100, width: 400, height: 300)       // over the bottom placement
        var p = CoverTitleLayout.place(.bottom, canvas: tall, block: block, face: lowFace)
        XCTAssertEqual(p.rect.minY, (1440 * 0.06).rounded(), "moved to the top")
        XCTAssertFalse(p.overlapsFace)
        let middleFace = CGRect(x: 200, y: 500, width: 600, height: 500)     // over the centre placement
        p = CoverTitleLayout.place(.center, canvas: tall, block: block, face: middleFace)
        XCTAssertEqual(p.rect.midY, 1440 * 0.25, accuracy: 1, "the upper third")
        XCTAssertFalse(p.overlapsFace)
    }

    func testFaceEverywhereTakesTheLeastOverlap() {
        // covers the top fully and the bottom only partly: the bottom overlaps less
        let face = CGRect(x: 0, y: 0, width: 1080, height: 1300)
        let p = CoverTitleLayout.place(.bottom, canvas: tall, block: block, face: face)
        XCTAssertEqual(p.rect.minY, (1440 - 86.4 - 120).rounded())
        XCTAssertTrue(p.overlapsFace)
    }

    func testFaceBoxInCoverPixels() throws {
        let s = SubjectTrack.Sample(center: SIMD2(0.5, 0.5), size: SIMD2(0.1, 0.2), source: .face)
        // a 3:4 crop of 1920x1080: 810 wide from x = 555, scaled by 1080 / 810 to the cover
        let r = try XCTUnwrap(CoverTitleLayout.face(s, sourceWidth: 1920, sourceHeight: 1080, crop: SIMD2(555, 0),
                                                    length: SIMD2(810, 1080), canvas: tall))
        let k = 1080.0 / 810, m = 1080 * 0.04
        XCTAssertEqual(r.minX, (864 - 555) * k - m, accuracy: 1e-3)
        XCTAssertEqual(r.maxX, (1056 - 555) * k + m, accuracy: 1e-3)
        XCTAssertEqual(r.minY, 432 * k - m, accuracy: 1e-3)
        XCTAssertEqual(r.maxY, 648 * k + m, accuracy: 1e-3)
        // people and saliency boxes are not avoided
        let body = SubjectTrack.Sample(center: SIMD2(0.5, 0.5), size: SIMD2(0.4, 0.9), source: .human)
        XCTAssertNil(CoverTitleLayout.face(body, sourceWidth: 1920, sourceHeight: 1080, crop: SIMD2(555, 0),
                                           length: SIMD2(810, 1080), canvas: tall))
    }

    func testRasterSizesAndShrinks() throws {
        let short = try XCTUnwrap(CoverTitleLayout.raster(CoverTitle(title: "草原上的第一次骑马"), canvasWidth: 1080, canvasHeight: 1440))
        XCTAssertEqual(short.fontSize, 1080 * 0.085, accuracy: 0.01, "from the short side")
        let long = try XCTUnwrap(CoverTitleLayout.raster(CoverTitle(title: String(repeating: "很长的标题", count: 8)),
                                                         canvasWidth: 1080, canvasHeight: 1440))
        XCTAssertLessThan(long.fontSize, short.fontSize)
        XCTAssertLessThanOrEqual(CGFloat(long.width), 1080 * 0.85 + 2 * (long.fontSize * 0.2 + 3) + 2, "text within 85%")
        let two = try XCTUnwrap(CoverTitleLayout.raster(CoverTitle(title: "标题", subtitle: "副标题在下面", template: .corner),
                                                        canvasWidth: 1080, canvasHeight: 1440))
        let one = try XCTUnwrap(CoverTitleLayout.raster(CoverTitle(title: "标题", template: .corner), canvasWidth: 1080, canvasHeight: 1440))
        XCTAssertGreaterThan(two.height, one.height, "the subtitle adds a line")
        XCTAssertNil(CoverTitleLayout.raster(CoverTitle(title: "  ", subtitle: ""), canvasWidth: 1080, canvasHeight: 1440))
        // drawn the same way every time
        XCTAssertEqual(CoverTitleLayout.raster(CoverTitle(title: "草原上的第一次骑马"), canvasWidth: 1080, canvasHeight: 1440)?.rgba,
                       short.rgba)
    }

    /// Outside its block the titled cover is the plain cover byte for byte; inside it differs.
    func testTitleOnlyTouchesItsBlock() throws {
        let engine = try AutoGrader(stylesDirectory: nil)
        let clip = Fixtures.url("synthetic_cover.mp4")
        let a = try engine.analyze(clip, lutSize: 33, cutThreshold: Fixtures.manifest.cut_threshold)
        let (w, h) = (a.info.width, a.info.height)
        let frame = EnhancedFrame(try engine.decodeFrame(clip, analysis: a, index: 90))
        let lut = a.luts[a.shotIndex(forFrame: 90)]
        for aspect in [CoverAspect.portrait3x4, .original] {
            let targets = try CoverTargets(kernels: engine.kernels, sourceWidth: w, sourceHeight: h, aspect: aspect)
            let centre = SIMD2<Float>(0.5, 0.5)
            let plain = try engine.renderCover(frame, lut: lut, aspect: aspect, center: centre, into: targets)
            let made = try XCTUnwrap(try engine.coverTitleOverlay(CoverTitle(title: "漫画封面"), aspect: aspect, sourceWidth: w,
                                                                   sourceHeight: h, center: centre, face: nil))
            let titled = try engine.renderCover(frame, lut: lut, aspect: aspect, center: centre, into: targets, title: made.overlay)
            let (cw, ch) = aspect.outputSize(sourceWidth: w, sourceHeight: h)
            let o = made.overlay.1, bw = made.overlay.0.width, bh = made.overlay.0.height
            var inside = 0, outside = 0
            for y in 0..<ch {
                for x in 0..<cw {
                    let i = (y * cw + x) * 4
                    guard titled[i..<(i + 4)] != plain[i..<(i + 4)] else { continue }
                    if x >= Int(o.x) && x < Int(o.x) + bw && y >= Int(o.y) && y < Int(o.y) + bh { inside += 1 } else { outside += 1 }
                }
            }
            XCTAssertEqual(outside, 0, "\(aspect): pixels outside the title block changed")
            XCTAssertGreaterThan(inside, 100, "\(aspect): the title was drawn")
        }
    }
}
