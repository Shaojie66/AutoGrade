import AutoGradeCore
import AVFoundation
import XCTest

/// The reframe crop path (a pure function, synthetic tracks) and subject
/// detection on a fixture with a known subject position (CLAUDE.md 重构图).
final class ReframeTests: XCTestCase {
    let fps = 30
    func times(_ n: Int) -> [CMTime] { (0..<n).map { CMTime(value: CMTimeValue($0), timescale: CMTimeScale(fps)) } }

    /// A track with the subject at normalised x = `x(frame)` (y fixed at 0.5).
    func track(_ n: Int, _ x: (Int) -> Float?) -> SubjectTrack {
        SubjectTrack(samples: (0..<n).map { f in x(f).map { .init(center: SIMD2($0, 0.5), size: SIMD2(0.1, 0.2), source: .face) } })
    }

    func path(_ t: SubjectTrack, shots: [Shot], width: Int = 1920, height: Int = 1080, aspect: Aspect = .vertical9x16,
              overrides: [Float?]? = nil) -> CropPath {
        Reframe.path(track: t, shots: shots, frameTimes: times(t.samples.count), width: width, height: height,
                     aspect: aspect, overrides: overrides ?? Array(repeating: nil, count: shots.count))
    }

    // MARK: geometry

    func testCropGeometry() {
        XCTAssertEqual(Aspect.vertical9x16.crop(width: 1920, height: 1080).length, SIMD2(607.5, 1080))
        XCTAssertEqual(Aspect.vertical9x16.crop(width: 1920, height: 1080).axis, 0)
        XCTAssertEqual(Aspect.horizontal16x9.crop(width: 1080, height: 1920).length, SIMD2(1080, 607.5))
        XCTAssertEqual(Aspect.horizontal16x9.crop(width: 1080, height: 1920).axis, 1)
        // narrower than 9:16 already: crop the height instead
        XCTAssertEqual(Aspect.vertical9x16.crop(width: 1080, height: 2400).length, SIMD2(1080, 1920))
        XCTAssertEqual(Aspect.vertical9x16.outputSize.width, 1080)
        XCTAssertEqual(Aspect.horizontal16x9.outputSize.height, 1080)
    }

    // MARK: path

    func testStillSubjectGivesAFixedCrop() {
        let p = path(track(90) { 0.3 + 0.01 * sin(Float($0)) }, shots: [Shot(first: 0, last: 89)])
        XCTAssertEqual(p.modes, [.fixed])
        XCTAssertEqual(Set(p.centers).count, 1, "one position for the whole shot")
        XCTAssertEqual(p.centers[0], 0.3, accuracy: 0.011)
    }

    func testMovingSubjectIsFollowedWithoutLag() {
        // 0.35 -> 0.65 over 3 s: 192 px/s, under the 0.6 crop/s limit (364 px/s)
        let x: (Int) -> Float = { 0.35 + 0.3 * Float($0) / 89 }
        let p = path(track(90, x), shots: [Shot(first: 0, last: 89)])
        XCTAssertEqual(p.modes, [.follow])
        var worst: Float = 0
        for f in 0..<90 { worst = max(worst, abs(p.centers[f] - x(f)) * 1920) }
        print("follow: worst lag over the whole shot \(worst) px")
        XCTAssertLessThanOrEqual(worst, 2)
    }

    func testANoisyFirstFrameDoesNotPinThePath() {
        // a steady pan, but the detector is far off on the shot's first frame
        let x: (Int) -> Float = { $0 == 0 ? 0.9 : 0.3 + 0.3 * Float($0) / 89 }
        let p = path(track(90, x), shots: [Shot(first: 0, last: 89)])
        XCTAssertEqual(p.modes, [.follow])
        let startError = abs(p.centers[0] - 0.3) * 1920, endError = abs(p.centers[89] - 0.6) * 1920
        print("noisy first frame: start off by \(startError) px, end off by \(endError) px")
        // 196 px when the ends were anchored by least squares, 42 px with Theil-Sen: what is
        // left is that sample's own weight in the Gaussian (~3%), as anywhere mid-shot
        XCTAssertLessThanOrEqual(startError, 50, "one bad sample pulls the start by under 1/12 of a crop")
        XCTAssertLessThanOrEqual(endError, 2)
    }

