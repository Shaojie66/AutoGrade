import AutoGradeCore
import AVFoundation
import Metal
import XCTest

/// The encoded file must decode (with our own BT.709 convention) back to the
/// pixels we handed the encoder: only codec noise, no systematic shift. A
/// colour conversion inside the encoder shows up as a per-channel mean bias.
final class ExportRoundTripTests: XCTestCase {
    func testExportDecodesBackWithoutColourShift() throws {
        let engine = try AutoGrader(stylesDirectory: nil)
        let synthetic = Fixtures.url("synthetic_shots.mp4")
        let analysis = try engine.analyze(synthetic, lutSize: 33, cutThreshold: Fixtures.manifest.cut_threshold)
        let probe: Set = [15, 45, 75]
        var handed: [Int: [UInt8]] = [:]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("autograde-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }   // test's own temp directory
        let out = dir.appendingPathComponent("rt.mov")
        _ = try engine.render(synthetic, analysis: analysis, luts: analysis.luts, to: out, codec: .hevc,
                              frameHook: { i, pb in if probe.contains(i) { handed[i] = bgra(pb) } })

        let reader = try VideoReader(url: out, device: engine.metal.device)
        while let f = try reader.next() {
            guard probe.contains(f.index), let sent = handed[f.index] else { continue }
            let rgb = try engine.kernels.yuvToRGB(luma: f.luma, chroma: f.chroma).floats()
            let n = rgb.count / 3
            var bias = [0.0, 0.0, 0.0]                    // decoded - handed, in 8-bit levels, per R G B
            for i in 0..<n {
                for (c, byte) in [(0, 2), (1, 1), (2, 0)] {   // BGRA byte order
                    bias[c] += Double(quantize8(rgb[c * n + i])) - Double(sent[i * 4 + byte])
                }
            }
            bias = bias.map { $0 / Double(n) }
            print(String(format: "export round trip frame %d: mean bias R %+.2f G %+.2f B %+.2f levels",
                         f.index, bias[0], bias[1], bias[2]))
            // HEVC noise measured 0.04-0.71 levels (2026-11-02); an sRGB<->709 transfer
            // conversion shifts mid-tones by 5-15, so 1.5 separates the two with margin.
            for b in bias { XCTAssertLessThan(abs(b), 1.5, "frame \(f.index): encoder shifted colour") }
        }
    }
}

private func bgra(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    return (0..<h).flatMap { y in Array(UnsafeBufferPointer(start: base + y * row, count: w * 4)) }
}
