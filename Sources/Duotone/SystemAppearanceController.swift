import AppKit
import Observation

@MainActor @Observable
final class SystemAppearanceController {
  enum Failure: Equatable {
    case automationDenied
    case other(String)
  }

  private(set) var isDark = SystemAppearanceController.readIsDark()
  private(set) var failure: Failure?
  @ObservationIgnored private var observer: NSObjectProtocol?

  init() {
    observer = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.isDark = Self.readIsDark() }
    }
  }

  func setDark(_ dark: Bool) {
    guard dark != isDark else { return }
    failure = nil
    let source = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
    var info: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&info)
    if let info {
      let code = info[NSAppleScript.errorNumber] as? Int
      failure = code == -1743
        ? .automationDenied
        : .other(info[NSAppleScript.errorMessage] as? String ?? "")
    }
    isDark = Self.readIsDark()
  }

  func clearFailure() { failure = nil }

  // Read from the global domain directly; UserDefaults.standard can lag behind the notification.
  private static func readIsDark() -> Bool {
    let value = CFPreferencesCopyValue(
      "AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    return (value as? String) == "Dark"
  }
}