    func testSpeedIsLimitedAndJitterSmoothed() {
        // a fast swing plus frame-to-frame jitter
        var seed: UInt64 = 7                                   // deterministic: a fixed LCG
        let noise = (0..<120).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24) * 0.08 - 0.04
        }
        let raw: (Int) -> Float = { 0.5 + 0.35 * sin(Float($0) / 8) + noise[$0] }
        let p = path(track(120, raw), shots: [Shot(first: 0, last: 119)])
        XCTAssertEqual(p.modes, [.follow])
        let px = p.centers.map { $0 * 1920 }
        let speed = zip(px, px.dropFirst()).map { abs($1 - $0) }.max()!
        let limit = Reframe.maxSpeed * 607.5 / Float(fps)
        func accel(_ v: [Float]) -> Float { (1..<v.count - 1).map { abs(v[$0 + 1] - 2 * v[$0] + v[$0 - 1]) }.max()! }
        let rawAccel = accel((0..<120).map { raw($0) * 1920 }), pathAccel = accel(px)
        print("speed max \(speed) px/frame (limit \(limit)); accel path \(pathAccel) vs raw \(rawAccel)")
        XCTAssertLessThanOrEqual(speed, limit + 1e-3)
        XCTAssertLessThanOrEqual(pathAccel, 0.01 * rawAccel, "turns are rounded, not taken at full speed")
    }

    func testEachShotStartsAfresh() {
        let p = path(track(60) { $0 < 30 ? 0.2 : 0.8 }, shots: [Shot(first: 0, last: 29), Shot(first: 30, last: 59)])
        XCTAssertEqual(p.modes, [.fixed, .fixed])
        XCTAssertEqual(p.centers[29], 0.2, accuracy: 1e-4, "no smoothing across the cut")
        XCTAssertEqual(p.centers[30], 0.8, accuracy: 1e-4)
    }

    func testShortShotsShareTheirNeighboursPath() {
        // an over-cut clip: 1-frame "shots" around two real ones (CLAUDE.md 已知坑)
        // whose own detections are off (0.6): alone, each would get its own crop
        let shots = [Shot(first: 0, last: 0), Shot(first: 1, last: 59), Shot(first: 60, last: 60),
                     Shot(first: 61, last: 61), Shot(first: 62, last: 119)]
        let shortFrames: Set = [0, 60, 61]
        let p = path(track(120) { shortFrames.contains($0) ? 0.6 : $0 < 62 ? 0.2 : 0.8 }, shots: shots)
        XCTAssertEqual(p.modes.count, 5)
        XCTAssertTrue(p.centers[0...61].allSatisfy { abs($0 - 0.2) < 1e-4 }, "short shots ride with shot 1, no per-frame jumps")
        XCTAssertTrue(p.centers[62...].allSatisfy { abs($0 - 0.8) < 1e-4 })
    }

    func testCropStaysInsideTheFrame() {
        // a sweep faster than the speed limit, edge to edge
        let p = path(track(90) { 0.02 + 0.96 * Float($0) / 89 }, shots: [Shot(first: 0, last: 89)])
        for o in p.origins {
            XCTAssertGreaterThanOrEqual(o.x, 0)
            XCTAssertLessThanOrEqual(o.x + 607.5, 1920 + 1e-3)
            XCTAssertEqual(o.y, 0)
        }
        // a subject at the very edge: the crop stops half a crop from it
        let edge = path(track(30) { _ in 0.02 }, shots: [Shot(first: 0, last: 29)])
        XCTAssertEqual(edge.centers[0], 303.75 / 1920, accuracy: 1e-5)
    }

    func testManualShotIsFixedWhereDragged() {
        let p = path(track(60) { _ in 0.2 }, shots: [Shot(first: 0, last: 29), Shot(first: 30, last: 59)], overrides: [nil, 0.7])
        XCTAssertEqual(p.modes, [.fixed, .manual])
        XCTAssertEqual(p.centers[0], 0.2, accuracy: 1e-5)
        XCTAssertTrue(p.centers[30...].allSatisfy { abs($0 - 0.7) < 1e-5 })
    }

    func testNothingFoundCentresTheCrop() {
        let p = path(track(30) { _ in nil }, shots: [Shot(first: 0, last: 29)])
        XCTAssertEqual(p.modes, [.fixed])
        XCTAssertEqual(p.centers[0], 0.5, accuracy: 1e-5)
    }

    func testPortraitTo16x9SlidesVertically() {
        let p = path(track(30) { _ in 0.5 }, shots: [Shot(first: 0, last: 29)], width: 1080, height: 1920, aspect: .horizontal16x9)
        XCTAssertEqual(p.axis, 1)
        XCTAssertEqual(p.origins[0].x, 0)
    }

    // MARK: detection

    func testDetectionFindsTheMovingDisk() throws {
        let engine = try AutoGrader(stylesDirectory: nil)
        let url = Fixtures.url("synthetic_subject.mp4")
        let analysis = try engine.analyze(url, lutSize: 17, cutThreshold: 3)
        let t = try engine.detectSubjects(url, analysis: analysis)
        XCTAssertEqual(t.samples.count, 90)
        var found = 0, worst: Float = 0
        for (f, s) in t.samples.enumerated() {
            guard let s else { continue }
            found += 1
            let truth = 60 + 60 * Float(f) / 30          // px, from make_fixtures.make_subject
            worst = max(worst, abs(s.center.x * 320 - truth))
        }
        print("detection: \(found)/90 frames, worst |x error| \(worst) px (disk radius 20), "
              + "faces \(t.count(.face)) humans \(t.count(.human)) saliency \(t.count(.saliency)), \(t.seconds) s")
        XCTAssertGreaterThanOrEqual(found, 81, "at least 90% of frames")
        XCTAssertLessThanOrEqual(worst, 20)
    }
}
