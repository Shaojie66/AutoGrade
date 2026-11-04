import SwiftUI

/// The split line, its handle and the two labels, drawn in points over the
/// picture. Anchored to the picture rect (`fitRect`), not the window, so the
/// line stays on the same part of the frame when the window resizes.
/// With an aspect set it also draws the crop (取景): the frame outside it dimmed,
/// and a drag anywhere but the split handle moves the current shot's crop.
struct CompareOverlay: View {
    @Bindable var project: Project
    private static let handle: CGFloat = 14
    @State private var drag: DragKind?

    private enum DragKind { case split, crop(start: Float) }

    var body: some View {
        GeometryReader { geo in
            if let info = project.summary?.info {
                let output = project.compare == .output
                let size = output ? project.reframe.map { r in
                    CGSize(width: r.aspect.outputSize.width, height: r.aspect.outputSize.height)
                } ?? .zero : CGSize(width: info.width, height: info.height)
                let rect = fitRect(image: size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    if let r = project.reframe, !output, let crop = cropRect(r, in: rect) {
                        Path { p in p.addRect(rect); p.addRect(crop) }
                            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                        Rectangle().stroke(.yellow, lineWidth: 2).frame(width: crop.width, height: crop.height)
                            .position(x: crop.midX, y: crop.midY)
                        label(L(S.dragCropHint)).position(x: rect.midX, y: rect.maxY - 18)
                    }
                    if project.compare == .split {
                        let x = rect.minX + rect.width * project.split
                        Rectangle()
                            .fill(.white.opacity(0.9))
                            .frame(width: 1, height: rect.height)
                            .position(x: x, y: rect.midY)
                        Circle()
                            .fill(.white)
                            .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black))
                            .frame(width: Self.handle * 2, height: Self.handle * 2)
                            .shadow(radius: 2)
                            .position(x: x, y: rect.midY)
                        label(L(S.compareOriginal)).position(x: rect.minX + 44, y: rect.minY + 18)
                        label(L(S.compareGraded)).position(x: rect.maxX - 44, y: rect.minY + 18)
                    } else {
                        let name = output ? S.compareOutput : project.compare == .original ? S.compareOriginal : S.compareGraded
                        label(L(name)).position(x: rect.minX + 44, y: rect.minY + 18)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { g in changed(g, rect: rect) }
                    .onEnded { _ in ended() })
            }
        }
    }

    /// The crop in view points, using the live drag position while dragging.
    private func cropRect(_ r: ReframeInfo, in rect: CGRect) -> CGRect? {
        guard project.playhead < r.centers.count, rect.width > 0 else { return nil }
        let c = CGFloat(project.draggingCrop ?? r.centers[project.playhead])
        if r.axis == 0 {
            let w = rect.width * r.length.x
            return CGRect(x: rect.minX + c * rect.width - w / 2, y: rect.minY, width: w, height: rect.height)
        }
        let h = rect.height * r.length.y
        return CGRect(x: rect.minX, y: rect.minY + c * rect.height - h / 2, width: rect.width, height: h)
    }

    private func changed(_ g: DragGesture.Value, rect: CGRect) {
        guard rect.width > 0 else { return }
        if drag == nil {
            let handleX = rect.minX + rect.width * project.split
            let onHandle = project.compare == .split && hypot(g.startLocation.x - handleX, g.startLocation.y - rect.midY) <= Self.handle * 1.5
            if let r = project.reframe, project.compare != .output, !onHandle, project.canEdit, project.playhead < r.centers.count {
                drag = .crop(start: r.centers[project.playhead])
            } else if project.compare == .split {
                drag = .split
            } else {
                return
            }
        }
        switch drag {
        case .split:
            project.split = min(max((g.location.x - rect.minX) / rect.width, 0), 1)
        case .crop(let start):
            guard let r = project.reframe else { return }
            let delta = r.axis == 0 ? g.translation.width / rect.width : g.translation.height / rect.height
            let half = Float((r.axis == 0 ? r.length.x : r.length.y) / 2)
            project.draggingCrop = min(max(start + Float(delta), half), 1 - half)
        case nil:
            break
        }
    }

    private func ended() {
        if case .crop = drag, let c = project.draggingCrop, let k = project.currentShot {
            project.setCropCenter(c, shot: k)
        }
        drag = nil
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
    }
}
