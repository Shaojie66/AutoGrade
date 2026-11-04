import AppKit
import AutoGradeCore
import XCTest

/// The app's cover title path (CLAUDE.md 封面 / 版式), without the interface:
/// setting the title in `Project` redraws the preview with the title in it, and
/// the exported files carry the same pixels. Round 3 on the Air (2026-11-04)
/// saw no title after setting the text fields through accessibility; these
/// tests tell an app bug apart from a binding the accessibility value never reached.
@MainActor
final class CoverTitleAppTests: XCTestCase {
    let clip = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/synthetic_cover.mp4")
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("autograde-apptest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)   // this test's own temporary directory
    }

    /// Waits on the main actor until `condition` holds, or fails after `seconds`.
    private func wait(_ what: String, seconds: Double = 60, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { XCTFail("timed out waiting for \(what)"); throw XCTSkip("timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func bytes(_ image: NSImage?) throws -> [UInt8] {
        let cg = try XCTUnwrap(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let data = try XCTUnwrap(cg.dataProvider?.data) as Data
        return [UInt8](data)
    }

    /// The whole state path: open, find covers, select one, type a title.
    func testSettingTheTitleRedrawsThePreviewWithIt() async throws {
        let project = Project(stylesDirectory: nil)
        project.open(clip)
        try await wait("analysis") { project.phase == .ready }
        project.findCovers()
        try await wait("covers") { project.covers != nil && project.busy == nil }
        let first = try XCTUnwrap(project.covers?.first)
        project.selectCover(first.frame)
        try await wait("plain preview") { project.coverPreview != nil }
        let plain = try bytes(project.coverPreview)

        project.coverTitleText = "漫画封面"
        try await wait("titled preview") { (try? self.bytes(project.coverPreview)) != plain }
        let titled = try bytes(project.coverPreview)
        XCTAssertEqual(titled.count, plain.count, "same size: 3:4, 1080x1440")
        let changed = stride(from: 0, to: plain.count, by: 4).filter { titled[$0..<($0 + 3)] != plain[$0..<($0 + 3)] }.count
        print("cover title in the app preview: \(changed) pixels changed")
        XCTAssertGreaterThan(changed, 1000, "the title is drawn into the preview")

        // a layout change moves it; clearing the title brings the plain cover back
        project.coverTemplate = .center
        try await wait("centre layout") { (try? self.bytes(project.coverPreview)) != titled }
        project.coverTitleText = ""
        try await wait("title cleared") { (try? self.bytes(project.coverPreview)) == plain }
    }

    /// The engine the app uses: the preview with a title is what the file holds.
    func testExportedCoverHoldsThePreviewedTitle() async throws {
        let engine = try Engine(stylesDirectory: nil)
        _ = try await engine.open(clip, style: StyleCatalog.builtinID) { _ in }
        let summary = try await engine.scanCovers { _ in }
        let c = try XCTUnwrap(summary.covers?.first)
        let title = CoverTitle(title: "漫画封面", subtitle: "第二行", template: .bottom)

        let (plainImage, _) = try await engine.coverPreview(c, aspect: .portrait3x4, title: nil)
        let (titledImage, _) = try await engine.coverPreview(c, aspect: .portrait3x4, title: title)
        let plain = try bytes(NSImage(cgImage: plainImage.value, size: .zero))
        let titled = try bytes(NSImage(cgImage: titledImage.value, size: .zero))
        XCTAssertNotEqual(plain, titled, "the title changes the preview")

        let checks = try await engine.exportCovers([(1, c)], aspects: [.portrait3x4], format: .png, title: title, to: dir) { _ in }
        XCTAssertEqual(checks.count, 1)
        XCTAssertTrue(checks[0].passed, "\(checks[0].failures)")
        let file = try XCTUnwrap(CoverWriter.readRGB(checks[0].url))
        XCTAssertEqual([file.width, file.height], [1080, 1440])
        // the file's RGB is the titled preview's BGRA, sample for sample
        var mismatched = 0, fromPlain = 0
        for i in 0..<(file.width * file.height) {
            for (c, byte) in [(0, 2), (1, 1), (2, 0)] {
                if file.rgb[i * 3 + c] != titled[i * 4 + byte] { mismatched += 1 }
                if file.rgb[i * 3 + c] != plain[i * 4 + byte] { fromPlain += 1 }
            }
        }
        XCTAssertEqual(mismatched, 0, "the exported cover is the previewed one")
        XCTAssertGreaterThan(fromPlain, 1000, "and it has the title")
    }
}
