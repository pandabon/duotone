import CoreServices
import Foundation
import Testing
@testable import DuotoneCore

/// A store whose containers can be locked, opened or removed while the test runs.
final class ScriptedStore: AppearanceStore, @unchecked Sendable {
  enum State { case open(Appearance), locked, missing }
  private let lock = NSLock()
  private var states: [String: State] = [:]
  private var _reads: [String: Int] = [:]
  private var _probes: [String] = []

  func set(_ id: String, _ state: State) { lock.withLock { states[id] = state } }
  func reads(_ id: String) -> Int { lock.withLock { _reads[id, default: 0] } }
  var probes: [String] { lock.withLock { _probes } }

  func read(for app: AppTarget) -> AppearanceReading {
    let id = app.bundleIdentifier.rawValue
    return lock.withLock {
      _reads[id, default: 0] += 1
      switch states[id] ?? .open(.system) {
      case .open(let appearance): return AppearanceReading(appearance: appearance, access: .available)
      case .locked: return AppearanceReading(appearance: .system, access: .locked)
      case .missing: return AppearanceReading(appearance: .system, access: .available)
      }
    }
  }

  func write(_ appearance: Appearance, for app: AppTarget) throws {
    set(app.bundleIdentifier.rawValue, .open(appearance))
  }

  func preflight(for app: AppTarget) throws {
    let id = app.bundleIdentifier.rawValue
    let state = lock.withLock { () -> State in
      _probes.append(id)
      return states[id] ?? .open(.system)
    }
    switch state {
    case .open: return
    case .locked: throw AppearanceError.needsPermission(app.bundleIdentifier)
    case .missing: throw AppearanceError.containerMissing(app.bundleIdentifier)
    }
  }
}

final class FakeFullDiskAccess: FullDiskAccessChecking, @unchecked Sendable {
  private let lock = NSLock()
  private var _granted = false
  var granted: Bool {
    get { lock.withLock { _granted } }
    set { lock.withLock { _granted = newValue } }
  }
  func hasFullDiskAccess() -> Bool { granted }
}

final class WriteCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var _count = 0
  var count: Int { lock.withLock { _count } }
  var writer: AppMetadataCache.Writer {
    { [self] data, url in
      lock.withLock { _count += 1 }
      try AppMetadataCache.atomicWriter(data, url)
    }
  }
}

@MainActor @Suite struct MetadataCacheTests {
  @MainActor private struct Rig {
    let temp: TempDirectory
    let cacheFile: URL
    let counter = WriteCounter()
    let store = ScriptedStore()
    let fda = FakeFullDiskAccess()

    func cache() -> AppMetadataCache { AppMetadataCache(file: cacheFile, writer: counter.writer) }

    func scanner(_ cache: AppMetadataCache, sandboxed: Set<String> = []) -> AppScanner {
      AppScanner(
        locations: [.init(url: temp.url.appendingPathComponent("A"))], excludedBundleIdentifiers: [],
        sandboxDetector: FakeSandbox(sandboxed: sandboxed), store: store, cache: cache)
    }

    func library(_ cache: AppMetadataCache, sandboxed: Set<String>) -> AppLibrary {
      let relauncher = FakeRelauncher()
      let service = AppearanceService(
        scanner: scanner(cache, sandboxed: sandboxed), store: store, relauncher: relauncher, fullDiskAccess: fda)
      return AppLibrary(service: service, relauncher: relauncher)
    }
  }

  private func rig(_ names: [String] = ["Alpha", "Bravo", "Charlie"]) throws -> Rig {
    let temp = try TempDirectory()
    for name in names { try temp.makeApp("A/\(name).app", id: "t.\(name.lowercased())") }
    return Rig(temp: temp, cacheFile: temp.url.appendingPathComponent("cache/apps.plist"))
  }

  // MARK: - The file

