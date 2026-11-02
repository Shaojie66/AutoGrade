import AutoGradeCore
import SwiftUI

/// Left column: one row per shot — graded thumbnail, range, duration, strength.
struct ShotList: View {
    @Bindable var project: Project

    var body: some View {
        List {
            if let summary = project.summary {
                ForEach(Array(summary.shots.enumerated()), id: \.offset) { k, shot in
                    ShotRow(project: project, index: k, shot: shot, seconds: summary.shotSeconds[k],
                            selected: project.currentShot == k)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(L(S.shots))
    }
}

private struct ShotRow: View {
    @Bindable var project: Project
    let index: Int
    let shot: Shot
    let seconds: Double
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { project.selectShot(index) } label: {
                HStack(alignment: .top, spacing: 8) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L(S.shot(index + 1))).font(.headline)
                        Text(L(S.frames(shot.first, shot.last))).font(.caption).foregroundStyle(.secondary)
                        Text(L(S.seconds(seconds))).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                Text(L(S.strength)).font(.caption)
                Slider(value: strength, in: 0...1) { editing in
                    if !editing { project.strengthCommitted(shot: index) }
                }
                .controlSize(.small)
                .disabled(!project.canEdit && !project.isPlaying)
                Text("\(Int((project.strengths[safe: index] ?? 1) * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var strength: Binding<Double> {
        Binding(get: { Double(project.strengths[safe: index] ?? 1) },
                set: { project.setStrength(Float($0), shot: index) })
    }

    @ViewBuilder private var thumbnail: some View {
        Group {
            if let image = project.thumbnails[index] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
