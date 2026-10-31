import Foundation
import Observation

public struct ScanTiming: Sendable {
  public var duration: Duration
  public var count: Int
}

/// One list entry: everything a row shows, so a row depends on nothing else.
public struct AppListItem: Sendable, Hashable, Identifiable {
  public var app: AppInfo
  public var outcome: SetAppearanceOutcome?
  public var id: BundleIdentifier { app.bundleIdentifier }
}

/// View-independent state for the app list: what is installed, what the user is looking at,
/// and what each in-flight change last did.
@MainActor @Observable
public final class AppLibrary {
  public enum Filter: String, CaseIterable, Sendable {
    case all
    case customized
    case light
    case dark
    case needsAttention
  }

  public private(set) var apps: [AppInfo] = []
  public var searchText = "" { didSet { if searchText != oldValue { recomputeVisible() } } }
  public var filter: Filter = .all { didSet { if filter != oldValue { recomputeVisible() } } }
  /// Filtered and searched, in `apps` order. Stored so views never derive it in a body.
  public private(set) var visibleItems: [AppListItem] = []
  /// Per-filter totals over all apps, ignoring the search. Updated together with `visibleItems`.
  public private(set) var counts: [Filter: Int] = [:]
  public private(set) var isLoaded = false
  /// Sandboxed apps are listed before their preferences are read; until then their state is unknown.
  public private(set) var isResolvingSandboxed = false
  public private(set) var inFlight: Set<BundleIdentifier> = []
  public private(set) var outcomes: [BundleIdentifier: SetAppearanceOutcome] = [:]
  public private(set) var lastImport: ApplyReport?

  public var visibleApps: [AppInfo] { visibleItems.map(\.app) }

  public func count(for filter: Filter) -> Int { counts[filter, default: 0] }

  /// Locked containers and the last change failing or not taking effect immediately.
  static func needsAttention(_ app: AppInfo, outcome: SetAppearanceOutcome?) -> Bool {
    if app.access == .locked { return true }
    switch outcome {
    case .failed, .applied(.stillRunning), .applied(.reopenFailed): return true
    default: return false
    }
  }

  private static func matches(_ filter: Filter, _ app: AppInfo, _ outcome: SetAppearanceOutcome?) -> Bool {
    switch filter {
    case .all: true
    case .customized: app.appearance != .system
    case .light: app.appearance == .light
    case .dark: app.appearance == .dark
    case .needsAttention: needsAttention(app, outcome: outcome)
    }
  }

  @ObservationIgnored private var lowercasedNames: [BundleIdentifier: String] = [:]
  @ObservationIgnored private var isRefreshing = false
  @ObservationIgnored private var watcher: AppFolderWatcher?
  @ObservationIgnored private var watchTask: Task<Void, Never>?
  @ObservationIgnored private var lastLightweight: ContinuousClock.Instant?
  /// Folder events never cause rescans closer together than this.
  @ObservationIgnored public var watchMinimumInterval: Duration = .seconds(5)
  @ObservationIgnored private var lastScan: ContinuousClock.Instant?
  @ObservationIgnored private let clock = ContinuousClock()
  @ObservationIgnored private let service: AppearanceService
  @ObservationIgnored private let relauncher: any AppRelauncher

  public init(service: AppearanceService, relauncher: any AppRelauncher) {
    self.service = service
    self.relauncher = relauncher
  }

  // MARK: - Loading

  /// Fast first listing; sandboxed apps are included but unresolved.
  @discardableResult
  public func loadList() async -> ScanTiming {
    let start = clock.now
    let found = await service.scan(readSandboxedPreferences: false, useCache: true)
    setApps(found)
    isLoaded = true
    isResolvingSandboxed = found.contains { $0.isSandboxPending }
    lastScan = clock.now
    // Reads that newly failed in this pass are remembered, so they are not repeated next launch.
    if !isResolvingSandboxed { await service.saveMetadata(apps) }
    return ScanTiming(duration: start.duration(to: clock.now), count: found.count)
  }

  @discardableResult
  public func resolveSandboxed() async -> ScanTiming {
    let start = clock.now
    guard isResolvingSandboxed else { return ScanTiming(duration: .zero, count: 0) }
    let resolved = await service.resolveSandboxedPreferences(in: apps)
    // Unlike a rescan this can reorder (display names replace the Info.plist ones), so it
    // follows the resolved order and keeps only what a change in flight has already updated.
    let current = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let merged = resolved.map { inFlight.contains($0.id) ? current[$0.id] ?? $0 : $0 }
    if merged != apps { setApps(merged) }
    isResolvingSandboxed = false
    await service.saveMetadata(apps)
    return ScanTiming(duration: start.duration(to: clock.now), count: resolved.filter(\.isSandboxed).count)
  }

  /// Refresh (⌘R): reads everything and ignores what the metadata cache says, so skipped locked
  /// containers and stale flags are corrected. Skipped while the first load is still resolving.
  public func refresh() async { await rescan(useCache: false) }

  /// What a folder event triggers: apps that did not change are taken from the cache.
  public func refreshIncremental() async { await rescan(useCache: true) }

  private func rescan(useCache: Bool) async {
    guard isLoaded, !isResolvingSandboxed, !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    let found = await service.scan(useCache: useCache)
    merge(found)
    lastScan = clock.now
    await service.saveMetadata(apps)
  }

  public func refreshIfStale(minimumInterval: Duration) async {
    if let lastScan, lastScan.duration(to: clock.now) < minimumInterval { return }
    await refresh()
  }

  // MARK: - Watching and activation

  public func startWatching() async {
    guard watcher == nil else { return }
    let locations = await service.watchedLocations
    let watcher = AppFolderWatcher(locations: locations) { [weak self] in
      Task { @MainActor in self?.folderChanged() }
    }
    watcher.start()
    self.watcher = watcher
  }

