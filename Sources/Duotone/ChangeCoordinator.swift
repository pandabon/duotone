import Foundation
import DuotoneCore
import Observation

/// Decides whether a change needs asking about, and makes rejected pickers snap back.
@MainActor @Observable
final class ChangeCoordinator {
  struct Pending: Identifiable {
    var app: AppInfo
    var appearance: Appearance
    var id: BundleIdentifier { app.id }
  }

  static let suppressKey = "suppressRestartDialog"
  static let preferenceKey = "restartPreference"

  private(set) var pending: Pending?
  /// A picker whose state did not change keeps showing what the user clicked; a new identity resets it.
  private(set) var resetTokens: [BundleIdentifier: Int] = [:]
  @ObservationIgnored private let library: AppLibrary

  init(library: AppLibrary) { self.library = library }

  func request(_ appearance: Appearance, for app: AppInfo) {
    guard app.appearance != appearance else { return }
    guard library.isRunning(app) else {
      perform(appearance, for: app, restart: true)
      return
    }
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: Self.suppressKey) {
      perform(appearance, for: app, restart: defaults.string(forKey: Self.preferenceKey) != "later")
    } else {
      pending = Pending(app: app, appearance: appearance)
      reset(app.id)
    }
  }

  func confirm(restart: Bool) {
    guard let pending else { return }
    self.pending = nil
    UserDefaults.standard.set(restart ? "restart" : "later", forKey: Self.preferenceKey)
    perform(pending.appearance, for: pending.app, restart: restart)
  }

  func cancel() {
    guard let pending else { return }
    self.pending = nil
    // The dialog only appears while unsuppressed, so a checked toggle here would otherwise make
    // a cancelled choice silently permanent.
    UserDefaults.standard.set(false, forKey: Self.suppressKey)
    reset(pending.id)
  }

  func resetToken(for id: BundleIdentifier) -> Int { resetTokens[id, default: 0] }

  private func perform(_ appearance: Appearance, for app: AppInfo, restart: Bool) {
    Task {
      await library.setAppearance(appearance, for: app, restart: restart)
      reset(app.id)
    }
  }

  private func reset(_ id: BundleIdentifier) {
    resetTokens[id, default: 0] += 1
  }
}
