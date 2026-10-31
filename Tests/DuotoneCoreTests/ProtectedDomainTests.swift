import Foundation
import Testing
@testable import DuotoneCore

/// com.apple.Music is guarded by the Media & Apple Music privacy prompt; merely reading its
/// preferences stalls for seconds. These use fake stores only and never touch the real domain.
@MainActor @Suite struct ProtectedDomainTests {
  private static let music = "com.apple.Music"
  nonisolated static let protectedIDs = ["com.apple.Music", "com.apple.TV"]

  @MainActor private struct Rig {
    let temp: TempDirectory
    let cacheFile: URL
    let reads = ScriptedStore()
    let writes = RecordingStore()
    let fda = FakeFullDiskAccess()

    func cache() -> AppMetadataCache { AppMetadataCache(file: cacheFile) }

    func library(_ cache: AppMetadataCache) -> AppLibrary {
      let scanner = AppScanner(
        locations: [.init(url: temp.url.appendingPathComponent("A"))], excludedBundleIdentifiers: [],
        sandboxDetector: FakeSandbox(), store: reads, cache: cache)
      let relauncher = FakeRelauncher()
      return AppLibrary(service: AppearanceService(scanner: scanner, store: writes, relauncher: relauncher, fullDiskAccess: fda), relauncher: relauncher)
    }
  }

  private func rig() throws -> Rig {
    let temp = try TempDirectory()
    try temp.makeApp("A/Music.app", id: Self.music)
    try temp.makeApp("A/TV.app", id: "com.apple.TV")
    try temp.makeApp("A/Other.app", id: "t.other")
    return Rig(temp: temp, cacheFile: temp.url.appendingPathComponent("cache/apps.plist"))
  }

  private func loaded(_ library: AppLibrary) async {
    await library.loadList()
    await library.resolveSandboxed()
  }

  @Test func nothingEverReadsTheProtectedDomain() async throws {
    let r = try rig()
    let cache = r.cache()
    let library = r.library(cache)
    await loaded(library)                                   // first pass and resolve
    await library.refresh()                                 // Refresh: full scan
    await library.refreshIncremental()                      // folder event
    await library.refreshOnActivation(minimumInterval: .zero)  // activation re-read
    await library.checkFullDiskAccess()                     // Full Disk Access check
    _ = await library.importSettings(from: "defaults write t.other NSRequiresAquaSystemAppearance -bool true\n")

    let second = r.library(r.cache())                       // a launch from the cache
    await loaded(second)

    for id in Self.protectedIDs {
      #expect(r.reads.reads(id) == 0, "\(id)")
      #expect(!r.reads.probes.contains(id), "\(id)")
    }
    #expect(r.reads.reads("t.other") > 0, "other apps are still read")
  }

  @Test(arguments: ProtectedDomainTests.protectedIDs)
  func theLastValueDuotoneWroteIsShownAndSurvivesAChangedFingerprint(id: String) async throws {
    let r = try rig()
    let first = r.library(r.cache())
    await loaded(first)
    let music = try #require(first.apps.first { $0.id.rawValue == id })
    #expect(music.appearance == .system)
    await first.setAppearance(.dark, for: music, restart: false)
    #expect(r.writes.writes.map(\.0) == [.dark], "writing stays allowed")
    #expect(first.apps.first { $0.id.rawValue == id }?.appearance == .dark)

    let second = r.library(r.cache())
    await loaded(second)
    #expect(second.apps.first { $0.id.rawValue == id }?.appearance == .dark)

    // Info.plist rewritten: the entry no longer matches, but the value is kept by bundle id.
    try r.temp.makeApp("A/\(id == "com.apple.TV" ? "TV" : "Music").app", id: id, icon: true)
    let third = r.library(r.cache())
    await third.loadList()
    #expect(third.apps.first { $0.id.rawValue == id }?.isSandboxPending == true)
    await third.resolveSandboxed()
    #expect(third.apps.first { $0.id.rawValue == id }?.appearance == .dark)
    #expect(r.reads.reads(id) == 0)
  }

  @Test(arguments: ProtectedDomainTests.protectedIDs)
  func importComparesWithTheKnownValueAndNeverReads(id: String) async throws {
    let r = try rig()
    let library = r.library(r.cache())
    await loaded(library)
    let music = try #require(library.apps.first { $0.id.rawValue == id })
    await library.setAppearance(.dark, for: music, restart: false)
    let written = r.writes.writes.count

    let same = await library.importSettings(from: "defaults write \(id) NSRequiresAquaSystemAppearance -bool false\n")
    #expect(same.unchanged.map(\.rawValue) == [id])
    #expect(r.writes.writes.count == written, "an unchanged protected app is not written")

    let different = await library.importSettings(from: "defaults write \(id) NSRequiresAquaSystemAppearance -bool true\n")
    #expect(different.applied.map(\.rawValue) == [id])
    #expect(r.writes.writes.count == written + 1)
    #expect(library.apps.first { $0.id.rawValue == id }?.appearance == .light)
    #expect(r.reads.reads(id) == 0)
  }

  @Test func theRealStoreAnswersWithoutTouchingPreferences() throws {
    let temp = try TempDirectory()
    let lib = temp.url.appendingPathComponent("lib")
    let store = PreferencesAppearanceStore(library: lib)
    for id in Self.protectedIDs {
      for sandboxed in [false, true] {
        let target = AppTarget(bundleIdentifier: BundleIdentifier(id)!, isSandboxed: sandboxed)
        #expect(store.read(for: target) == AppearanceReading(appearance: .system, access: .available))
        try store.preflight(for: target)  // no container probe either
      }
    }
    #expect(!FileManager.default.fileExists(atPath: lib.path))
  }
}
