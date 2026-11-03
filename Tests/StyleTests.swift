import AutoGradeCore
import Metal
import XCTest

/// Returns the same AiLUT (fixture `demo`) for every frame, so a shot graded
/// in this style has a known LUT: bake(demo AiLUT). No trained weights needed.
final class FixedPredictor: LUTPredictor, @unchecked Sendable {
    let ai: AiLUT
    init(kernels: GradeKernels) throws { ai = try Fixtures.aiLUT("demo", kernels: kernels) }
    func predict(_ resized: PlanarImage) throws -> AiLUT { ai }
}

/// Styles in the Core (CLAUDE.md, 风格): the catalog, and the edits that
/// re-analyse only what a style change touches.
final class StyleTests: XCTestCase {
    static let fixed = Style(id: "fixed", nameEN: "Fixed \"demo\"", nameZH: "固定",
                             license: "test only; fine-tuned toward a look (CC BY-SA 4.0).")
    var engine: AutoGrader!
    var kernels: GradeKernels { engine.kernels }
    var expected: [Float]!          // clamp(bake(demo AiLUT)): any shot graded in "fixed"
    let synthetic = Fixtures.url("synthetic_shots.mp4")

    override func setUpWithError() throws {
        let k = GradeKernels(metal: try MetalContext())
        engine = try AutoGrader(stylesDirectory: nil, extraStyles: [(Self.fixed, try FixedPredictor(kernels: k))])
        // clamp(bake): a shot LUT is the clamped mean (CLAUDE.md 每镜头 LUT); mean over one frame clamps
        expected = try kernels.mean(try kernels.bake(try Fixtures.aiLUT("demo", kernels: kernels), size: 33), frames: 1).floats()
    }

    private func analyze(style: String = StyleCatalog.builtinID) throws -> Analysis {
        let a = try engine.analyze(synthetic, lutSize: 33, cutThreshold: Fixtures.manifest.cut_threshold, style: style)
        XCTAssertEqual(a.shots, [Shot(first: 0, last: 29), Shot(first: 30, last: 59), Shot(first: 60, last: 89)])
        return a
    }

    private func assertFixed(_ a: Analysis, _ k: Int, file: StaticString = #filePath, line: UInt = #line) {
        let err = maxAbsDifference(a.luts[k].floats(), expected)
        print("shot \(k) vs bake(fixed): max \(err)")
        XCTAssertLessThanOrEqual(err, 1e-6, "shot \(k)", file: file, line: line)
    }

    // MARK: edits

    func testRestyleOneShotTouchesOnlyThatShot() throws {
        let three = try analyze()
        let r = try engine.restyle(three, source: synthetic, shots: 1...1, to: "fixed")
        XCTAssertEqual(r.shots, three.shots)
        XCTAssertEqual(r.styles, ["fivek", "fixed", "fivek"])
        assertFixed(r, 1)
        for k in [0, 2] {
            XCTAssertEqual(r.luts[k].floats(), three.luts[k].floats(), "shot \(k) unchanged")
            XCTAssertEqual(r.sums[k].floats(), three.sums[k].floats(), "shot \(k) sum unchanged")
        }
    }

    func testRestyleAllKeepsCutsAndRoundTrips() throws {
        let four = try engine.addCut(try analyze(), source: synthetic, atFrame: 45)   // a manual cut detection would not make
        let all = try engine.restyle(four, source: synthetic, shots: 0...3, to: "fixed")
        XCTAssertEqual(all.shots, four.shots, "cuts stay where they are")
        XCTAssertEqual(all.styles, Array(repeating: "fixed", count: 4))
        for k in 0..<4 { assertFixed(all, k) }

        let back = try engine.restyle(all, source: synthetic, shots: 0...3, to: "fivek")
        for k in 0..<4 {
            let err = maxAbsDifference(back.luts[k].floats(), four.luts[k].floats())
            print("restyle round trip shot \(k): max \(err)")
            XCTAssertLessThanOrEqual(err, 1e-6)
        }
    }

    func testAnalyzeInAStyle() throws {
        let a = try analyze(style: "fixed")
        XCTAssertEqual(a.styles, ["fixed", "fixed", "fixed"])
        for k in 0..<3 { assertFixed(a, k) }
    }

