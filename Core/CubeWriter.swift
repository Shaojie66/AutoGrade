import Foundation

/// Writes a LUT3D as Adobe/Resolve `.cube` text: TITLE, LUT_3D_SIZE, then one
/// "r g b" row per lattice point with r fastest, "%.6f". Byte-identical to
/// research/make_fixtures.py::cube_text for the same floats (CubeWriterTests).
/// Values are clamped to [0,1]; a shot LUT already is (CLAUDE.md 架构原则 4).
public enum CubeWriter {
    public static func text(_ lut: LUT3D, title: String) -> String {
        let n = lut.size, n3 = n * n * n
        let values = lut.floats()
        var out = "TITLE \"\(title)\"\nLUT_3D_SIZE \(n)\n"
        out.reserveCapacity(out.utf8.count + n3 * 27)
        for i in 0..<n3 {   // i = (b*n + g)*n + r: memory order is already r-fastest
            let r = Double(min(max(values[i], 0), 1))
            let g = Double(min(max(values[i + n3], 0), 1))
            let b = Double(min(max(values[i + 2 * n3], 0), 1))
            out += String(format: "%.6f %.6f %.6f\n", r, g, b)
        }
        return out
    }

    public static func write(_ lut: LUT3D, title: String, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw VideoError.writer("\(url.path) already exists (refusing to overwrite)")
        }
        try text(lut, title: title).write(to: url, atomically: true, encoding: .utf8)
    }
}
