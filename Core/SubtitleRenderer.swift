import CoreGraphics
import CoreText
import Foundation

/// Rasterises a cue with CoreText (CLAUDE.md 字幕): white text, black stroke
/// (8% of the font size), a soft shadow, premultiplied sRGB RGBA8, placed for
/// the output frame. Drawn once per cue; `SubtitleBurn` caches the result.
public enum SubtitleRenderer {
    /// Source Han Sans CN Bold, shipped in the framework (SIL OFL 1.1; CLAUDE.md 字幕 / 许可与素材).
    public static let fontName = "SourceHanSansCN-Bold"
    public static let fontFile = "SourceHanSansCN-Bold.otf"

    /// Registers the bundled font for this process once (never system-wide).
    /// True when `fontName` resolves to the bundled font, not a fallback.
    public static let fontRegistered: Bool = {
        guard let url = Bundle(for: SubtitleBurn.self).url(forResource: fontFile, withExtension: nil) else { return false }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            // already registered by an earlier call in this process is fine
            if let e = error?.takeRetainedValue(), CFErrorGetCode(e) != CTFontManagerError.alreadyRegistered.rawValue { return false }
        }
        let font = CTFontCreateWithName(fontName as CFString, 12, nil)
        return CTFontCopyPostScriptName(font) as String == fontName
    }()
    public static let sizeFraction: CGFloat = 0.055         // of height (wide frames) or width (vertical)
    public static let bottomMargin: CGFloat = 0.08          // wide frames: bottom edge above the frame's
    public static let verticalCentre: CGFloat = 0.70        // 9:16: centre, clear of the platforms' UI
    public static let maxWidthFraction: CGFloat = 0.85
    static let strokePercent: CGFloat = 8
    static let lineSpacing: CGFloat = 1.25

    public struct Raster: Sendable {
        public let rgba: [UInt8]
        public let width: Int
        public let height: Int
        public let origin: SIMD2<Int32>        // top-left in the output frame
        public let fontSize: CGFloat
    }

    /// `vertical`: a 9:16 output (taller than wide).
    public static func render(_ lines: [String], frameWidth w: Int, frameHeight h: Int) -> Raster? {
        let text = lines.filter { !$0.isEmpty }
        guard !text.isEmpty, w > 0, h > 0 else { return nil }
        let vertical = h > w
        var size = (vertical ? CGFloat(w) : CGFloat(h)) * sizeFraction
        var built = layout(text, size: size)
        let maxWidth = CGFloat(w) * maxWidthFraction
        if built.width > maxWidth {                               // too wide: shrink to fit
            size *= maxWidth / built.width
            built = layout(text, size: size)
        }
        let pad = Int((size * strokePercent / 100 + size * 0.12).rounded(.up)) + 2
        let lineHeight = size * lineSpacing
        let bw = Int(built.width.rounded(.up)) + 2 * pad, bh = Int((lineHeight * CGFloat(text.count)).rounded(.up)) + 2 * pad
        let lines = built.fills.indices.map { i -> TextLine in
            let lw = CTLineGetTypographicBounds(built.fills[i], nil, nil, nil)
            // CoreGraphics is bottom-up: line i sits i lines below the top
            let baseline = CGFloat(bh) - CGFloat(pad) - lineHeight * CGFloat(i) - built.ascent - (lineHeight - built.ascent - built.descent) / 2
            return TextLine(fill: built.fills[i], stroke: built.strokes[i], position: CGPoint(x: (CGFloat(bw) - lw) / 2, y: baseline),
                            size: size)
        }
        let drawn = draw(lines, width: bw, height: bh)
        guard let rgba = drawn else { return nil }
        let x = (w - bw) / 2
        let y = vertical ? Int((CGFloat(h) * verticalCentre).rounded()) - bh / 2
                         : h - Int((CGFloat(h) * bottomMargin).rounded()) - bh
        return Raster(rgba: rgba, width: bw, height: bh, origin: SIMD2(Int32(x), Int32(y)), fontSize: size)
    }

    /// One line to draw: its white fill and black stroke, the baseline start in
    /// the bitmap (bottom-up), and its font size (the shadow scales with it).
    struct TextLine {
        let fill: CTLine
        let stroke: CTLine
        let position: CGPoint
        let size: CGFloat
    }

    /// Premultiplied sRGB RGBA8 of `lines`, shared by subtitles and cover titles.
    /// Two passes: the black stroke (with the shadow) first, the white fill on top, so
    /// the outline only shows outside the glyphs. One fill-and-stroke pass centres the
    /// stroke on the outline and its inner half covered thin CJK strokes black
    /// (2026-11-04: black text with a white rim).
    static func draw(_ lines: [TextLine], width bw: Int, height bh: Int) -> [UInt8]? {
        var rgba = [UInt8](repeating: 0, count: bw * bh * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: raw.baseAddress, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: bw * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            for strokePass in [true, false] {
                ctx.saveGState()
                for line in lines {
                    if strokePass {
                        ctx.setShadow(offset: CGSize(width: 0, height: -line.size * 0.04), blur: line.size * 0.12,
                                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5))
                    }
                    ctx.textPosition = line.position
                    CTLineDraw(strokePass ? line.stroke : line.fill, ctx)
                }
                ctx.restoreGState()
            }
            return true
        }
        return drawn ? rgba : nil
    }

    struct Layout {
        let fills: [CTLine]          // white, no stroke
        let strokes: [CTLine]        // black stroke only, twice the visible outline
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    static func layout(_ text: [String], size: CGFloat) -> Layout {
        _ = fontRegistered
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let fill: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
        // positive width: stroke only, centred on the outline, so half of it shows outside
        let stroke: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): 2 * strokePercent,
        ]
        let fills = text.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: fill)) }
        let strokes = text.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: stroke)) }
        let width = fills.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        return Layout(fills: fills, strokes: strokes, width: width + size * strokePercent / 100,
                      ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font))
    }
}

/// The cues to burn into one export (or preview) at one output size, each
/// rasterised once and kept on the GPU (CLAUDE.md 字幕).
public final class SubtitleBurn: @unchecked Sendable {
    public let cues: [SubtitleCue]
    public let width: Int
    public let height: Int
    private let kernels: GradeKernels
    private var cache: [Int: (OverlayImage, SIMD2<Int32>)?] = [:]
    private let lock = NSLock()

    public init(cues: [SubtitleCue], width: Int, height: Int, kernels: GradeKernels) {
        self.cues = cues
        self.width = width
        self.height = height
        self.kernels = kernels
    }

    /// The index of the cue on screen at `seconds`, if any.
    public func cueIndex(at seconds: Double) -> Int? { Subtitles.cue(at: seconds, in: cues) }

    /// The rasterised cue on screen at `seconds` and its top-left, if any.
    public func overlay(at seconds: Double) throws -> (OverlayImage, SIMD2<Int32>)? {
        guard let k = cueIndex(at: seconds) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[k] { return hit }
        let made = try SubtitleRenderer.render(cues[k].lines, frameWidth: width, frameHeight: height).map {
            (try kernels.makeOverlay(rgba: $0.rgba, width: $0.width, height: $0.height), $0.origin)
        }
        cache[k] = made
        return made
    }
}
