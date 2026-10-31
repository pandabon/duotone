import DuotoneCore
import SwiftUI

/// Rows take plain values and are compared by them, so a change elsewhere in the list never
/// re-evaluates a row. The height is fixed so a status appearing or the sandbox state resolving
/// never moves the rows around.
struct AppRow: View, Equatable {
  let item: AppListItem
  let compact: Bool
  let isTarget: Bool
  @Environment(ChangeCoordinator.self) private var coordinator

  nonisolated static func == (lhs: AppRow, rhs: AppRow) -> Bool { lhs.item == rhs.item && lhs.compact == rhs.compact && lhs.isTarget == rhs.isTarget }

  static let height: CGFloat = 44
  private static let inset: CGFloat = 16
  private static let iconSize: CGFloat = 32
  private static let gap: CGFloat = 12

  var body: some View {
    let status = AppStatus(app: item.app, outcome: item.outcome)
    HStack(spacing: Self.gap) {
      AppIconView(url: item.app.url, size: Self.iconSize)
      VStack(alignment: .leading, spacing: 1) {
        Text(item.app.name)
          .lineLimit(1)
        if status.hasMessage {
          StatusLine(status: status)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      AppearanceBar(
        appearance: item.app.appearance, label: String(localized: "Appearance for \(item.app.name)"),
        enabled: status.allowsChanges, compact: compact
      ) { [app = item.app] in coordinator.request($0, for: app) }
    }
    .padding(.horizontal, Self.inset)
    .frame(height: Self.height)
    // Always present, only its opacity changes, so selecting never swaps the row's children.
    .background { SelectionHighlight(isOn: isTarget).padding(.horizontal, 6) }
    // The separator is part of the row and starts at the name.
    .overlay(alignment: .bottom) {
      Divider().padding(.leading, Self.inset + Self.iconSize + Self.gap).padding(.trailing, Self.inset)
    }
    .accessibilityElement(children: .contain)
  }
}

struct AppTile: View, Equatable {
  let item: AppListItem
  let resetToken: Int
  let isTarget: Bool
  @ScaledMetric(relativeTo: .callout) private var nameHeight = 34

  nonisolated static func == (lhs: AppTile, rhs: AppTile) -> Bool { lhs.item == rhs.item && lhs.resetToken == rhs.resetToken && lhs.isTarget == rhs.isTarget }

  var body: some View {
    let status = AppStatus(app: item.app, outcome: item.outcome)
    VStack(spacing: 4) {
      AppIconView(url: item.app.url, size: 52)
      Text(item.app.name)
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .frame(height: nameHeight)
      AppearancePicker(app: item.app, enabled: status.allowsChanges, resetToken: resetToken)
      // Below the picker, so pickers line up across a row whether or not a status exists.
      if status.hasMessage {
        StatusLine(status: status)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 4)
    .background { SelectionHighlight(isOn: isTarget) }
    .accessibilityElement(children: .contain)
  }
}

/// The type-to-select target, in the accent colour at low opacity.
struct SelectionHighlight: View {
  let isOn: Bool

  var body: some View {
    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(isOn ? 0.22 : 0))
  }
}
