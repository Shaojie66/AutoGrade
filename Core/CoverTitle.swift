import CoreGraphics
import CoreText
import Foundation

/// Where a cover title goes (CLAUDE.md 封面 / 版式). Each template lists its
/// placements in order; the first one clear of the face wins.
public enum CoverTitleTemplate: String, CaseIterable, Sendable {
    case bottom     // large, centred, near the bottom (else the top)
    case corner     // title + subtitle, left-aligned, top-left (else bottom-left)
    case center     // the largest, centred (else at 25% or 75% of the height)
}

/// The owner's title for the covers: one line, an optional second smaller line.
public struct CoverTitle: Sendable, Equatable {
    public var title: String
    public var subtitle: String?
    public var template: CoverTitleTemplate

    public init(title: String, subtitle: String? = nil, template: CoverTitleTemplate = .bottom) {
        self.title = title
        self.subtitle = subtitle
        self.template = template
    }

    var lines: [String] {
        [title, subtitle ?? ""].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    public var isEmpty: Bool { lines.isEmpty }
}

public enum CoverTitleLayout {
    // CLAUDE.md 封面 / 版式 — change the rules there first.
    public static let margin: CGFloat = 0.06            // of the width (x) and the height (y): placeholder safe area
    public static let faceMargin: CGFloat = 0.04        // of the cover's short side, around the face
    public static let maxWidthFraction: CGFloat = 0.85
    public static let subtitleScale: CGFloat = 0.5

    static func sizeFraction(_ t: CoverTitleTemplate) -> CGFloat {
        switch t {
        case .bottom: 0.085
        case .corner: 0.07
        case .center: 0.11
        }
    }

    public struct Raster: Sendable {
        public let rgba: [UInt8]           // premultiplied sRGB RGBA8
        public let width: Int
        public let height: Int
        public let fontSize: CGFloat       // the title line's, after any shrinking
    }

    /// The title block for a `width` x `height` cover, drawn like subtitles
    /// (`SubtitleRenderer.draw`). nil when there is no text.
    public static func raster(_ t: CoverTitle, canvasWidth w: Int, canvasHeight h: Int) -> Raster? {
        let text = t.lines
        guard !text.isEmpty, w > 0, h > 0 else { return nil }
        var size = CGFloat(min(w, h)) * sizeFraction(t.template)
        func sizes() -> [CGFloat] { text.indices.map { $0 == 0 ? size : size * subtitleScale } }
        func layouts() -> [SubtitleRenderer.Layout] { zip(text, sizes()).map { SubtitleRenderer.layout([$0], size: $1) } }
        var built = layouts()
        let widest = built.map(\.width).max() ?? 0, maxWidth = CGFloat(w) * maxWidthFraction
        if widest > maxWidth {                                   // too wide: shrink every line alike
            size *= maxWidth / widest
            built = layouts()
        }
        let lineSizes = sizes()
        let pad = Int((size * SubtitleRenderer.strokePercent / 100 + size * 0.12).rounded(.up)) + 2
        let heights = lineSizes.map { $0 * SubtitleRenderer.lineSpacing }
        let bw = Int((built.map(\.width).max() ?? 0).rounded(.up)) + 2 * pad
        let bh = Int(heights.reduce(0, +).rounded(.up)) + 2 * pad
        var top = CGFloat(pad)                                   // from the bitmap's top
        var lines: [SubtitleRenderer.TextLine] = []
        for (i, l) in built.enumerated() {
            let lw = CGFloat(CTLineGetTypographicBounds(l.fills[0], nil, nil, nil))
            let x = t.template == .corner ? CGFloat(pad) : (CGFloat(bw) - lw) / 2
            // CoreGraphics is bottom-up: the baseline sits `ascent` below the line's top, centred in its height
            let baseline = CGFloat(bh) - top - l.ascent - (heights[i] - l.ascent - l.descent) / 2
            lines.append(.init(fill: l.fills[0], stroke: l.strokes[0], position: CGPoint(x: x, y: baseline), size: lineSizes[i]))
            top += heights[i]
        }
        guard let rgba = SubtitleRenderer.draw(lines, width: bw, height: bh) else { return nil }
        return Raster(rgba: rgba, width: bw, height: bh, fontSize: size)
    }

