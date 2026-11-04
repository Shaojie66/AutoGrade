import AutoGradeCore
import XCTest

/// Playback scheduling (CLAUDE.md 画质增强 / App: playback).
final class PlaybackClockTests: XCTestCase {
    let frame = 1.0 / 30

    func testStartsWhenTheFirstFrameIsReady() {
        var c = PlaybackClock()
        XCTAssertEqual(c.schedule(pts: 3.0, now: 10.5, slack: frame), 10.5, "a slow first frame is not late")
        XCTAssertEqual(c.schedule(pts: 3.0 + frame, now: 10.51, slack: frame)!, 10.5 + frame, accuracy: 1e-12)
    }

    func testDropsAFewLateFramesThenShowsAndRestarts() {
        var c = PlaybackClock()
        _ = c.schedule(pts: 0, now: 0, slack: frame)
        // every frame takes 50 ms to prepare: always later than one frame
        var shown: [Int] = []
        for i in 1...12 where c.schedule(pts: Double(i) * frame, now: Double(i) * 0.05 + 0.2, slack: frame) != nil { shown.append(i) }
        XCTAssertFalse(shown.isEmpty, "a machine that cannot keep up still shows frames")
        XCTAssertEqual(shown.first, 4, "three dropped, the fourth shown")
        for (a, b) in zip(shown, shown.dropFirst()) { XCTAssertLessThanOrEqual(b - a, PlaybackClock.maxConsecutiveDrops + 1) }
    }

    func testOnTimeFramesAreNeverDropped() {
        var c = PlaybackClock()
        for i in 0..<60 {
            let due = c.schedule(pts: Double(i) * frame, now: Double(i) * frame + 0.01, slack: frame)
            XCTAssertNotNil(due, "frame \(i)")
        }
    }

    func testAOneOffStallDropsOnlyWhileBehind() {
        var c = PlaybackClock()
        _ = c.schedule(pts: 0, now: 0, slack: frame)
        XCTAssertNil(c.schedule(pts: frame, now: 0.2, slack: frame))            // stalled 0.2 s
        XCTAssertNil(c.schedule(pts: 2 * frame, now: 0.2, slack: frame))
        XCTAssertNil(c.schedule(pts: 3 * frame, now: 0.2, slack: frame))
        XCTAssertEqual(c.schedule(pts: 4 * frame, now: 0.2, slack: frame), 0.2, "fourth late frame shown, clock restarts")
        XCTAssertEqual(c.schedule(pts: 5 * frame, now: 0.21, slack: frame)!, 0.2 + frame, accuracy: 1e-12)
    }
}
