import SwiftUI

/// The split line, its handle and the two labels, drawn in points over the
/// picture. Anchored to the picture rect (`fitRect`), not the window, so the
/// line stays on the same part of the frame when the window resizes.
struct CompareOverlay: View {
    @Bindable var project: Project
    private static let handle: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            if let info = project.summary?.info {
                let rect = fitRect(image: CGSize(width: info.width, height: info.height), in: geo.size)
                ZStack(alignment: .topLeading) {
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
                        label(L(project.compare == .original ? S.compareOriginal : S.compareGraded))
                            .position(x: rect.minX + 44, y: rect.minY + 18)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    guard project.compare == .split, rect.width > 0 else { return }
                    project.split = min(max((g.location.x - rect.minX) / rect.width, 0), 1)
                })
            }
        }
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
