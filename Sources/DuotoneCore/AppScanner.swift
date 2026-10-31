import Foundation

public struct AppScanner: Sendable {
  public struct Location: Sendable, Hashable {
    public var url: URL
    /// Whether to descend into non-bundle subfolders (e.g. /Applications/Utilities).
    public var recursive: Bool

    public init(url: URL, recursive: Bool = true) {
      self.url = url
      self.recursive = recursive
    }
  }

  public static let defaultExcludedBundleIdentifiers: Set<String> = ["dev.pandabon.duotone"]

  // Matched against the lowercased bundle file name; these are helpers, not user-facing apps.
  static let excludedNameKeywords = [
    "handler", "agent", "migration", "problem", "setup", "uiserver", "install", "system image", "escrow",
  ]

  public static func defaultLocations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Location] {
    func dir(_ path: String, recursive: Bool = true) -> Location {
      Location(url: URL(fileURLWithPath: path, isDirectory: true), recursive: recursive)
    }
    func homeDir(_ path: String) -> Location {
      Location(url: home.appendingPathComponent(path, isDirectory: true))
    }
    return [
      dir("/Applications"),
      homeDir("Applications"),
      homeDir("Developer/Applications"),
      dir("/Developer/Applications"),
      dir("/Network/Applications"),
      dir("/Network/Developer/Applications"),
      // Flat: its subfolders are frameworks and XPC services, not app folders.
      dir("/System/Library/CoreServices", recursive: false),
      dir("/System/Library/CoreServices/Applications"),
      dir("/Applications/Xcode.app/Contents/Applications"),
      dir("/Applications/Xcode.app/Contents/Developer/Applications"),
      dir("/Users/Shared/Applications"),
      dir("/System/Applications"),
    ]
  }

  private let locations: [Location]
  private let excludedBundleIdentifiers: Set<String>
  private let sandboxDetector: any SandboxDetecting
  private let store: any AppearanceStore
  private let cache: AppMetadataCache?

  public init(
    locations: [Location] = AppScanner.defaultLocations(),
    excludedBundleIdentifiers: Set<String> = AppScanner.defaultExcludedBundleIdentifiers,
    sandboxDetector: any SandboxDetecting = CodeSignatureSandboxDetector(),
    store: any AppearanceStore = PreferencesAppearanceStore(),
    cache: AppMetadataCache? = nil
  ) {
    self.locations = locations
    self.excludedBundleIdentifiers = excludedBundleIdentifiers
    self.sandboxDetector = sandboxDetector
    self.store = store
    self.cache = cache
  }

  /// Where the app folders are, for the folder watcher; only those that exist.
  public var existingLocations: [URL] {
    locations.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  public func redetectSandbox(_ app: AppInfo) -> AppInfo {
    let actual = sandboxDetector.isSandboxed(appAt: app.url)
    guard actual != app.isSandboxed || app.isSandboxPending else { return app }
    if actual != app.isSandboxed { cache?.correctSandbox(path: app.url.path, isSandboxed: actual) }
    var corrected = app
    corrected.isSandboxed = actual
    corrected.isSandboxPending = false
    return corrected
  }

  public var lastFullDiskAccess: Bool? { cache?.lastFullDiskAccess }

  public func recordFullDiskAccess(_ granted: Bool) { cache?.recordFullDiskAccess(granted) }

  public func saveMetadata(of apps: [AppInfo]) {
    guard let cache, !apps.contains(where: \.isSandboxPending) else { return }
    cache.save(apps.compactMap { app in
      app.fingerprint.map {
        AppMetadataCache.Entry(
          path: app.url.path, bundleIdentifier: app.bundleIdentifier.rawValue, name: app.name,
          isSandboxed: app.isSandboxed, isLocked: app.access == .locked, fingerprint: $0,
          knownAppearance: PreferencesAppearanceStore.isProtected(app.bundleIdentifier) ? app.appearance : nil)
      }
    })
  }

  /// - Parameter readSandboxedPreferences: `false` is the fast first listing: only Info.plist is
  ///   read. The Finder display name, the code-signature sandbox check and preferences are most
  ///   of a full scan's cost, so those apps come back with `isSandboxPending` set, a name taken
  ///   from Info.plist and no appearance yet; `resolveSandboxedPreferences(in:)` finishes them.
  /// - Parameter useCache: Apps whose bundle fingerprint matches the metadata cache are resolved on
  ///   the spot (name, sandbox flag) and a cached locked container is not read again. Without it
  ///   everything is read, which is what Refresh and import want.
  public func scan(readSandboxedPreferences: Bool = true, useCache: Bool = false) async -> [AppInfo] {
    await ScanGate.shared.acquire()
    let apps = await performScan(readSandboxedPreferences: readSandboxedPreferences, useCache: useCache)
    await ScanGate.shared.release()
    return apps
  }

  private func performScan(readSandboxedPreferences: Bool, useCache: Bool) async -> [AppInfo] {
    // Pass 1: cheap directory walks, one task per location.
    let candidates = await withTaskGroup(of: (Int, [URL]).self) { group in
      for (index, location) in locations.enumerated() {
        group.addTask { (index, Self.findBundles(in: location)) }
      }
      var perLocation = [[URL]](repeating: [], count: locations.count)
      for await (index, urls) in group { perLocation[index] = urls }
      // Location order decides which copy of a duplicated bundle id wins.
      return perLocation.flatMap { $0 }
    }

    // Pass 2: plist, signature and preferences, striped across a worker per core.
    let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, candidates.count))
    let parsed = await withTaskGroup(of: [(Int, AppInfo)].self) { group in
      for worker in 0..<workers {
        group.addTask {
          var found: [(Int, AppInfo)] = []
          for index in stride(from: worker, to: candidates.count, by: workers) {
            if let app = makeApp(at: candidates[index], readSandboxed: readSandboxedPreferences, useCache: useCache) { found.append((index, app)) }
          }
          return found
        }
      }
      var all: [(Int, AppInfo)] = []
      for await chunk in group { all += chunk }
      return all.sorted { $0.0 < $1.0 }.map(\.1)
    }

    var seen = Set<BundleIdentifier>()
    return parsed
      .filter { seen.insert($0.bundleIdentifier).inserted }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// Completes the pending apps (display name, sandbox, preferences); the rest are left alone.
  /// Returns every app, sorted, with `isSandboxPending` cleared.
  public func resolveSandboxedPreferences(in apps: [AppInfo]) async -> [AppInfo] {
    let store = store
    let cache = cache
    let detector = sandboxDetector
    let pending = apps.indices.filter { apps[$0].isSandboxPending }
    if pending.isEmpty { return apps }
    let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, pending.count))
    return await withTaskGroup(of: [(Int, AppInfo)].self) { group in
      for worker in 0..<workers {
        group.addTask {
          var done: [(Int, AppInfo)] = []
          for slot in stride(from: worker, to: pending.count, by: workers) {
            let index = pending[slot]
            var app = apps[index]
            app.name = Self.displayName(at: app.url)
            app.isSandboxed = detector.isSandboxed(appAt: app.url)
            app.isSandboxPending = false
            // Denied before (even if the bundle changed since): stays locked without another read,
            // which macOS would report to the user again.
            let reading = app.isSandboxed && cache?.wasLocked(path: app.url.path) == true
              ? AppearanceReading(appearance: .system, access: .locked)
              : Self.reading(for: app.target, store: store, cache: cache)
            app.appearance = reading.appearance
            app.access = reading.access
            done.append((index, app))
          }
          return done
        }
      }
      var result = apps
      for await chunk in group { for (index, app) in chunk { result[index] = app } }
      return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
  }

  /// Reads the preference values of apps that are already known; no directory walk, no signature
  /// check. A container that has become unreadable is reported as locked.
  public func readValues(of apps: [AppInfo]) async -> [AppInfo] {
    let store = store
    let cache = cache
    let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, apps.count))
    return await withTaskGroup(of: [(Int, AppInfo)].self) { group in
      for worker in 0..<workers {
        group.addTask {
          var done: [(Int, AppInfo)] = []
          for index in stride(from: worker, to: apps.count, by: workers) {
            var app = apps[index]
            let reading = Self.reading(for: app.target, store: store, cache: cache)
            app.appearance = reading.appearance
            app.access = reading.access
            done.append((index, app))
          }
          return done
        }
      }
      var result = apps
      for await chunk in group { for (index, app) in chunk { result[index] = app } }
      return result
    }
  }

  /// The only place a preference value is read. Protected domains are answered from what Duotone last
  /// wrote, so macOS's privacy prompt for them is never triggered by looking.
  private static func reading(for target: AppTarget, store: any AppearanceStore, cache: AppMetadataCache?) -> AppearanceReading {
    if PreferencesAppearanceStore.isProtected(target.bundleIdentifier) {
      let known = cache?.knownAppearance(forBundleIdentifier: target.bundleIdentifier.rawValue) ?? .system
      return AppearanceReading(appearance: known, access: .available)
    }
    return store.read(for: target)
  }

  public func recordKnownAppearance(_ appearance: Appearance, for app: AppInfo) {
    guard PreferencesAppearanceStore.isProtected(app.bundleIdentifier) else { return }
    cache?.recordKnownAppearance(appearance, forBundleIdentifier: app.bundleIdentifier.rawValue)
  }

  // MARK: - Pass 1

  static func findBundles(in location: Location) -> [URL] {
    var result: [URL] = []
    walk(location.url, recursive: location.recursive, into: &result)
    return result
  }

  /// Hidden-flagged apps count (Safari lives behind a symlink the system flags hidden); only
  /// names starting with a dot are skipped. A symlink to an app is a candidate, but a symlink to
  /// a folder is never followed, so loops cannot happen.
  private static func walk(_ directory: URL, recursive: Bool, into result: inout [URL]) {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
    guard let contents = try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: keys, options: []
    ) else { return }
    for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      if url.lastPathComponent.hasPrefix(".") { continue }
      if url.pathExtension == "app" {
        result.append(url)
      } else if recursive {
        let values = try? url.resourceValues(forKeys: Set(keys))
        if values?.isDirectory == true && values?.isSymbolicLink != true {
          walk(url, recursive: true, into: &result)
        }
      }
    }
  }

  // MARK: - Pass 2

  private func makeApp(at url: URL, readSandboxed: Bool, useCache: Bool) -> AppInfo? {
    let fileName = url.lastPathComponent.lowercased()
    if Self.excludedNameKeywords.contains(where: fileName.contains) { return nil }

    let isCoreService = url.path.contains("/CoreServices")
    let fingerprint = AppMetadataCache.fingerprint(of: url)
    if useCache, let fingerprint, let entry = cache?.entry(for: url, fingerprint: fingerprint),
       let id = BundleIdentifier(entry.bundleIdentifier), !excludedBundleIdentifiers.contains(entry.bundleIdentifier) {
      // A denied container is never read again here; Full Disk Access being granted, or Refresh, re-reads it.
      let reading = entry.isLocked
        ? AppearanceReading(appearance: .system, access: .locked)
        : Self.reading(for: AppTarget(bundleIdentifier: id, isSandboxed: entry.isSandboxed), store: store, cache: cache)
      return AppInfo(
        bundleIdentifier: id, name: entry.name, url: url, isSandboxed: entry.isSandboxed,
        isCoreService: isCoreService, appearance: reading.appearance, access: reading.access,
        fingerprint: fingerprint)
    }

    guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let rawID = plist["CFBundleIdentifier"] as? String,
          let id = BundleIdentifier(rawID),
          !excludedBundleIdentifiers.contains(rawID),
          plist["CFBundleExecutable"] is String
    else { return nil }

    // CoreServices entries without an icon are daemons with a bundle, not apps.
    if isCoreService && plist["CFBundleIconFile"] == nil && plist["CFBundleIconName"] == nil { return nil }

    let sandboxed = readSandboxed && sandboxDetector.isSandboxed(appAt: url)
    let reading: AppearanceReading
    if !readSandboxed {
      reading = AppearanceReading(appearance: .system, access: .available)
    } else if useCache && sandboxed && cache?.wasLocked(path: url.path) == true {
      reading = AppearanceReading(appearance: .system, access: .locked)  // changed bundle, still denied
    } else {
      reading = Self.reading(for: AppTarget(bundleIdentifier: id, isSandboxed: sandboxed), store: store, cache: cache)
    }
    let name = readSandboxed
      ? Self.displayName(at: url)
      : (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
        ?? url.deletingPathExtension().lastPathComponent
    return AppInfo(
      bundleIdentifier: id,
      name: name,
      url: url,
      isSandboxed: sandboxed,
      isCoreService: isCoreService,
      appearance: reading.appearance,
      access: reading.access,
      isSandboxPending: !readSandboxed,
      fingerprint: fingerprint
    )
  }

  private static func displayName(at url: URL) -> String {
    let name = FileManager.default.displayName(atPath: url.path)
    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
  }
}

/// Overlapping scans (2 x cores workers blocked in `displayName(atPath:)`) hung the test run
/// indefinitely, so scans take turns. The root cause inside the system service was not found.
private actor ScanGate {
  static let shared = ScanGate()
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if busy {
      await withCheckedContinuation { waiters.append($0) }
    } else {
      busy = true
    }
  }

  func release() {
    if waiters.isEmpty {
      busy = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}
