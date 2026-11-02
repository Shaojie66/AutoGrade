import AutoGradeCore
import AVFoundation
import SwiftUI

/// The picture, shown through AVSampleBufferDisplayLayer — the same system
/// video display path QuickTime uses — so the preview is colour-managed the
/// way the exported file will be (CLAUDE.md 架构原则 5). Each change (new
/// frame, split move, mode) enqueues one composited, BT.709-tagged buffer for
/// immediate display; the layer does the aspect-fit scaling.
struct PreviewView: NSViewRepresentable {
    let frame: DisplayFrame?
    let split: Double
    let mode: CompareMode

    func makeCoordinator() -> PreviewPresenter { PreviewPresenter() }

    func makeNSView(context: Context) -> DisplayLayerView {
        DisplayLayerView()
    }

    func updateNSView(_ view: DisplayLayerView, context: Context) {
        context.coordinator.show(frame, split: split, mode: mode, on: view.displayLayer)
    }
}

final class DisplayLayerView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer = displayLayer
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

@MainActor
final class PreviewPresenter {
    private let kernels: GradeKernels?
    private var maker: DisplayFrameMaker?
    private var shown: (index: Int, split: Double, mode: CompareMode, texture: ObjectIdentifier)?

    init() {
        kernels = (try? MetalContext()).map { GradeKernels(metal: $0) }
    }

    func show(_ frame: DisplayFrame?, split: Double, mode: CompareMode, on layer: AVSampleBufferDisplayLayer) {
        guard let kernels, let frame else { return }
        let key = (frame.index, split, mode, ObjectIdentifier(frame.graded))
        if let shown, shown.index == key.0, shown.split == key.1, shown.mode == key.2, shown.texture == key.3 { return }
        do {
            let w = frame.graded.width, h = frame.graded.height
            if maker?.width != w || maker?.height != h {
                maker = try DisplayFrameMaker(kernels: kernels, width: w, height: h)
            }
            let layout: CompareLayout = mode == .split ? .split : (mode == .original ? .original : .graded)
            let sample = try maker!.sampleBuffer(original: frame.original, graded: frame.graded, split: split, layout: layout)
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sample)
            shown = key
        } catch {
            // A frame that cannot be shown leaves the previous one on screen.
        }
    }
}

/// Aspect-fit `image` inside `container`, centred — what `.resizeAspect`
/// does, so the compare overlay's line sits where the layer draws the split.
func fitRect(image: CGSize, in container: CGSize) -> CGRect {
    guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return .zero }
    let scale = min(container.width / image.width, container.height / image.height)
    let w = image.width * scale, h = image.height * scale
    return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
}
