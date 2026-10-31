import Foundation
import Testing
@testable import DuotoneCore

@Suite struct AppearanceStoreTests {
  private let id = BundleIdentifier("local.scratch.unit")!

  private func plist(_ url: URL) -> [String: Any]? {
    (try? Data(contentsOf: url))
      .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
  }

  /// cfprefsd persists plain domains asynchronously, so wait for the file rather than assume.
  private func waitForValue(_ url: URL, _ expected: Bool?) -> Bool {
    for _ in 0..<200 {
      if plist(url)?["NSRequiresAquaSystemAppearance"] as? Bool == expected { return true }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return false
  }

  private func library(withContainer: Bool) throws -> (TempDirectory, URL, URL) {
    let temp = try TempDirectory()
    let lib = temp.url.appendingPathComponent("Library")
    let plain = lib.appendingPathComponent("Plain/\(id.rawValue).plist")
    let container = lib.appendingPathComponent("Containers/\(id.rawValue)")
    try FileManager.default.createDirectory(at: lib.appendingPathComponent("Plain"), withIntermediateDirectories: true)
    if withContainer { try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true) }
    return (temp, plain, container.appendingPathComponent("Data/Library/Preferences/\(id.rawValue).plist"))
  }

  @Test func unsandboxedWritesPlainDomainOnly() throws {
    let (temp, plain, containerPlist) = try library(withContainer: true)
    let store = PreferencesAppearanceStore(library: temp.url.appendingPathComponent("Library"))
    let target = AppTarget(bundleIdentifier: id, isSandboxed: false)

    try store.write(.light, for: target)
    #expect(waitForValue(plain, true))
    #expect(!FileManager.default.fileExists(atPath: containerPlist.path))
    #expect(store.read(for: target).appearance == .light)

    try store.write(.dark, for: target)
    #expect(store.read(for: target).appearance == .dark)

    try store.write(.system, for: target)
    #expect(waitForValue(plain, nil))
    #expect(store.read(for: target).appearance == .system)
  }

  @Test func sandboxedWritesContainerPlistOnly() throws {
    let (temp, plain, containerPlist) = try library(withContainer: true)
    let store = PreferencesAppearanceStore(library: temp.url.appendingPathComponent("Library"))
    let target = AppTarget(bundleIdentifier: id, isSandboxed: true)

    try store.write(.light, for: target)
    #expect(plist(containerPlist)?["NSRequiresAquaSystemAppearance"] as? Bool == true)
    #expect(!FileManager.default.fileExists(atPath: plain.path))
    #expect(store.read(for: target) == AppearanceReading(appearance: .light, access: .available))

    try store.write(.dark, for: target)
    #expect(store.read(for: target).appearance == .dark)
  }

  @Test func sandboxedWithoutContainerThrows() throws {
    let (temp, _, _) = try library(withContainer: false)
    let store = PreferencesAppearanceStore(library: temp.url.appendingPathComponent("Library"))
    let target = AppTarget(bundleIdentifier: id, isSandboxed: true)
    #expect(throws: AppearanceError.containerMissing(id)) { try store.write(.light, for: target) }
    #expect(store.read(for: target) == AppearanceReading(appearance: .system, access: .available))
  }

  @Test func unreadableContainerPlistIsLockedAndWriteNeedsPermission() throws {
    let (temp, _, containerPlist) = try library(withContainer: true)
    let store = PreferencesAppearanceStore(library: temp.url.appendingPathComponent("Library"))
    let target = AppTarget(bundleIdentifier: id, isSandboxed: true)
    try store.write(.light, for: target)
    let prefsDir = containerPlist.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: prefsDir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: prefsDir.path) }

    #expect(store.read(for: target).access == .locked)
    #expect(throws: AppearanceError.needsPermission(id)) { try store.write(.dark, for: target) }
  }

  @Test func preflightThrowsWithoutWriting() throws {
    let (temp, _, containerPlist) = try library(withContainer: false)
    let store = PreferencesAppearanceStore(library: temp.url.appendingPathComponent("Library"))
    let target = AppTarget(bundleIdentifier: id, isSandboxed: true)
    #expect(throws: AppearanceError.containerMissing(id)) { try store.preflight(for: target) }

    let container = containerPlist.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    try store.preflight(for: target)
    #expect(!FileManager.default.fileExists(atPath: containerPlist.path))
    try store.preflight(for: AppTarget(bundleIdentifier: id, isSandboxed: false))
  }
}
