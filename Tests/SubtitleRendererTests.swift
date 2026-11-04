import AutoGradeCore
import CoreText
import XCTest

/// Rasterised subtitles: checked by properties that do not depend on the OS's
/// font rendering, never against golden pixels (CLAUDE.md 字幕).
final class SubtitleRendererTests: XCTestCase {
    func coverage(_ r: SubtitleRenderer.Raster) -> (opaque: Int, maxAlpha: UInt8) {
        var opaque = 0, top: UInt8 = 0
        for i in stride(from: 3, to: r.rgba.count, by: 4) { top = max(top, r.rgba[i]); if r.rgba[i] > 200 { opaque += 1 } }
        return (opaque, top)
    }

    func testWideFramePlacementAndInk() throws {
        let r = try XCTUnwrap(SubtitleRenderer.render(["今天天气很好"], frameWidth: 1920, frameHeight: 1080))
        XCTAssertEqual(r.fontSize, 1080 * 0.055, accuracy: 0.01)
        XCTAssertEqual(Int(r.origin.y) + r.height, 1080 - Int((1080 * 0.08).rounded()), "bottom edge 8% above the frame's")
        XCTAssertEqual(Double(r.origin.x) + Double(r.width) / 2, 960, accuracy: 1, "centred")
        let c = coverage(r)
        XCTAssertEqual(c.maxAlpha, 255)
        XCTAssertGreaterThan(c.opaque, 500, "there is text")
        // white text on a black outline: a good share of the opaque pixels are white
        // (a stroke drawn over the fill turned CJK text black, 2026-11-04)
        var white = 0
        for i in stride(from: 0, to: r.rgba.count, by: 4) where r.rgba[i + 3] > 200 && r.rgba[i] > 200 { white += 1 }
        print("subtitle raster: \(c.opaque) opaque px, \(white) white (\(String(format: "%.0f", 100 * Double(white) / Double(c.opaque)))%)")
        XCTAssertGreaterThan(Double(white) / Double(c.opaque), 0.3, "the text itself is white")
        // premultiplied: no channel above alpha
        for i in stride(from: 0, to: r.rgba.count, by: 4) {
            XCTAssertLessThanOrEqual(max(r.rgba[i], r.rgba[i + 1], r.rgba[i + 2]), r.rgba[i + 3])
        }
    }

    func testVerticalFrameSitsAt70Percent() throws {
        let r = try XCTUnwrap(SubtitleRenderer.render(["竖屏字幕"], frameWidth: 1080, frameHeight: 1920))
        XCTAssertEqual(r.fontSize, 1080 * 0.055, accuracy: 0.01, "sized from the width")
        XCTAssertEqual(Double(r.origin.y) + Double(r.height) / 2, 1920 * 0.70, accuracy: 1)
    }

    func testTwoLinesAreTallerAndLongTextShrinks() throws {
        let one = try XCTUnwrap(SubtitleRenderer.render(["一行"], frameWidth: 1920, frameHeight: 1080))
        let two = try XCTUnwrap(SubtitleRenderer.render(["第一行", "第二行"], frameWidth: 1920, frameHeight: 1080))
        XCTAssertGreaterThan(two.height, one.height + Int(one.fontSize))
        let long = try XCTUnwrap(SubtitleRenderer.render([String(repeating: "很长的字幕", count: 12)], frameWidth: 1920, frameHeight: 1080))
        XCTAssertLessThan(long.fontSize, one.fontSize)
        // the raster adds a margin of about 0.2 x font size + 3 px on each side for the stroke and shadow
        let margin = 2 * (Double(long.fontSize) * 0.2 + 3)
        XCTAssertLessThanOrEqual(Double(long.width) - margin, 1920 * 0.85, "the text itself fits 85% of the frame")
        XCTAssertGreaterThanOrEqual(long.origin.x, 0)
    }

    /// The bundled Source Han Sans is what draws, not a silent fallback (CLAUDE.md 字幕 / 许可与素材).
    func testBundledFontIsUsed() {
        XCTAssertTrue(SubtitleRenderer.fontRegistered)
        let font = CTFontCreateWithName(SubtitleRenderer.fontName as CFString, 40, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, "SourceHanSansCN-Bold")
        XCTAssertEqual(CTFontCopyFamilyName(font) as String, "Source Han Sans CN")
    }

    func testEmptyCueDrawsNothing() {
        XCTAssertNil(SubtitleRenderer.render([], frameWidth: 1920, frameHeight: 1080))
        XCTAssertNil(SubtitleRenderer.render([""], frameWidth: 1920, frameHeight: 1080))
    }
}
