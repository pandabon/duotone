import Foundation

public struct AppearanceReading: Sendable, Hashable {
  public var appearance: Appearance
  public var access: AppAccess

  public init(appearance: Appearance, access: AppAccess) {
    self.appearance = appearance
    self.access = access
  }
}

public enum AppearanceError: Error, Sendable, Hashable {
  /// macOS refused access to the app's container (privacy / App Management).
  case needsPermission(BundleIdentifier)
  /// A sandboxed app that has never been launched has no container to write into.
  case containerMissing(BundleIdentifier)
  case writeFailed(BundleIdentifier, reason: String)
}

public protocol AppearanceStore: Sendable {
  /// Never throws: an unreadable container is reported as `.locked`.
  func read(for app: AppTarget) -> AppearanceReading
  func write(_ appearance: Appearance, for app: AppTarget) throws
  /// Throws what `write` would throw for a missing or inaccessible container, without writing.
  func preflight(for app: AppTarget) throws
}

extension AppearanceStore {
  public func preflight(for app: AppTarget) throws {}
}

/// Reads and writes `NSRequiresAquaSystemAppearance` through CFPreferences.
///
/// A sandboxed app never reads `~/Library/Preferences/<id>.plist`; it reads the copy in its
/// container, so the write has to target that file. CFPreferences accepts an absolute path
/// (without `.plist`) as the application ID, which is what `defaults write /path/to/plist` does.
public struct PreferencesAppearanceStore: AppearanceStore {
  static let key = "NSRequiresAquaSystemAppearance"

  /// Domains macOS guards with a privacy prompt (Music and TV: the Media & Apple Music permission).
  /// Merely reading one stalls for seconds and raises that prompt, so they are never read; the
  /// scanner shows the value Duotone last wrote instead. Writing is an explicit user action and stays allowed.
  public static let protectedDomains: Set<String> = ["com.apple.Music", "com.apple.TV"]

  public static func isProtected(_ id: BundleIdentifier) -> Bool { protectedDomains.contains(id.rawValue) }

  private let library: URL?

  /// - Parameter library: Overrides `~/Library`, for tests. With an override, even the plain
  ///   domain is addressed by absolute path (`<library>/Plain/<id>`) so nothing touches the real preferences.
  public init(library: URL? = nil) {
    self.library = library
  }

  public func read(for app: AppTarget) -> AppearanceReading {
    let id = app.bundleIdentifier
    if Self.isProtected(id) { return AppearanceReading(appearance: .system, access: .available) }
    guard app.isSandboxed else {
      return AppearanceReading(appearance: Self.appearance(from: Self.copyValue(domain: plainDomain(id))), access: .available)
    }
    switch Self.readPlist(at: containerPlist(id)) {
    case .missing:
      return AppearanceReading(appearance: .system, access: .available)
    case .locked:
      return AppearanceReading(appearance: .system, access: .locked)
    case .contents(let dict):
      return AppearanceReading(appearance: Self.appearance(from: dict[Self.key]), access: .available)
    }
  }

  public func preflight(for app: AppTarget) throws {
    guard app.isSandboxed, !Self.isProtected(app.bundleIdentifier) else { return }
    let id = app.bundleIdentifier
    switch Self.probe(containersRoot.appendingPathComponent(id.rawValue)) {
    case .missing: throw AppearanceError.containerMissing(id)
    case .locked: throw AppearanceError.needsPermission(id)
    case .contents: break
    }
    if case .locked = Self.readPlist(at: containerPlist(id)) { throw AppearanceError.needsPermission(id) }
  }

  public func write(_ appearance: Appearance, for app: AppTarget) throws {
    let id = app.bundleIdentifier
    if app.isSandboxed && !Self.isProtected(id) {
      try preflight(for: app)
      let preferences = containerPlist(id).deletingLastPathComponent()
      do {
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
      } catch {
        throw Self.isPermissionError(error)
          ? AppearanceError.needsPermission(id)
          : AppearanceError.writeFailed(id, reason: error.localizedDescription)
      }
    }

    let domain = app.isSandboxed ? containerPlist(id).deletingPathExtension().path : plainDomain(id)
    let value: CFPropertyList? = switch appearance {
    case .light: kCFBooleanTrue
    case .dark: kCFBooleanFalse
    case .system: nil
    }
    CFPreferencesSetAppValue(Self.key as CFString, value, domain as CFString)
    let synced = CFPreferencesAppSynchronize(domain as CFString)

    // A read-back of a protected domain would itself raise the privacy prompt, so it is skipped.
    if Self.isProtected(id) { return }

    // CFPreferences reports no reason on failure, and a denied container write can look like
    // success, so confirm against the file the app will actually read.
    if app.isSandboxed {
      // cfprefsd may flush to disk a moment after synchronize returns; poll instead of sleeping blindly.
      var result = read(for: app)
      for _ in 0..<100 where result.access == .available && result.appearance != appearance {
        Thread.sleep(forTimeInterval: 0.005)
        result = read(for: app)
      }
      if result.access == .locked { throw AppearanceError.needsPermission(id) }
      if result.appearance != appearance {
        throw AppearanceError.writeFailed(id, reason: "The value did not persist.")
      }
    } else if !synced {
      throw AppearanceError.writeFailed(id, reason: "Preferences could not be synchronized.")
    }
  }

  // MARK: - Locations

  private var libraryRoot: URL {
    library ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
  }

  private var containersRoot: URL { libraryRoot.appendingPathComponent("Containers") }

  private func plainDomain(_ id: BundleIdentifier) -> String {
    // cfprefsd rewrites any domain path containing /Library/Preferences/ to the real
    // ~/Library/Preferences, so the test layout must avoid that segment.
    library == nil ? id.rawValue : libraryRoot.appendingPathComponent("Plain/\(id.rawValue)").path
  }

  private func containerPlist(_ id: BundleIdentifier) -> URL {
    containersRoot.appendingPathComponent("\(id.rawValue)/Data/Library/Preferences/\(id.rawValue).plist")
  }

  // MARK: - Helpers

  private enum FileState {
    case missing
    case locked
    case contents([String: Any])
  }

  private static func copyValue(domain: String) -> Any? {
    CFPreferencesCopyAppValue(key as CFString, domain as CFString)
  }

  private static func appearance(from value: Any?) -> Appearance {
    guard let flag = value as? Bool else { return .system }
    return flag ? .light : .dark
  }

  private static func isPermissionError(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain {
      return ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError
    }
    return ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES))
  }

  private static func readPlist(at url: URL) -> FileState {
    do {
      let data = try Data(contentsOf: url)
      let object = try PropertyListSerialization.propertyList(from: data, format: nil)
      return .contents(object as? [String: Any] ?? [:])
    } catch {
      if isPermissionError(error) { return .locked }
      let ns = error as NSError
      // A garbled plist is not something a permission prompt fixes; treat as empty.
      return ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError ? .missing : .contents([:])
    }
  }

  /// Distinguishes absent, forbidden and present for a directory without listing it.
  private static func probe(_ url: URL) -> FileState {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      return .contents([:])
    }
    do {
      _ = try url.checkResourceIsReachable()
      return .contents([:])
    } catch {
      return isPermissionError(error) ? .locked : .missing
    }
  }
}
