import Foundation

public enum RestartStatus: Sendable, Hashable {
  case notRunning
  case relaunched
  /// Written without quitting the app, as requested; it applies on its next launch.
  case appliesOnNextLaunch
  /// A CoreService was terminated; launchd brings it back with the new setting.
  case restartedBySystem
  /// The app declined to quit (e.g. unsaved changes). The setting is saved and applies on its next launch.
  case stillRunning
  case reopenFailed(String)
}

public enum SetAppearanceOutcome: Sendable, Hashable {
  case applied(RestartStatus)
  case failed(AppearanceError)
}

public struct ApplyReport: Sendable, Hashable {
  public var applied: [BundleIdentifier] = []
  /// Already at the requested value.
  public var unchanged: [BundleIdentifier] = []
  /// Not installed on this Mac.
  public var missing: [BundleIdentifier] = []
  public var failed: [BundleIdentifier: AppearanceError] = [:]
  public var rejectedLineCount = 0

  public init() {}
}

public actor AppearanceService {
  private let scanner: AppScanner
  private let store: any AppearanceStore
  private let relauncher: any AppRelauncher
  private let quitTimeout: Duration
  private let fullDiskAccess: any FullDiskAccessChecking

  public init(
    scanner: AppScanner = AppScanner(),
    store: any AppearanceStore = PreferencesAppearanceStore(),
    relauncher: any AppRelauncher,
    quitTimeout: Duration = .seconds(5),
    fullDiskAccess: any FullDiskAccessChecking = SystemFullDiskAccess()
  ) {
    self.scanner = scanner
    self.store = store
    self.relauncher = relauncher
    self.quitTimeout = quitTimeout
    self.fullDiskAccess = fullDiskAccess
  }

  public func scan(readSandboxedPreferences: Bool = true, useCache: Bool = false) async -> [AppInfo] {
    await scanner.scan(readSandboxedPreferences: readSandboxedPreferences, useCache: useCache)
  }

  public var watchedLocations: [URL] { scanner.existingLocations }

  public func saveMetadata(_ apps: [AppInfo]) { scanner.saveMetadata(of: apps) }

  public func readValues(of apps: [AppInfo]) async -> [AppInfo] { await scanner.readValues(of: apps) }

  public enum AccessChange: Sendable { case unchanged, granted }

  /// Asks, without touching any app's data, whether Full Disk Access is held, and remembers the
  /// answer. Only a change from not held to held matters: that is when locked containers are worth
  /// reading again. Losing it is left to Refresh.
  public func checkFullDiskAccess() -> AccessChange {
    let now = fullDiskAccess.hasFullDiskAccess()
    let before = scanner.lastFullDiskAccess
    if before != now { scanner.recordFullDiskAccess(now) }
    return before == false && now ? .granted : .unchanged
  }

  public func resolveSandboxedPreferences(in apps: [AppInfo]) async -> [AppInfo] {
    await scanner.resolveSandboxedPreferences(in: apps)
  }

  /// Quits the app, writes the setting, and reopens it if it was running. Order matters: a
  /// running app can rewrite its preferences on exit, so the write happens after it is gone.
  /// With `restart: false` the value is only written and the app is left alone.
  public func setAppearance(
    _ appearance: Appearance, for app: AppInfo, restart: Bool = true
  ) async -> SetAppearanceOutcome {
    // A cached or pending sandbox flag could send the write to the wrong domain, so look again.
    let app = scanner.redetectSandbox(app)
    // Checked before quitting so a write that cannot succeed never closes the app for nothing.
    do {
      try store.preflight(for: app.target)
    } catch {
      return .failed(Self.appearanceError(error, app))
    }

    if app.isCoreService {
      return await setCoreService(appearance, app, restart: restart)
    }

    if !restart {
      do {
        try store.write(appearance, for: app.target)
        scanner.recordKnownAppearance(appearance, for: app)
        return .applied(.appliesOnNextLaunch)
      } catch {
        return .failed(Self.appearanceError(error, app))
      }
    }

    let quit = await relauncher.quit(app, timeout: quitTimeout)
    let result = Result { try store.write(appearance, for: app.target) }
    if case .success = result { scanner.recordKnownAppearance(appearance, for: app) }

    var restart: RestartStatus
    switch quit {
    case .notRunning:
      restart = .notRunning
    case .stillRunning:
      restart = .stillRunning
    case .quit:
      do {
        try await relauncher.reopen(app)
        restart = .relaunched
      } catch {
        restart = .reopenFailed(error.localizedDescription)
      }
    }

    switch result {
    case .success: return .applied(restart)
    case .failure(let error): return .failed(Self.appearanceError(error, app))
    }
  }

  /// Writes every entry that matches an installed app. Running apps are left alone and pick the
  /// value up on their next launch, so importing never closes anything.
  public func apply(settings: SettingsFile) async -> ApplyReport {
    var report = ApplyReport()
    report.rejectedLineCount = settings.rejectedLineCount
    let installed = Dictionary(
      await scanner.scan(useCache: true).map { ($0.bundleIdentifier, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    for entry in settings.entries {
      guard let listed = installed[entry.bundleIdentifier] else {
        report.missing.append(entry.bundleIdentifier)
        continue
      }
      if listed.access == .locked {  // no read, and no write that would be one
        report.failed[listed.bundleIdentifier] = .needsPermission(listed.bundleIdentifier)
        continue
      }
      let app = scanner.redetectSandbox(listed)
      if app.appearance == entry.appearance && app.access == .available {
        report.unchanged.append(app.bundleIdentifier)
        continue
      }
      do {
        try store.write(entry.appearance, for: app.target)
        scanner.recordKnownAppearance(entry.appearance, for: app)
        report.applied.append(app.bundleIdentifier)
      } catch {
        report.failed[app.bundleIdentifier] = Self.appearanceError(error, app)
      }
    }
    return report
  }

  private func setCoreService(_ appearance: Appearance, _ app: AppInfo, restart: Bool) async -> SetAppearanceOutcome {
    do {
      try store.write(appearance, for: app.target)
      scanner.recordKnownAppearance(appearance, for: app)
    } catch {
      return .failed(Self.appearanceError(error, app))
    }
    if !restart { return .applied(.appliesOnNextLaunch) }
    let terminated = await relauncher.forceTerminate(app)
    return .applied(terminated ? .restartedBySystem : .notRunning)
  }

  private static func appearanceError(_ error: Error, _ app: AppInfo) -> AppearanceError {
    error as? AppearanceError ?? .writeFailed(app.bundleIdentifier, reason: error.localizedDescription)
  }
}
