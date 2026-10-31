import DuotoneCore
import SwiftUI

/// Lives in the sidebar footer; the control logic is the controller's. It follows Compact mode.
struct SystemAppearanceSection: View {
  let controller: SystemAppearanceController
  @AppStorage("compactBars") private var compact = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("System appearance", systemImage: controller.isDark ? "moon.fill" : "sun.max.fill")
        .font(.caption)
        .foregroundStyle(.secondary)
      AppearanceBar(
        options: [.light, .dark],
        appearance: controller.isDark ? .dark : .light,
        label: String(localized: "System appearance"),
        width: 172, compactWidth: 80,
        enabled: true, compact: compact
      ) { controller.setDark($0 == .dark) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .accessibilityElement(children: .contain)
  }
}
