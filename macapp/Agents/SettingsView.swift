import SwiftUI

/// Content of the app's Settings window (see the `Settings` scene in
/// `AgentsApp`), currently just the appearance picker.
///
/// `@AppStorage` decodes the stored string through
/// `AppearanceMode`'s `RawRepresentable` init, so an unknown or corrupt
/// stored value (e.g. from a future case this build doesn't know about)
/// falls back to the declared default, `.system`, rather than crashing or
/// leaving the picker wedged on nothing.
struct SettingsView: View {
    @AppStorage(AppearanceMode.defaultsKey) private var appearanceMode: AppearanceMode = .system

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize()
    }
}
