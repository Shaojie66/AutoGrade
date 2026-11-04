import AutoGradeCore
import SwiftUI

/// Cover frames (CLAUDE.md 封面): find them once, tick the ones to export,
/// pick shapes and a format. The preview below is the exported pixels; the
/// row pictures are the shot list's approximate thumbnails.
struct CoverList: View {
    @Bindable var project: Project

    var body: some View {
        if let covers = project.covers {
            VStack(spacing: 0) {
                List(selection: Binding(get: { project.selectedCover }, set: { if let f = $0 { project.selectCover(f) } })) {
                    ForEach(Array(covers.enumerated()), id: \.element.frame) { k, c in
                        CoverRow(project: project, rank: k + 1, candidate: c).tag(c.frame)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                controls.padding(10)
            }
        } else {
            VStack(spacing: 12) {
                Text(L(S.coversHint)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(L(S.findCovers)) { project.findCovers() }.disabled(!project.canEdit)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(S.coverShapes)).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(CoverAspect.allCases, id: \.self) { a in
                    Toggle(name(a), isOn: Binding(get: { project.coverAspects.contains(a) },
                                                  set: { if $0 { project.coverAspects.insert(a) } else { project.coverAspects.remove(a) } }))
                        .toggleStyle(.checkbox)
                }
            }
            Picker(L(S.coverFormat), selection: $project.coverFormat) {
                Text("PNG").tag(CoverFormat.png)
                Text("JPEG").tag(CoverFormat.jpeg)
            }
            .pickerStyle(.segmented)
            preview
            Text(L(S.coverShortShots)).font(.caption).foregroundStyle(.secondary)
            Button(L(S.exportCoversButton)) { project.exportCovers() }
                .disabled(!project.canExportCovers)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder private var preview: some View {
        if project.selectedCover != nil {
            Picker(L(S.coverPreviewTitle), selection: $project.coverPreviewAspect) {
                ForEach(CoverAspect.allCases, id: \.self) { a in Text(name(a)).tag(a) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(L(S.coverPreviewTitle)).font(.caption).foregroundStyle(.secondary)
            Group {
                if let image = project.coverPreview {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 220)
        } else {
            Text(L(S.coverSelectHint)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func name(_ a: CoverAspect) -> String { a == .original ? L(S.coverOriginal) : a.rawValue }
}

private struct CoverRow: View {
    @Bindable var project: Project
    let rank: Int
    let candidate: Cover.Candidate

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { project.coverChosen.contains(candidate.frame) },
                                     set: { if $0 { project.coverChosen.insert(candidate.frame) } else { project.coverChosen.remove(candidate.frame) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(L(S.coverInclude))
                .accessibilityLabel(L(S.coverInclude))
            Group {
                if let image = project.coverThumbnails[candidate.frame] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 72, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text(L(S.coverRow(rank: rank, shot: candidate.shot + 1, frame: candidate.frame))).font(.callout)
                Text(L(S.coverScore(candidate.rank))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