  public func stopWatching() {
    watcher?.stop()
    watcher = nil
    watchTask?.cancel()
  }

  /// One refresh for any number of events, and never sooner than `watchMinimumInterval` after the
  /// last scan; the wait is a single sleep started by an event, not a timer.
  public func folderChanged() {
    guard watchTask == nil else { return }
    let wait = lastScan.map { watchMinimumInterval - $0.duration(to: clock.now) } ?? .zero
    watchTask = Task {
      if wait > .zero { try? await Task.sleep(for: wait) }
      if !Task.isCancelled { await refreshIncremental() }
      watchTask = nil
    }
  }

  /// Duotone became active: no directory walk, no signature checks and no read of a container
  /// that is known to be denied. Ask whether Full Disk Access arrived, and re-read the values of
  /// the apps already listed, so changes made outside Duotone show up.
  public func refreshOnActivation(minimumInterval: Duration) async {
    guard isLoaded, !isResolvingSandboxed, !isRefreshing else { return }
    if let lastLightweight, lastLightweight.duration(to: clock.now) < minimumInterval { return }
    lastLightweight = clock.now
    await checkFullDiskAccess()
    let known = apps.filter { $0.access != .locked }
    applyUpdates(await service.readValues(of: known))
    // A read that newly failed is cached as locked, so it is never repeated.
    await service.saveMetadata(apps)
  }

  /// Only Full Disk Access going from not held to held re-reads the locked containers; whichever
  /// is still denied stays locked.
  public func checkFullDiskAccess() async {
    guard isLoaded, !isResolvingSandboxed else { return }
    guard await service.checkFullDiskAccess() == .granted else { return }
    applyUpdates(await service.readValues(of: apps.filter { $0.access == .locked }))
    await service.saveMetadata(apps)
  }

  private func applyUpdates(_ updates: [AppInfo]) {
    let byID = Dictionary(updates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var merged = apps
    for index in merged.indices {
      let id = merged[index].id
      if let updated = byID[id], !inFlight.contains(id) { merged[index] = updated }
    }
    if merged != apps { setApps(merged) }
  }

  // MARK: - Changing appearance

  public func isRunning(_ app: AppInfo) -> Bool {
    relauncher.isRunning(app)
  }

  public func setAppearance(_ appearance: Appearance, for app: AppInfo, restart: Bool = true) async {
    let id = app.id
    guard !inFlight.contains(id), let current = apps.first(where: { $0.id == id }), current.appearance != appearance
    else { return }

    inFlight.insert(id)
    setOutcome(nil, for: id)
    let outcome = await service.setAppearance(appearance, for: current, restart: restart)
    inFlight.remove(id)
    setOutcome(outcome, for: id)

    switch outcome {
    case .applied:
      // Writing worked, so whatever locked this app no longer does.
      let wasLocked = apps.first { $0.id == id }?.access == .locked
      update(id) {
        $0.appearance = appearance
        $0.access = .available
      }
      if wasLocked { await service.saveMetadata(apps) }
    case .failed(.needsPermission):
      update(id) { $0.access = .locked }
      await service.saveMetadata(apps)
    case .failed:
      break
    }
  }

  public func clearOutcome(for id: BundleIdentifier) {
    setOutcome(nil, for: id)
  }

  // MARK: - Import and export

  public func exportText() -> String {
    SettingsFile(entries: apps.map { SettingsFile.Entry(bundleIdentifier: $0.id, appearance: $0.appearance) })
      .serialized()
  }

  public func importSettings(from text: String) async -> ApplyReport {
    let report = await service.apply(settings: SettingsFile(parsing: text))
    lastImport = report
    let found = await service.scan(useCache: true)
    merge(found)
    lastScan = clock.now
    await service.saveMetadata(apps)
    return report
  }

  // MARK: - Helpers

  private func setApps(_ new: [AppInfo]) {
    apps = new
    lowercasedNames = Dictionary(new.map { ($0.id, $0.name.lowercased()) }, uniquingKeysWith: { first, _ in first })
    recompute()
  }

  private func setOutcome(_ outcome: SetAppearanceOutcome?, for id: BundleIdentifier) {
    guard outcomes[id] != outcome else { return }
    outcomes[id] = outcome
    recompute()
  }

  private func recompute() {
    var totals: [Filter: Int] = [:]
    for app in apps {
      let outcome = outcomes[app.id]
      for filter in Filter.allCases where Self.matches(filter, app, outcome) { totals[filter, default: 0] += 1 }
    }
    if totals != counts { counts = totals }
    // A filter that has emptied out has no sidebar entry any more.
    if filter == .needsAttention && totals[.needsAttention, default: 0] == 0 {
      filter = .all
    }
    recomputeVisible()
  }

  private func recomputeVisible() {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let items = apps.compactMap { app -> AppListItem? in
      let outcome = outcomes[app.id]
      guard Self.matches(filter, app, outcome),
            query.isEmpty || lowercasedNames[app.id, default: ""].contains(query)
      else { return nil }
      return AppListItem(app: app, outcome: outcome)
    }
    if items != visibleItems { visibleItems = items }
  }

  /// Keeps in-flight apps as they are so a scan that raced a change cannot undo it.
  private func merge(_ found: [AppInfo]) {
    let current = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let merged = found.map { inFlight.contains($0.id) ? current[$0.id] ?? $0 : $0 }
    if merged != apps { setApps(merged) }
  }

  private func update(_ id: BundleIdentifier, _ change: (inout AppInfo) -> Void) {
    guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
    change(&apps[index])
    recompute()
  }
}