  @Test func missingCorruptAndWrongVersionFilesAreEmpty() throws {
    let r = try rig()
    let app = r.temp.url.appendingPathComponent("A/Alpha.app")
    let fingerprint = try #require(AppMetadataCache.fingerprint(of: app))
    #expect(r.cache().entry(for: app, fingerprint: fingerprint) == nil)

    try FileManager.default.createDirectory(at: r.cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a plist".utf8).write(to: r.cacheFile)
    #expect(r.cache().entry(for: app, fingerprint: fingerprint) == nil)

    let wrong = try PropertyListSerialization.data(fromPropertyList: ["version": 99, "apps": [Any]()], format: .binary, options: 0)
    try wrong.write(to: r.cacheFile)
    let cache = r.cache()
    #expect(cache.entry(for: app, fingerprint: fingerprint) == nil)
    #expect(cache.save([]), "a bad file is replaced by the first real save")
  }

  @Test func unchangedRescanWritesNothingAndRemovedAppsAreDropped() async throws {
    let r = try rig()
    let cache = r.cache()
    let scanner = r.scanner(cache)
    var apps = await scanner.scan()
    scanner.saveMetadata(of: apps)
    #expect(r.counter.count == 1)

    for _ in 0..<3 {
      apps = await scanner.scan(readSandboxedPreferences: false, useCache: true)
      scanner.saveMetadata(of: apps)
    }
    #expect(r.counter.count == 1, "an unchanged scan must not touch the disk")

    // A new process sees the same file and also writes nothing.
    let second = r.cache()
    let secondScanner = r.scanner(second)
    secondScanner.saveMetadata(of: await secondScanner.scan(readSandboxedPreferences: false, useCache: true))
    #expect(r.counter.count == 1)

    let before = await secondScanner.scan(readSandboxedPreferences: false, useCache: true)
    let bravo = try #require(before.first { $0.name == "Bravo" })
    let charlie = try #require(before.first { $0.name == "Charlie" })
    try FileManager.default.removeItem(at: charlie.url)
    secondScanner.saveMetadata(of: await secondScanner.scan(useCache: true))
    #expect(r.counter.count == 2, "a real change writes once")
    #expect(second.entry(for: bravo.url, fingerprint: try #require(bravo.fingerprint)) != nil)
    #expect(second.entry(for: charlie.url, fingerprint: try #require(charlie.fingerprint)) == nil, "removed apps are dropped")
  }

  // MARK: - First pass

  @Test func matchingAppsAreResolvedInTheFirstPassAndChangedOnesStayPending() async throws {
    let r = try rig()
    let cache = r.cache()
    let scanner = r.scanner(cache, sandboxed: ["Bravo.app"])
    scanner.saveMetadata(of: await scanner.scan())

    var first = await scanner.scan(readSandboxedPreferences: false, useCache: true)
    #expect(first.allSatisfy { !$0.isSandboxPending })
    #expect(first.first { $0.name == "Bravo" }?.isSandboxed == true)

    // Rewriting Info.plist changes the fingerprint, so that app goes the slow way again.
    try r.temp.makeApp("A/Alpha.app", id: "t.alpha", icon: true)
    first = await scanner.scan(readSandboxedPreferences: false, useCache: true)
    #expect(first.first { $0.name == "Alpha" }?.isSandboxPending == true)
    #expect(first.first { $0.name == "Bravo" }?.isSandboxPending == false)
    let resolved = await scanner.resolveSandboxedPreferences(in: first)
    #expect(resolved.allSatisfy { !$0.isSandboxPending })
  }

  // MARK: - Safety

  @Test func aStaleCachedSandboxFlagStillWritesToTheContainer() async throws {
    let r = try rig(["Boxed"])
    let cache = r.cache()
    // Cached while the app was not sandboxed...
    let plain = r.scanner(cache, sandboxed: [])
    plain.saveMetadata(of: await plain.scan())
    // ...then it became sandboxed without the fingerprint changing.
    let scanner = r.scanner(cache, sandboxed: ["Boxed.app"])
    let listed = await scanner.scan(readSandboxedPreferences: false, useCache: true)
    let app = try #require(listed.first)
    #expect(!app.isSandboxed, "the cache is stale, as set up")

    let recorder = RecordingStore()
    let service = AppearanceService(scanner: scanner, store: recorder, relauncher: FakeRelauncher())
    let outcome = await service.setAppearance(.dark, for: app, restart: false)
    #expect(outcome == .applied(.appliesOnNextLaunch))
    #expect(recorder.targets.map(\.isSandboxed) == [true])
    let fingerprint = try #require(app.fingerprint)
    #expect(cache.entry(for: app.url, fingerprint: fingerprint)?.isSandboxed == true, "the cache is corrected")

    let imported = await service.apply(settings: SettingsFile(parsing: "defaults write t.boxed NSRequiresAquaSystemAppearance -bool true\n"))
    #expect(imported.applied.map(\.rawValue) == ["t.boxed"])
    #expect(recorder.targets.map(\.isSandboxed) == [true, true])
  }

  // MARK: - Locked containers

  /// A first launch that finds all three containers locked, then a second launch from the cache.
  private func lockedSecondLaunch(_ r: Rig) async throws -> AppLibrary {
    for id in ["t.alpha", "t.bravo", "t.charlie"] { r.store.set(id, .locked) }
    let firstLaunch = r.library(r.cache(), sandboxed: ["Alpha.app", "Bravo.app", "Charlie.app"])
    await firstLaunch.loadList()
    await firstLaunch.resolveSandboxed()
    await firstLaunch.checkFullDiskAccess()  // as at launch: records that access is not held
    #expect(firstLaunch.count(for: .needsAttention) == 3)

    let second = r.library(r.cache(), sandboxed: ["Alpha.app", "Bravo.app", "Charlie.app"])
    let before = ["t.alpha", "t.bravo", "t.charlie"].map(r.store.reads)
    await second.loadList()
    #expect(["t.alpha", "t.bravo", "t.charlie"].map(r.store.reads) == before, "locked containers are not read again")
    #expect(second.count(for: .needsAttention) == 3)
    #expect(!second.isResolvingSandboxed)
    return second
  }

  private let lockedIDs = ["t.alpha", "t.bravo", "t.charlie"]

  @Test func cachedLaunchAndActivationNeverReadLockedContainers() async throws {
    let r = try rig()
    let library = try await lockedSecondLaunch(r)
    let before = lockedIDs.map(r.store.reads)
    await library.checkFullDiskAccess()
    await library.refreshOnActivation(minimumInterval: .zero)
    await library.refreshOnActivation(minimumInterval: .zero)
    #expect(lockedIDs.map(r.store.reads) == before)
    #expect(r.store.probes.isEmpty, "nothing probes a container either")
    #expect(library.count(for: .needsAttention) == 3)
  }

  @Test func grantingFullDiskAccessRereadsLockedAppsOnceAndPartialDenialStaysLocked() async throws {
    let r = try rig()
    let library = try await lockedSecondLaunch(r)     // the cache holds "no Full Disk Access"
    await library.checkFullDiskAccess()               // still none: nothing happens
    let before = lockedIDs.map(r.store.reads)

    r.fda.granted = true
    r.store.set("t.alpha", .open(.light))             // Bravo and Charlie are still denied
    await library.checkFullDiskAccess()
    #expect(r.store.reads("t.alpha") == before[0] + 1)
    #expect(r.store.reads("t.bravo") == before[1] + 1)
    #expect(library.apps.first { $0.name == "Alpha" }?.access == .available)
    #expect(library.apps.first { $0.name == "Alpha" }?.appearance == .light)
    #expect(library.apps.filter { $0.access == .locked }.map(\.name) == ["Bravo", "Charlie"])
    #expect(library.count(for: .needsAttention) == 2)

    // Unchanged since: no further reads, at activation or otherwise.
    let after = lockedIDs.map(r.store.reads)
    await library.checkFullDiskAccess()
    await library.refreshOnActivation(minimumInterval: .zero)
    #expect(r.store.reads("t.bravo") == after[1] && r.store.reads("t.charlie") == after[2])
  }

  @Test func aGrantMadeBetweenLaunchesIsCaughtAtTheNextLaunch() async throws {
    let r = try rig()
    _ = try await lockedSecondLaunch(r)               // records "no Full Disk Access" in the cache
    r.fda.granted = true
    r.store.set("t.bravo", .open(.dark))
    let next = r.library(r.cache(), sandboxed: ["Alpha.app", "Bravo.app", "Charlie.app"])
    await next.loadList()
    await next.checkFullDiskAccess()
    #expect(next.apps.first { $0.name == "Bravo" }?.access == .available)
    #expect(next.apps.first { $0.name == "Alpha" }?.access == .locked)
  }

  @Test func lockedStatusSurvivesAChangedFingerprintWithoutARead() async throws {
    let r = try rig()
    _ = try await lockedSecondLaunch(r)
    let before = r.store.reads("t.alpha")
    try r.temp.makeApp("A/Alpha.app", id: "t.alpha", icon: true)  // new fingerprint
    let next = r.library(r.cache(), sandboxed: ["Alpha.app", "Bravo.app", "Charlie.app"])
    await next.loadList()
    #expect(next.apps.first { $0.name == "Alpha" }?.isSandboxPending == true)
    await next.resolveSandboxed()
    #expect(next.apps.first { $0.name == "Alpha" }?.access == .locked)
    await next.refreshIncremental()
    #expect(r.store.reads("t.alpha") == before)
  }

  @Test func aNewAppIsReadOnceAndThenRemembered() async throws {
    let r = try rig()
    let library = try await lockedSecondLaunch(r)
    r.store.set("t.delta", .locked)
    try r.temp.makeApp("A/Delta.app", id: "t.delta")
    let sandboxed: Set<String> = ["Alpha.app", "Bravo.app", "Charlie.app", "Delta.app"]
    let next = r.library(r.cache(), sandboxed: sandboxed)
    await next.loadList()
    await next.resolveSandboxed()
    #expect(r.store.reads("t.delta") == 1)
    #expect(next.apps.first { $0.name == "Delta" }?.access == .locked)
    await next.refreshIncremental()
    await next.refreshOnActivation(minimumInterval: .zero)
    let again = r.library(r.cache(), sandboxed: sandboxed)
    await again.loadList()
    #expect(r.store.reads("t.delta") == 1, "classified once, never again without Refresh")
    _ = library
  }

  @Test func aReadThatNewlyFailsIsCachedAsLocked() async throws {
    let r = try rig()
    let first = r.library(r.cache(), sandboxed: ["Alpha.app", "Bravo.app", "Charlie.app"])
    await first.loadList()
    await first.resolveSandboxed()
    #expect(first.count(for: .needsAttention) == 0)
    r.store.set("t.bravo", .locked)
    await first.refreshOnActivation(minimumInterval: .zero)  // reads the non-locked apps, sees the denial
    #expect(first.apps.first { $0.name == "Bravo" }?.access == .locked)
    let reads = r.store.reads("t.bravo")
    let next = r.library(r.cache(), sandboxed: ["Alpha.app", "Bravo.app", "Charlie.app"])
    await next.loadList()
    #expect(next.apps.first { $0.name == "Bravo" }?.access == .locked)
    #expect(r.store.reads("t.bravo") == reads, "the next launch does not read it again")
  }

  @Test func oneSuccessfulWriteClearsThatAppAtOnce() async throws {
    let r = try rig()
    let library = try await lockedSecondLaunch(r)
    r.store.set("t.bravo", .open(.system))  // access arrived, but nothing has noticed yet
    let bravo = try #require(library.apps.first { $0.name == "Bravo" })
    await library.setAppearance(.dark, for: bravo, restart: false)
    #expect(library.apps.first { $0.name == "Bravo" }?.access == .available)
    #expect(library.count(for: .needsAttention) == 2)
  }

  @Test func refreshReadsEverythingButImportAndIncrementalRescansDoNot() async throws {
    let r = try rig()
    let library = try await lockedSecondLaunch(r)
    r.store.set("t.charlie", .open(.dark))
    let before = lockedIDs.map(r.store.reads)

    await library.refreshIncremental()
    _ = await library.importSettings(from: "defaults write t.alpha NSRequiresAquaSystemAppearance -bool true\n")
    #expect(lockedIDs.map(r.store.reads) == before, "neither reads a locked container")
    #expect(library.lastImport?.failed.keys.map(\.rawValue) == ["t.alpha"], "a locked app in an import is reported, not written")
    #expect(library.apps.first { $0.name == "Charlie" }?.access == .locked)

    await library.refresh()
    #expect(lockedIDs.map(r.store.reads).enumerated().allSatisfy { $0.element > before[$0.offset] }, "Refresh reads all")
    #expect(library.apps.first { $0.name == "Charlie" }?.access == .available)
    #expect(library.count(for: .needsAttention) == 2)
  }

  // MARK: - Folder events

  @Test func eventsThatDoNotChangeABundleAreIgnored() {
    let roots = ["/Applications"]
    let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
    let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
    func relevant(_ path: String, _ flags: FSEventStreamEventFlags) -> Bool {
      AppFolderWatcher.isRelevant(path: path, flags: flags, roots: roots)
    }
    #expect(relevant("/Applications/New.app", created))
    #expect(!relevant("/Applications/New.app", modified), "touching a bundle is not a new app")
    #expect(relevant("/Applications/Foo.app/Contents/Info.plist", modified))
    #expect(relevant("/Applications/Foo.app/Contents/_CodeSignature/CodeResources", modified))
    #expect(!relevant("/Applications/Foo.app/Contents/MacOS/Foo", modified))
    #expect(!relevant("/Applications/Foo.app/Contents/Resources/cache.db", created))
    #expect(!relevant("/Applications/Foo.app/Contents/Library/LoginItems/Helper.app", created), "nested helpers")
    #expect(!relevant("/Applications/Foo.app/Contents/Library/LoginItems/Helper.app/Contents/Info.plist", modified))
    #expect(!relevant("/Applications/Notes.txt", created))
  }

  @Test func manyEventsCauseOneRescan() async throws {
    let r = try rig(["Alpha"])
    let library = r.library(r.cache(), sandboxed: [])
    library.watchMinimumInterval = .milliseconds(50)
    await library.loadList()
    await library.resolveSandboxed()
    let before = r.store.reads("t.alpha")
    for _ in 0..<5 { library.folderChanged() }
    // Scans take turns process-wide, so a busy neighbour test can delay this one.
    for _ in 0..<150 where r.store.reads("t.alpha") == before { try await Task.sleep(for: .milliseconds(20)) }
    try await Task.sleep(for: .milliseconds(300))
    #expect(r.store.reads("t.alpha") == before + 1)
  }

  // MARK: - Measured cost (printed, loosely asserted)

  @Test func timings() async throws {
    let names = (0..<160).map { "App\($0)" }
    let r = try rig(names)
    let sandboxed = Set(names.indices.filter { $0 % 2 == 0 }.map { "App\($0).app" })
    let clock = ContinuousClock()

    // The first pass without a cache, and a cache built from it without the Finder-name lookups.
    let cold = r.scanner(r.cache(), sandboxed: sandboxed)
    var listed: [AppInfo] = []
    let coldTime = await clock.measure { listed = await cold.scan(readSandboxedPreferences: false) }
    r.cache().save(listed.map {
      .init(path: $0.url.path, bundleIdentifier: $0.bundleIdentifier.rawValue, name: $0.name,
            isSandboxed: sandboxed.contains($0.url.lastPathComponent), isLocked: false, fingerprint: $0.fingerprint!)
    })

    let warm = r.scanner(r.cache(), sandboxed: sandboxed)
    var apps: [AppInfo] = []
    let warmTime = await clock.measure { apps = await warm.scan(readSandboxedPreferences: false, useCache: true) }
    #expect(apps.count == 160 && apps.allSatisfy { !$0.isSandboxPending })

    let reread = await clock.measure { _ = await warm.readValues(of: apps) }
    print("TIMING first pass without cache: \(coldTime), with cache hits: \(warmTime), activation re-read of 160 apps (fake store): \(reread)")
    #expect(warmTime < .seconds(10), "a sanity bound only; scans take turns process-wide")
  }
}
