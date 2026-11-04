import AutoGradeCore
import SwiftUI

/// Left column: one row per shot — graded thumbnail, range, duration, strength, style.
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
                rowLabel(L(S.strength))
                Slider(value: strength, in: 0...1) { editing in
                    if !editing { project.strengthCommitted(shot: index) }
                }
                .controlSize(.small)
                .disabled(!project.canEdit && !project.isPlaying)
                Text("\(Int((project.strengths[safe: index] ?? 1) * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
            if let r = project.reframe, index < r.modes.count {
                // the same setCropCenter the preview drag uses; also reachable without dragging
                HStack(spacing: 6) {
                    rowLabel(L(S.cropPosition))
                    Slider(value: cropPosition(r), in: cropRange(r))
                        .controlSize(.small)
                        .disabled(!project.canEdit)
                        .accessibilityLabel(L(S.cropPosition))
                }
                HStack(spacing: 6) {
                    Text(L(r.modes[index] == .manual ? S.cropManual : r.modes[index] == .follow ? S.cropFollow : S.cropFixed))
                        .font(.caption).foregroundStyle(.secondary)
                    if r.modes[index] == .manual {
                        Button(L(S.resetCrop)) { project.setCropCenter(nil, shot: index) }
                            .controlSize(.small)
                            .disabled(!project.canEdit)
                    }
                }
            }
            if project.availableStyles.count > 1 {
                Picker(L(S.style), selection: style) {
                    ForEach(project.availableStyles) { s in Text(project.styleName(s.id)).tag(s.id) }
                }
                .font(.caption)
                .controlSize(.small)
                .disabled(!project.canEdit)
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

    /// A fixed-width, one-line label, so a longer translation never widens the row
    /// (English "Crop position" pushed the sidebar's rows out of view, 2026-11-04).
    private func rowLabel(_ text: String) -> some View {
        Text(text).font(.caption).lineLimit(1).minimumScaleFactor(0.8).frame(width: 64, alignment: .leading)
    }

    /// The shot's crop centre at its middle frame, normalised along the crop's axis.
    private func cropPosition(_ r: ReframeInfo) -> Binding<Double> {
        Binding(get: { Double(r.centers[safe: (shot.first + shot.last) / 2] ?? 0.5) },
                set: { project.setCropCenter(Float($0), shot: index) })
    }

    private func cropRange(_ r: ReframeInfo) -> ClosedRange<Double> {
        let half = (r.axis == 0 ? r.length.x : r.length.y) / 2
        return half...max(half, 1 - half)
    }

    private var style: Binding<String> {
        Binding(get: { project.styles[safe: index] ?? StyleCatalog.builtinID },
                set: { project.setStyle($0, shot: index) })
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
