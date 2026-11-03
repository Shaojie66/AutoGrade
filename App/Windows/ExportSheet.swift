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
            Toggle(L(S.alsoCubes), isOn: $project.exportCubes)
            Toggle(L(S.keepAudio), isOn: $project.exportAudio)
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
