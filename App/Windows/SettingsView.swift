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
        }
        .padding(20)
        .frame(width: 360)
    }
}
