import AutoGradeCore
import AVFoundation
import Metal
import XCTest

/// The preview's on-screen picture: the split-selected preview pixels as a
/// '420v' BT.709 frame carrying the decoder's own attachments (CLAUDE.md 架构原则 5).
final class DisplayFrameTests: XCTestCase {
    func testDisplayFrameIsDecoderShapedAndCarriesTheRightPixels() throws {
        let engine = try AutoGrader()
        let synthetic = Fixtures.url("synthetic_shots.mp4")
        let analysis = try engine.analyze(synthetic, lutSize: 33, cutThreshold: Fixtures.manifest.cut_threshold)
        let w = analysis.info.width, h = analysis.info.height
        let decoded = try engine.decodeFrame(synthetic, analysis: analysis, index: 40)
        let targets = try PreviewTargets(kernels: engine.kernels, width: w, height: h)
        try engine.preview(decoded, lut: analysis.luts[1], into: targets)
        let original = bytes(targets.original), graded = bytes(targets.graded)
        XCTAssertNotEqual(original, graded, "the shot LUT changes the picture")

        let maker = try DisplayFrameMaker(kernels: engine.kernels, width: w, height: h)
        let split = 0.3, column = Int((split * Double(w) / 2).rounded()) * 2
        for layout in [CompareLayout.split, .original, .graded] {
            let pb = try maker.pixelBuffer(original: targets.original, graded: targets.graded, split: split, layout: layout)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(pb), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            func source(_ x: Int) -> [UInt8] { (layout == .original || (layout == .split && x < column)) ? original : graded }

            // Luma: exactly the BT.709 limited code of the selected source pixel.
            let y = plane(pb, 0)
            var off = 0, offBy2 = 0
            for row in 0..<h {
                for x in 0..<w {
                    let s = source(x), i = (row * w + x) * 4
                    let l = 0.2126 * Double(s[i + 2]) / 255 + 0.7152 * Double(s[i + 1]) / 255 + 0.0722 * Double(s[i]) / 255
                    let d = abs(Int(y[row * w + x]) - Int((16 + 219 * l).rounded(.toNearestOrEven)))
                    if d > 0 { off += 1 }
                    if d > 1 { offBy2 += 1 }
                }
            }
            print("display luma \(layout): \(off) codes off by 1, \(offBy2) by more")
            XCTAssertEqual(offBy2, 0, "\(layout)")
            XCTAssertLessThan(Double(off) / Double(w * h), 0.001, "float rounding only at .5 ties")

            // Colour: decoding it with our own convention gives the source back without bias.
            let back = try engine.kernels.yuvToRGB(luma: try texture(pb, 0, .r8Unorm, engine), chroma: try texture(pb, 1, .rg8Unorm, engine)).floats()
            var bias = [0.0, 0.0, 0.0]
            for i in 0..<(w * h) {
                let s = source(i % w)
                for (c, byte) in [(0, 2), (1, 1), (2, 0)] { bias[c] += Double(quantize8(back[c * w * h + i])) - Double(s[i * 4 + byte]) }
            }
            bias = bias.map { $0 / Double(w * h) }
            print(String(format: "display round trip %@: bias R %+.2f G %+.2f B %+.2f", "\(layout)", bias[0], bias[1], bias[2]))
            for b in bias { XCTAssertLessThan(abs(b), 1.0, "\(layout)") }

            // Tags spelled out here, not read from DisplayFrameMaker (a test that iterates
            // the table under test cannot notice an entry going missing).
            let expected: [(CFString, CFString)] = [
                (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
                (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
                (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left),
                (kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left),
            ]
            for (key, value) in expected {
                XCTAssertEqual(CVBufferCopyAttachment(pb, key, nil) as? String, value as String, "\(key)")
            }
            // The colour space must be the one the decoder gives QuickTime for the same file type.
            let ours = CVBufferCopyAttachment(pb, kCVImageBufferCGColorSpaceKey, nil).map { $0 as! CGColorSpace }
            let decoders = CVBufferCopyAttachment(decoded.pixelBuffer, kCVImageBufferCGColorSpaceKey, nil).map { $0 as! CGColorSpace }
            XCTAssertNotNil(decoders, "the decoder attaches a colour space")
            XCTAssertEqual(ours?.name as String?, decoders?.name as String?)
            XCTAssertEqual(ours?.copyICCData() as Data?, decoders?.copyICCData() as Data?)
        }
        let sample = try maker.sampleBuffer(original: targets.original, graded: targets.graded, split: split, layout: .split)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        XCTAssertEqual(attachments?.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool, true)
    }

    private func bytes(_ t: MTLTexture) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: t.width * t.height * 4)
        t.getBytes(&out, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        return out
    }

    private func plane(_ pb: CVPixelBuffer, _ p: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, p) * (p == 0 ? 1 : 2), h = CVPixelBufferGetHeightOfPlane(pb, p)
        let row = CVPixelBufferGetBytesPerRowOfPlane(pb, p)
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, p)!.assumingMemoryBound(to: UInt8.self)
        return (0..<h).flatMap { y in Array(UnsafeBufferPointer(start: base + y * row, count: w)) }
    }

    private func texture(_ pb: CVPixelBuffer, _ p: Int, _ format: MTLPixelFormat, _ engine: AutoGrader) throws -> MTLTexture {
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, engine.metal.device, nil, &cache)
        var tex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache!, pb, nil, format, CVPixelBufferGetWidthOfPlane(pb, p),
                                                  CVPixelBufferGetHeightOfPlane(pb, p), p, &tex)
        textureRefs.append(tex!)
        return CVMetalTextureGetTexture(tex!)!
    }
    private var textureRefs: [CVMetalTexture] = []
}
