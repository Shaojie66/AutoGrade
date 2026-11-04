import AutoGradeCore
import SwiftUI

/// Cover frames (CLAUDE.md 封面): find them once, tick the ones to export,
/// pick shapes and a format. The selected cover is previewed in the main view
/// (`CoverPreview`, the exported pixels); the row pictures are the shot list's
/// approximate thumbnails.
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
            Text(L(S.coverTitle)).font(.caption).foregroundStyle(.secondary)
            TextField(L(S.coverTitle), text: $project.coverTitleText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L(S.coverTitle))
            TextField(L(S.coverSubtitle), text: $project.coverSubtitleText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L(S.coverSubtitle))
            titleCandidates
            Picker(L(S.coverTemplate), selection: $project.coverTemplate) {
                Text(L(S.templateBottom)).tag(CoverTitleTemplate.bottom)
                Text(L(S.templateCorner)).tag(CoverTitleTemplate.corner)
                Text(L(S.templateCenter)).tag(CoverTitleTemplate.center)
            }
            .pickerStyle(.segmented)
            Picker(L(S.coverFormat), selection: $project.coverFormat) {
                Text("PNG").tag(CoverFormat.png)
                Text("JPEG").tag(CoverFormat.jpeg)
            }
            .pickerStyle(.segmented)
            if project.selectedCover == nil {
                Text(L(S.coverSelectHint)).font(.caption).foregroundStyle(.secondary)
            }
            Text(L(S.coverShortShots)).font(.caption).foregroundStyle(.secondary)
            Button(L(S.exportCoversButton)) { project.exportCovers() }
                .disabled(!project.canExportCovers)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// DeepSeek candidates (CLAUDE.md 封面 / 云端候选 / App), only once turned on with a key saved.
    @ViewBuilder private var titleCandidates: some View {
        if project.titleSettings.enabled && project.titleSettings.hasKey {
            DisclosureGroup(L(S.titleSuggestionsSection)) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(L(S.titleTopic), text: $project.coverTopicText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L(S.titleTopic))
                    HStack {
                        Button(L(S.suggestTitles)) { project.suggestTitles() }
                            .disabled(!project.canSuggestTitles)
                        Button(L(S.anotherBatch)) { project.suggestTitles(anotherBatch: true) }
                            .disabled(!project.canSuggestTitles || project.offeredTitles.isEmpty)
                        if project.suggestingTitles { ProgressView().controlSize(.small) }
                    }
                    let counts = project.titleSendCounts
                    Text(L(S.titleWillSend(counts.topic, counts.subtitles))).font(.caption).foregroundStyle(.secondary)
                    if project.titleInputIsThin { Text(L(S.titleThinHint)).font(.caption).foregroundStyle(.secondary) }
                    if let error = project.titleSuggestionError { Text(error).font(.caption).foregroundStyle(.orange) }
                    if !project.titleCandidates.isEmpty {
                        Text(L(S.titleCheckFacts)).font(.caption).foregroundStyle(.secondary)
                        ForEach(project.titleCandidates, id: \.self) { t in
                            Button(t) { project.useTitleCandidate(t) }
                                .buttonStyle(.link)
                                .accessibilityLabel(t)
                        }
                    }
                }
                .padding(.top, 4)
            }
        } else {
            Text(L(S.titleSuggestionsOff)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func name(_ a: CoverAspect) -> String { coverAspectName(a) }
}

@MainActor func coverAspectName(_ a: CoverAspect) -> String { a == .original ? L(S.coverOriginal) : a.rawValue }

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
                Text(L(S.coverRow(rank: rank, shot: candidate.shot + 1))).font(.callout).lineLimit(1)
                Text(L(S.coverDetail(frame: candidate.frame + 1, score: candidate.rank)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
