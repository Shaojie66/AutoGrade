// Render FiveK DNGs to 8-bit sRGB PNG, short side 480 — the training inputs.
//
//   swift research/train/render_dng.swift research/data/fivek-dng research/data/fivek-srgb480
//
// macOS Core Image RAW (CIRAWFilter) with the camera's as-shot white balance
// and the default exposure/boost: an ungraded rendition, no look applied
// (CLAUDE.md, research/data/fivek-srgb480). Upstream's 480p set was exported
// from Lightroom instead, so pixels differ; only "ungraded input" matters here.
// Existing outputs are kept, so the script can be rerun after more downloads.
import CoreImage
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: render_dng.swift <dng dir> <png out dir>\n".utf8))
    exit(2)
}
let src = URL(fileURLWithPath: args[1]), dst = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CIContext(options: [.outputColorSpace: srgb])
let files = try FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension.lowercased() == "dng" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

var rendered = 0, kept = 0, failed: [String] = []
for url in files {
    let code = String(url.deletingPathExtension().lastPathComponent.prefix(5))   // a0001
    let out = dst.appendingPathComponent("\(code).png")
    if FileManager.default.fileExists(atPath: out.path) { kept += 1; continue }
    guard let raw = CIRAWFilter(imageURL: url), let image = raw.outputImage else {
        failed.append(url.lastPathComponent); continue
    }
    let scale = 480.0 / min(image.extent.width, image.extent.height)
    let lanczos = CIFilter(name: "CILanczosScaleTransform")!
    lanczos.setValue(image, forKey: kCIInputImageKey)
    lanczos.setValue(scale, forKey: kCIInputScaleKey)
    lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
    guard var small = lanczos.outputImage else { failed.append(url.lastPathComponent); continue }
    small = small.cropped(to: small.extent.integral)
    do {
        try context.writePNGRepresentation(of: small, to: out, format: .RGBA8, colorSpace: srgb)
        rendered += 1
    } catch {
        failed.append("\(url.lastPathComponent): \(error)")
    }
    if (rendered + kept) % 100 == 0 { print("\(rendered + kept)/\(files.count)") }
}
print("rendered \(rendered), kept \(kept), failed \(failed.count) of \(files.count) DNGs")
for f in failed { print("failed: \(f)") }
exit(failed.isEmpty ? 0 : 1)
