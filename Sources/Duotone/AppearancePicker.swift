import DuotoneCore
import SwiftUI

/// The grid tile's menu. Changes go through the coordinator, which may ask first; `resetToken`
/// gives the menu a new identity when a change was refused so it shows the real value again.
struct AppearancePicker: View {
  let app: AppInfo
  let enabled: Bool
  let resetToken: Int
  @Environment(ChangeCoordinator.self) private var coordinator

  private var selection: Binding<Appearance> {
    Binding(get: { app.appearance }, set: { coordinator.request($0, for: app) })
  }

  var body: some View {
    Menu {
      Picker("Appearance for \(app.name)", selection: selection) {
        ForEach(AppearanceBar.order, id: \.self) { appearance in
          Label(appearance.title, systemImage: appearance.symbol).tag(appearance)
        }
      }
      .pickerStyle(.inline)
    } label: {
      // Customized apps stand out; the default value recedes.
      Label(app.appearance.title, systemImage: app.appearance.symbol)
        .labelStyle(.titleAndIcon)
        .foregroundStyle(app.appearance == .system ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(!enabled)
    .accessibilityLabel("Appearance for \(app.name)")
    .id(resetToken)
  }
}
