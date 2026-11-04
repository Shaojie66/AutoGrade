import AppKit
import AutoGradeCore
import SwiftUI

struct SettingsView: View {
    @Bindable private var localization = Localization.shared
    @Bindable private var titles = TitleSuggestionSettings.shared
    @State private var keyInput = ""          // cleared once saved; the saved key is never shown again

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
            Section(L(S.titleSuggestionsSection)) {
                Toggle(L(S.useDeepSeek), isOn: $titles.enabled)
                SecureField(L(S.deepSeekKey), text: $keyInput)
                    .accessibilityLabel(L(S.deepSeekKey))
                HStack {
                    Button(L(S.saveKey)) {
                        titles.saveKey(keyInput)
                        keyInput = ""
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(L(S.deleteKey), role: .destructive) { titles.deleteKey() }
                        .disabled(!titles.hasKey)
                }
                Text(L(titles.hasKey ? S.keySaved : S.keyNotSaved)).font(.caption)
                if let error = titles.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
                Text(L(S.titleSuggestionsNote)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