    /// The template's placements of a `block` in a `canvas`, in order (top-left origin, pixels).
    public static func candidates(_ t: CoverTitleTemplate, canvas: CGSize, block: CGSize) -> [CGRect] {
        let (W, H, w, h) = (canvas.width, canvas.height, block.width, block.height)
        let mx = W * margin, my = H * margin, cx = (W - w) / 2
        let tops: [(CGFloat, CGFloat)]
        switch t {
        case .bottom: tops = [(cx, H - my - h), (cx, my)]
        case .corner: tops = [(mx, my), (mx, H - my - h)]
        case .center: tops = [(cx, (H - h) / 2), (cx, H * 0.25 - h / 2), (cx, H * 0.75 - h / 2)]
        }
        return tops.map { x, y in
            CGRect(x: min(max(x, 0), max(W - w, 0)).rounded(), y: min(max(y, 0), max(H - h, 0)).rounded(), width: w, height: h)
        }
    }

    /// The first placement clear of `face`, else the one overlapping it least
    /// (the earlier on ties); `overlapsFace` says whether it still touches it.
    public static func place(_ t: CoverTitleTemplate, canvas: CGSize, block: CGSize, face: CGRect?)
        -> (rect: CGRect, overlapsFace: Bool) {
        let options = candidates(t, canvas: canvas, block: block)
        guard let face else { return (options[0], false) }
        func overlap(_ r: CGRect) -> CGFloat {
            let i = r.intersection(face)
            return i.isNull ? 0 : i.width * i.height
        }
        var best = options[0]
        for r in options.dropFirst() where overlap(r) < overlap(best) { best = r }
        return (best, overlap(best) > 0)
    }

    /// This frame's face in cover pixels, widened by `faceMargin`: only face
    /// samples count (people and saliency boxes are too large to avoid).
    public static func face(_ sample: SubjectTrack.Sample?, sourceWidth: Int, sourceHeight: Int,
                            crop origin: SIMD2<Float>, length: SIMD2<Float>, canvas: CGSize) -> CGRect? {
        guard let s = sample, s.source == .face else { return nil }
        let sx = canvas.width / CGFloat(length.x), sy = canvas.height / CGFloat(length.y)
        let x0 = (CGFloat(s.center.x - s.size.x / 2) * CGFloat(sourceWidth) - CGFloat(origin.x)) * sx
        let y0 = (CGFloat(s.center.y - s.size.y / 2) * CGFloat(sourceHeight) - CGFloat(origin.y)) * sy
        let box = CGRect(x: x0, y: y0, width: CGFloat(s.size.x) * CGFloat(sourceWidth) * sx,
                         height: CGFloat(s.size.y) * CGFloat(sourceHeight) * sy)
        let m = min(canvas.width, canvas.height) * faceMargin
        return box.insetBy(dx: -m, dy: -m)
    }
}

extension AutoGrader {
    /// The title overlay for one cover (CLAUDE.md 封面 / 版式): raster, placed
    /// clear of the frame's face when it can be. nil when the title is empty.
    public func coverTitleOverlay(_ t: CoverTitle, aspect: CoverAspect, sourceWidth: Int, sourceHeight: Int,
                                  center: SIMD2<Float>, face sample: SubjectTrack.Sample?) throws
        -> (overlay: (OverlayImage, SIMD2<Int32>), overlapsFace: Bool)? {
        let (w, h) = aspect.outputSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        guard let r = CoverTitleLayout.raster(t, canvasWidth: w, canvasHeight: h) else { return nil }
        let canvas = CGSize(width: w, height: h)
        let (origin, length) = Cover.crop(center: center, aspect: aspect, width: sourceWidth, height: sourceHeight)
        let face = CoverTitleLayout.face(sample, sourceWidth: sourceWidth, sourceHeight: sourceHeight, crop: origin,
                                         length: length, canvas: canvas)
        let placed = CoverTitleLayout.place(t.template, canvas: canvas, block: CGSize(width: r.width, height: r.height), face: face)
        let image = try kernels.makeOverlay(rgba: r.rgba, width: r.width, height: r.height)
        return ((image, SIMD2(Int32(placed.rect.minX), Int32(placed.rect.minY))), placed.overlapsFace)
    }
}
