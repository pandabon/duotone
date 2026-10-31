import Foundation

/// Whether Duotone can read and change an app's preferences.
public enum AppAccess: Sendable, Hashable {
  case available
  /// A sandboxed app whose container the system will not let Duotone read or write.
  case locked
}

/// What the store needs to know to find an app's preferences.
public struct AppTarget: Sendable, Hashable {
  public var bundleIdentifier: BundleIdentifier
  public var isSandboxed: Bool

  public init(bundleIdentifier: BundleIdentifier, isSandboxed: Bool) {
    self.bundleIdentifier = bundleIdentifier
    self.isSandboxed = isSandboxed
  }
}

public struct AppInfo: Sendable, Hashable, Identifiable {
  public var bundleIdentifier: BundleIdentifier
  /// Localized display name, without the `.app` suffix.
  public var name: String
  public var url: URL
  /// Meaningless while `isSandboxPending`; never write through `target` in that state.
  public var isSandboxed: Bool
  /// The fast first scan skips code-signature detection; until it is resolved, `appearance`
  /// is only what the plain preferences domain says.
  public var isSandboxPending: Bool
  /// Lives in CoreServices; launchd restarts these, so they cannot be quit and reopened.
  public var isCoreService: Bool
  public var appearance: Appearance
  public var access: AppAccess
  /// Set by the scanner; what the metadata cache is keyed on.
  public var fingerprint: AppMetadataCache.Fingerprint?

  public var id: BundleIdentifier { bundleIdentifier }
  public var target: AppTarget { AppTarget(bundleIdentifier: bundleIdentifier, isSandboxed: isSandboxed) }

  public init(
    bundleIdentifier: BundleIdentifier,
    name: String,
    url: URL,
    isSandboxed: Bool,
    isCoreService: Bool,
    appearance: Appearance,
    access: AppAccess,
    isSandboxPending: Bool = false,
    fingerprint: AppMetadataCache.Fingerprint? = nil
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.name = name
    self.url = url
    self.isSandboxed = isSandboxed
    self.isSandboxPending = isSandboxPending
    self.isCoreService = isCoreService
    self.appearance = appearance
    self.access = access
    self.fingerprint = fingerprint
  }
}
