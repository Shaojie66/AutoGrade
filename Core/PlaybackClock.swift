import Foundation

/// Playback's show-or-drop decision, frame by frame, in seconds. The clock
/// starts at the first frame that is ready (a denoised start prepares a
/// warm-up first). A frame more than `slack` late is dropped, but never more
/// than `maxConsecutiveDrops` in a row: then the late frame is shown and the
/// clock restarts from it, so a machine that cannot keep up plays slower
/// instead of showing nothing (2026-11-04, Air: every frame of an enhanced
/// playback was late and dropped, the picture never moved).
public struct PlaybackClock: Sendable {
    public static let maxConsecutiveDrops = 3
    private var anchor: (wall: Double, media: Double)?
    private var drops = 0

    public init() {}

    /// When to show the frame at media time `pts`, on the wall clock `now`
    /// (seconds); nil = drop it.
    public mutating func schedule(pts: Double, now: Double, slack: Double) -> Double? {
        guard let a = anchor else {
            anchor = (now, pts)
            return now
        }
        let due = a.wall + (pts - a.media)
        if now > due + slack {
            if drops < Self.maxConsecutiveDrops {
                drops += 1
                return nil
            }
            anchor = (now, pts)
            drops = 0
            return now
        }
        drops = 0
        return due
    }
}