    func testAddCutKeepsTheShotStyle() throws {
        let mixed = try engine.restyle(try analyze(), source: synthetic, shots: 1...1, to: "fixed")
        let split = try engine.addCut(mixed, source: synthetic, atFrame: 45)
        XCTAssertEqual(split.shots.map(\.first), [0, 30, 45, 60])
        XCTAssertEqual(split.styles, ["fivek", "fixed", "fixed", "fivek"])
        assertFixed(split, 1)
        assertFixed(split, 2)
    }

    func testRemoveCutAcrossStylesTakesTheEarlierStyle() throws {
        let three = try analyze()
        let mixed = try engine.restyle(three, source: synthetic, shots: 1...1, to: "fixed")

        // fivek | fixed -> fivek: the fixed shot is re-analysed in FiveK, so the
        // result equals merging the all-FiveK analysis.
        let a = try engine.removeCut(mixed, beforeShot: 1, source: synthetic)
        XCTAssertEqual(a.styles, ["fivek", "fivek"])
        let reference = try engine.removeCut(three, beforeShot: 1, source: synthetic)
        let err = maxAbsDifference(a.luts[0].floats(), reference.luts[0].floats())
        print("cross-style removeCut vs same-style: max \(err)")
        XCTAssertLessThanOrEqual(err, 1e-6)

        // fixed | fivek -> fixed: the merged shot is entirely the fixed style.
        let b = try engine.removeCut(mixed, beforeShot: 2, source: synthetic)
        XCTAssertEqual(b.shots, [Shot(first: 0, last: 29), Shot(first: 30, last: 89)])
        XCTAssertEqual(b.styles, ["fivek", "fixed"])
        assertFixed(b, 1)
    }

    func testCancelledRestyleLeavesTheAnalysisAsItWas() throws {
        let three = try analyze()
        let token = CancelToken()
        token.cancel()
        XCTAssertThrowsError(try engine.restyle(three, source: synthetic, shots: 0...2, to: "fixed", cancel: token)) { error in
            XCTAssertTrue(error is Cancelled, "\(error)")
        }
        // The edit returns a new Analysis or nothing: the old one is still FiveK, byte for byte.
        XCTAssertEqual(three.styles, ["fivek", "fivek", "fivek"])
        let again = try analyze()
        for k in 0..<3 { XCTAssertEqual(three.luts[k].floats(), again.luts[k].floats(), "shot \(k)") }
    }

    func testUnknownStyleFailsBeforeAnyWork() throws {
        XCTAssertThrowsError(try engine.analyze(synthetic, lutSize: 33, style: "nope")) { error in
            XCTAssertEqual("\(error)", "no style \"nope\" is installed")
        }
        let three = try analyze()
        XCTAssertThrowsError(try engine.restyle(three, source: synthetic, shots: 0...0, to: "nope"))
    }

