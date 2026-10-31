import Foundation

/// What a scan learned about each app that is expensive to learn again: its Finder display name,
/// whether it is sandboxed (a code-signature read) and whether its container was denied. An entry
/// is only trusted while the bundle's fingerprint (stat calls only) is unchanged.
///
/// Disk writes are deliberate: `save` writes atomically and only when the serialized content
/// differs from what is already on disk, so a launch where nothing changed writes nothing.
public final class AppMetadataCache: @unchecked Sendable {
  public struct Fingerprint: Codable, Hashable, Sendable {
    public var infoModified: Double
    public var infoSize: Int64
    /// Nil when the bundle is unsigned, which is a valid state to compare against.
    public var signatureModified: Double?
  }

  public struct Entry: Codable, Hashable, Sendable {
    public var path: String
    public var bundleIdentifier: String
    public var name: String
    public var isSandboxed: Bool
    public var isLocked: Bool
    public var fingerprint: Fingerprint
    /// For apps whose preferences Duotone must not read (`PreferencesAppearanceStore.protectedDomains`):
    /// the last value Duotone itself set, kept by bundle id across fingerprint changes.
    public var knownAppearance: Appearance?
  }

  public typealias Writer = @Sendable (Data, URL) throws -> Void

  static let version = 2

  private struct File: Codable {
    var version: Int
    var apps: [Entry]
    /// Whether Full Disk Access was held when last checked, so a grant made between launches is noticed.
    var fullDiskAccess: Bool?
  }

  public static var defaultFile: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Caches/dev.pandabon.duotone/apps.plist")
  }

  public static let atomicWriter: Writer = { data, url in
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }

  private let file: URL
  private let writer: Writer
  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var onDisk: Data?
  private var fullDiskAccess: Bool?

  /// A missing, unreadable, corrupt or other-version file is the same as an empty cache.
  public init(file: URL = AppMetadataCache.defaultFile, writer: @escaping Writer = AppMetadataCache.atomicWriter) {
    self.file = file
    self.writer = writer
    guard let data = try? Data(contentsOf: file),
          let decoded = try? PropertyListDecoder().decode(File.self, from: data),
          decoded.version == Self.version
    else { return }
    onDisk = data
    fullDiskAccess = decoded.fullDiskAccess
    entries = Dictionary(decoded.apps.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
  }

  public static func fingerprint(of app: URL) -> Fingerprint? {
    func stat(_ path: String) -> (modified: Double, size: Int64)? {
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let date = attributes[.modificationDate] as? Date
      else { return nil }
      return (date.timeIntervalSince1970, (attributes[.size] as? NSNumber)?.int64Value ?? 0)
    }
    guard let info = stat(app.appendingPathComponent("Contents/Info.plist").path) else { return nil }
    let signature = stat(app.appendingPathComponent("Contents/_CodeSignature/CodeResources").path)
    return Fingerprint(infoModified: info.modified, infoSize: info.size, signatureModified: signature?.modified)
  }

  /// The entry for `url`, only if it was recorded for exactly this fingerprint.
  public func entry(for url: URL, fingerprint: Fingerprint) -> Entry? {
    lock.withLock {
      guard let entry = entries[url.path], entry.fingerprint == fingerprint else { return nil }
      return entry
    }
  }

  /// Replaces the cache with `apps` (anything no longer present is dropped) and writes if, and
  /// only if, that differs from the file. Returns whether a write happened.
  @discardableResult
  public func save(_ apps: [Entry]) -> Bool {
    lock.withLock { persist(Dictionary(apps.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }), fullDiskAccess) }
  }

  public var lastFullDiskAccess: Bool? { lock.withLock { fullDiskAccess } }

  public func recordFullDiskAccess(_ granted: Bool) {
    lock.withLock { _ = persist(entries, granted) }
  }

  /// Whether this app's container was denied when last read, whatever its fingerprint is now.
  public func wasLocked(path: String) -> Bool {
    lock.withLock { entries[path]?.isLocked == true }
  }

  /// Caller holds the lock.
  private func persist(_ new: [String: Entry], _ access: Bool?) -> Bool {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let file = File(version: Self.version, apps: new.values.sorted { $0.path < $1.path }, fullDiskAccess: access)
    guard let data = try? encoder.encode(file), data != onDisk else { return false }
    do {
      try writer(data, self.file)
    } catch {
      return false  // a cache that cannot be written is only a slower next launch
    }
    onDisk = data
    entries = new
    fullDiskAccess = access
    return true
  }

  public func knownAppearance(forBundleIdentifier id: String) -> Appearance? {
    lock.withLock { entries.values.first { $0.bundleIdentifier == id }?.knownAppearance }
  }

  /// Written when Duotone changes a protected app; a write only if the value actually differs.
  public func recordKnownAppearance(_ appearance: Appearance, forBundleIdentifier id: String) {
    let updated: [Entry] = lock.withLock {
      var changed = false
      let all = entries.values.map { entry -> Entry in
        guard entry.bundleIdentifier == id, entry.knownAppearance != appearance else { return entry }
        changed = true
        var copy = entry
        copy.knownAppearance = appearance
        return copy
      }
      return changed ? all : []
    }
    if !updated.isEmpty { save(updated) }
  }

  /// The signature check found a different answer than the cache held.
  public func correctSandbox(path: String, isSandboxed: Bool) {
    let updated: [Entry] = lock.withLock {
      guard var entry = entries[path], entry.isSandboxed != isSandboxed else { return [] }
      entry.isSandboxed = isSandboxed
      return entries.values.map { $0.path == path ? entry : $0 }
    }
    if !updated.isEmpty { save(updated) }
  }
}
