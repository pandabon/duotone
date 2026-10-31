import AppKit
import DuotoneCore

/// Duotone's own look, applied through `NSApp.appearance` so the window, sheets, menus and Settings
/// all follow it at once. It is stored under its own key and never in Duotone's preference domain
/// as `NSRequiresAquaSystemAppearance`.
@MainActor
enum AppAppearance {
  static let key = "appAppearance"

  static func apply(_ appearance: Appearance) {
    NSApp.appearance = switch appearance {
    case .system: nil
    case .dark: NSAppearance(named: .darkAqua)
    case .light: NSAppearance(named: .aqua)
    }
  }

  /// Read straight from UserDefaults, before any view exists, so the first window is already right.
  static func applyStored() {
    apply(UserDefaults.standard.string(forKey: key).flatMap(Appearance.init(rawValue:)) ?? .system)
  }
}
