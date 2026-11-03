import AppKit
import AutoGradeCore
import SwiftUI

struct SettingsView: View {
    @Bindable private var localization = Localization.shared

    var body: some View {
        Form {
            Picker(L(S.language), selection: $localization.setting) {
                Text(L(S.followSystem)).tag(LanguageSetting.system)
                Text(L(S.english)).tag(LanguageSetting.english)
                Text(L(S.chinese)).tag(LanguageSetting.simplifiedChinese)
            }
            Section(L(S.styles)) {
                Button(L(S.showStylesFolder)) {
                    NSWorkspace.shared.activateFileViewerSelecting([StyleCatalog.defaultDirectory])
                }
                .disabled(!FileManager.default.fileExists(atPath: StyleCatalog.defaultDirectory.path))
                Text(L(S.stylesNote)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
