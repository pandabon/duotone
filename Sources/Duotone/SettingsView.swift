import DuotoneCore
import SwiftUI

struct SettingsView: View {
  @AppStorage(AppAppearance.key) private var appearance = Appearance.system
  @AppStorage("compactBars") private var compact = false

  var body: some View {
    Form {
      Section {
        LabeledContent("Appearance") {
          AppearanceBar(
            appearance: appearance, label: String(localized: "Appearance"),
            width: 250, compactWidth: 120, enabled: true, compact: false
          ) { appearance = $0 }
        }
      } footer: {
        Text("Applies to Duotone only.")
      }
      Section {
        Toggle("Compact mode", isOn: $compact)
      }
    }
    .formStyle(.grouped)
    .frame(width: 440, height: 210)
    .onChange(of: appearance) { _, new in AppAppearance.apply(new) }
  }
}
