import Foundation

/// First-version cut detector (CLAUDE.md, 已知坑): an 8x8x8 colour histogram of
/// a 160x90 bilinear thumbnail, and a cut wherever the L1 distance to the
/// previous frame exceeds `threshold`. Mirrors research/make_fixtures.py::histogram.
/// Known weakness: low-saturation footage (ink-wash) needs ~0.25, not 0.5.
public struct ShotDetector {
    public static let thumbnailWidth = 160
    public static let thumbnailHeight = 90
    public static let defaultThreshold: Float = 0.25

    public let threshold: Float
    private var previous: [Float]?

    public init(threshold: Float = ShotDetector.defaultThreshold) {
        self.threshold = threshold
    }

    /// Feed frames in order; returns true when `thumbnail` starts a new shot.
    /// `thumbnail` is planar float[3][90][160].
    public mutating func isCut(thumbnail: [Float]) -> Bool {
        let h = Self.histogram(thumbnail)
        defer { previous = h }
        guard let previous else { return false }
        var distance: Float = 0
        for i in 0..<h.count { distance += abs(h[i] - previous[i]) }
        return distance > threshold
    }

    static func histogram(_ planar: [Float]) -> [Float] {
        let n = planar.count / 3
        var counts = [Float](repeating: 0, count: 512)
        @inline(__always) func bin(_ v: Float) -> Int { Int(min(max(v, 0), 1) * 7.999) }   // truncation, as .long()
        for i in 0..<n {
            counts[bin(planar[i]) * 64 + bin(planar[i + n]) * 8 + bin(planar[i + 2 * n])] += 1
        }
        let total = Float(n)
        return counts.map { $0 / total }
    }
}
