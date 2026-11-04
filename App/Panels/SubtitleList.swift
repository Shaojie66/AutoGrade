import AutoGradeCore
import SwiftUI

/// The subtitles, one row per cue (CLAUDE.md 字幕): its time (click to go there),
/// its text (edit, Return to keep) and a delete button. No timing edits in v1.
struct SubtitleList: View {
    @Bindable var project: Project

    var body: some View {
        if project.subtitles.isEmpty {
            Text(L(S.noSubtitles))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(Array(project.subtitles.enumerated()), id: \.offset) { k, cue in
                    CueRow(project: project, index: k, cue: cue)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct CueRow: View {
    @Bindable var project: Project
    let index: Int
    let cue: SubtitleCue
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { project.seek(toSeconds: cue.start) } label: {
                    Text(String(format: "%@ – %@", stamp(cue.start), stamp(cue.end)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Button(role: .destructive) { project.deleteCue(index) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(L(S.deleteCue)).accessibilityLabel(L(S.deleteCue))
                    .disabled(!project.canEdit)
            }
            TextField("", text: $text, axis: .vertical)
                .lineLimit(1...3)
                .onSubmit { project.setCueText(text, cue: index) }
                .disabled(!project.canEdit)
                .accessibilityLabel(L(S.sidebarSubtitles) + " \(index + 1)")
        }
        .padding(.vertical, 2)
        .onAppear { text = cue.text }
        .onChange(of: cue.text) { _, new in text = new }
    }

    private func stamp(_ s: Double) -> String {
        String(format: "%d:%02d.%d", Int(s) / 60, Int(s) % 60, Int((s * 10).truncatingRemainder(dividingBy: 10)))
    }
}
