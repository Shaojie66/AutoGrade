import AutoGradeCore
import SwiftUI

struct ExportSheet: View {
    @Bindable var project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L(S.exportTitle)).font(.title2.weight(.semibold))
            Picker(L(S.codec), selection: $project.exportCodec) {
                Text("HEVC").tag(OutputCodec.hevc)
                Text("ProRes 422").tag(OutputCodec.prores)
            }
            .pickerStyle(.segmented)
            if let info = project.summary?.info {
                let r = project.reframe?.aspect
                let size = r?.outputSize ?? (info.width, info.height)
                let name = r == .vertical9x16 ? L(S.aspectVertical) : r == .horizontal16x9 ? L(S.aspectHorizontal) : L(S.aspectOriginal)
                Text(L(S.exportFrame(name, size.0, size.1))).font(.callout).foregroundStyle(.secondary)
            }
            Toggle(L(S.alsoCubes), isOn: $project.exportCubes)
            // No audio track: shown unticked as well as disabled, so it never looks like audio will be kept.
            Toggle(L(S.keepAudio), isOn: (project.summary?.hasAudio ?? false) ? $project.exportAudio : .constant(false))
                .disabled(!(project.summary?.hasAudio ?? false))
            if !(project.summary?.hasAudio ?? false) {
                Text(L(S.noAudioInSource)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L(S.cancel)) { project.showingExport = false }.keyboardShortcut(.cancelAction)
                Button(L(S.start)) { project.runExport() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