    func testCubeTitleNamesStyleAndLicence() throws {
        let mixed = try engine.restyle(try analyze(), source: synthetic, shots: 1...1, to: "fixed")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("autograde-styletests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }   // this test's own temporary directory
        let urls = try engine.writeCubes(mixed, luts: mixed.luts, to: dir, prefix: "synthetic")
        let titles = try urls.map { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n")[0] }
        XCTAssertEqual(titles[0], "TITLE \"AutoGrade synthetic shot 0 (frames 0-29), style FiveK [fivek]: research use only, non-commercial\"")
        XCTAssertEqual(titles[1], "TITLE \"AutoGrade synthetic shot 1 (frames 30-59), style Fixed 'demo' [fixed]: "
                       + "research use only, non-commercial; film look CC BY-SA 4.0\"")
    }

    // MARK: catalog

    func testCatalogLoadsInstalledModelsAndSkipsBrokenOnes() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("autograde-styles-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }   // this test's own temporary directory
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let builtin = try Grader.builtinModelURL()
        try fm.copyItem(at: builtin, to: dir.appendingPathComponent("teststyle.mlmodelc"))
        try fm.copyItem(at: builtin, to: dir.appendingPathComponent("fivek.mlmodelc"))       // reserved id
        try fm.createDirectory(at: dir.appendingPathComponent("broken.mlmodelc"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("notes.txt"))                         // not a model

        let catalog = try StyleCatalog(kernels: kernels, directory: dir)
        XCTAssertEqual(catalog.styles.map(\.id), ["fivek", "teststyle"])
        XCTAssertEqual(catalog.warnings.count, 2, "\(catalog.warnings)")
        XCTAssertEqual(catalog.style("teststyle")?.nameEN, "teststyle", "no names in the metadata: the id")

        // Same weights through the installed-model path: identical output.
        let resized = try kernels.makeImage(width: 256, height: 256, floats: try Fixtures.floats("demo_resized256").values)
        let a = try catalog.predictor("fivek").predict(resized), b = try catalog.predictor("teststyle").predict(resized)
        XCTAssertEqual(try kernels.bake(a, size: 17).floats(), try kernels.bake(b, size: 17).floats())
        XCTAssertThrowsError(try catalog.predictor("broken"))

        let none = try StyleCatalog(kernels: kernels, directory: dir.appendingPathComponent("missing"))
        XCTAssertEqual(none.styles.map(\.id), ["fivek"])
        XCTAssertTrue(none.warnings.isEmpty)
    }
}

/// Every style installed on this machine (Tools/install-style.sh) against the
/// PyTorch outputs convert_coreml.py stored beside it: the same 1e-4 the
/// built-in model is held to (CLAUDE.md 容差表). Skips when none is installed;
/// report the skip (CLAUDE.md: "0 failures" is not "tested").
final class StyleParityTests: XCTestCase {
    struct Reference: Decodable {
        struct File: Decodable { let file: String; let shape: [Int]; let sha256: String }
        let inputs: [String: String]
        let files: [String: File]
    }

    func testInstalledStylesMatchPyTorch() throws {
        let kernels = GradeKernels(metal: try MetalContext())
        let catalog = try StyleCatalog(kernels: kernels, directory: StyleCatalog.defaultDirectory)
        let dir = try XCTUnwrap(catalog.directory)
        var checked = 0
        for style in catalog.styles where !style.isBuiltin {
            let ref = dir.appendingPathComponent("\(style.id).reference")
            guard let json = try? Data(contentsOf: ref.appendingPathComponent("reference.json")) else {
                XCTFail("\(style.id): installed without reference data")
                continue
            }
            let doc = try JSONDecoder().decode(Reference.self, from: json)
            let grader = try catalog.predictor(style.id)
            for (name, inputSHA) in doc.inputs.sorted(by: { $0.key < $1.key }) {
                XCTAssertEqual(inputSHA, Fixtures.manifest.files["\(name)_resized256"]?.sha256,
                               "\(style.id): reference made from different fixtures; reconvert")
                let resized = try kernels.makeImage(width: 256, height: 256,
                                                    floats: try Fixtures.floats("\(name)_resized256").values)
                let ai = try grader.predict(resized)
                func load(_ key: String) throws -> [Float] {
                    let entry = try XCTUnwrap(doc.files["\(name)_\(key)"])
                    let data = try Data(contentsOf: ref.appendingPathComponent(entry.file))
                    XCTAssertEqual(sha256(data), entry.sha256)
                    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                }
                let n = 3 * 33 * 33 * 33
                let lut = Array(UnsafeBufferPointer(start: ai.lut.contents().bindMemory(to: Float.self, capacity: n), count: n))
                let ver = Array(UnsafeBufferPointer(start: ai.vertices.contents().bindMemory(to: Float.self, capacity: 99), count: 99))
                let errLUT = maxAbsDifference(lut, try load("lut")), errVer = maxAbsDifference(ver, try load("vertices"))
                print("style \(style.id) \(name): lut max \(errLUT), vertices max \(errVer)")
                XCTAssertLessThanOrEqual(errLUT, 1e-4, "\(style.id) \(name)")
                XCTAssertLessThanOrEqual(errVer, 1e-4, "\(style.id) \(name)")
            }
            checked += 1
        }
        print("style parity: \(checked) installed styles checked in \(dir.path)")
        if checked == 0 { throw XCTSkip("no styles installed in \(dir.path)") }
    }
}
