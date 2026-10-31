import DuotoneCore
import SwiftUI

/// A segmented bar drawn in SwiftUI, so a long list costs views rather than AppKit controls. It
/// serves the list rows (System / Dark / Light) and the sidebar's system appearance control
/// (Light / Dark). The selection is only ever `appearance`, which the model owns, so a refused
/// change shows the real value again without any local state to reset.
struct AppearanceBar: View {
  static let order: [Appearance] = [.system, .dark, .light]
  static let rowWidth: CGFloat = 250
  static let rowCompactWidth: CGFloat = 120
  static let height: CGFloat = 24

  var options: [Appearance] = AppearanceBar.order
  let appearance: Appearance
  /// The VoiceOver label of the whole control.
  let label: String
  var width: CGFloat = AppearanceBar.rowWidth
  var compactWidth: CGFloat = AppearanceBar.rowCompactWidth
  let enabled: Bool
  let compact: Bool
  let onSelect: (Appearance) -> Void

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.self) { option in
        segment(option)
      }
    }
    .frame(width: compact ? compactWidth : width, height: Self.height)
    .background(.quaternary, in: .capsule)
    .opacity(enabled ? 1 : 0.5)
    .disabled(!enabled)
    // One labelled control with three values for VoiceOver, instead of three loose buttons.
    .accessibilityRepresentation {
      Picker(label, selection: Binding(get: { appearance }, set: { onSelect($0) })) {
        ForEach(options, id: \.self) { Text($0.title).tag($0) }
      }
      .disabled(!enabled)
    }
  }

  private func segment(_ option: Appearance) -> some View {
    let selected = option == appearance
    let button = Button {
      if !selected { onSelect(option) }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: option.symbol).imageScale(.small)
        if !compact { Text(option.title) }
      }
      .font(.callout)
      .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        if selected { Capsule().fill(.tertiary).padding(2) }
      }
      .contentShape(.rect)
    }
    .buttonStyle(PressStyle())
    // Words are visible when not compact; only icon-only segments get a tooltip (it adds a tracking area).
    return Group {
      if compact { button.help(Text(option.title)) } else { button }
    }
  }
}

/// Opacity is the only press feedback; no hover tracking, which would add an area per row.
private struct PressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
  }
}
