import AutoGradeCore
import SwiftUI

/// Transport controls above a timeline of shot blocks, cut ticks and the playhead.
struct Transport: View {
    @Bindable var project: Project

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button { project.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .help(L(S.previousFrame)).accessibilityLabel(L(S.previousFrame))
                Button { project.togglePlay() } label: {
                    Image(systemName: project.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .help(L(project.isPlaying ? S.pause : S.play)).accessibilityLabel(L(project.isPlaying ? S.pause : S.play))
                Button { project.step(1) } label: { Image(systemName: "forward.frame.fill") }
                    .help(L(S.nextFrame)).accessibilityLabel(L(S.nextFrame))
                if let s = project.summary {
                    Text(L(S.frameOf(project.playhead, s.frameCount))).font(.callout.monospacedDigit())
                        .lineLimit(1).fixedSize()   // "Frame 101 of 193" wrapped in English (2026-11-02)
                }
                if project.isPlaying, let stats = project.stats {
                    Text(L(S.playbackRate(stats.fps, stats.dropped))).font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                }
                Spacer()
                // one line each: the 2026-11-02 walkthrough caught the merge label wrapping
                Button(L(S.addCut)) { project.addCut() }.disabled(!project.canAddCut)
                    .lineLimit(1).fixedSize()
                Button(L(S.removeCut)) { project.removeCut() }.disabled(!project.canRemoveCut)
                    .lineLimit(1).fixedSize()
                Picker("", selection: $project.compare) {
                    Text(L(S.compareSplit)).tag(CompareMode.split)
                    Text(L(S.compareOriginal)).tag(CompareMode.original)
                    Text(L(S.compareGraded)).tag(CompareMode.graded)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .disabled(project.summary == nil)
            Timeline(project: project).frame(height: 40)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct Timeline: View {
    @Bindable var project: Project

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard let s = project.summary, s.frameCount > 0 else { return }
                let perFrame = size.width / CGFloat(s.frameCount)
                for (k, shot) in s.shots.enumerated() {
                    let rect = CGRect(x: CGFloat(shot.first) * perFrame, y: 6,
                                      width: CGFloat(shot.frames) * perFrame, height: size.height - 12)
                    let selected = project.currentShot == k
                    ctx.fill(Path(rect), with: .color(.accentColor.opacity(selected ? 0.55 : (k.isMultiple(of: 2) ? 0.22 : 0.34))))
                    if k > 0 {
                        ctx.fill(Path(CGRect(x: rect.minX - 1, y: 0, width: 2, height: size.height)), with: .color(.primary.opacity(0.8)))
                    }
                }
                let x = (CGFloat(project.playhead) + 0.5) * perFrame
                ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.red))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard let s = project.summary, geo.size.width > 0 else { return }
                project.seek(Int(g.location.x / geo.size.width * CGFloat(s.frameCount)))
            })
        }
    }
}
