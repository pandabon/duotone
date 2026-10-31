import Foundation
import Testing
@testable import DuotoneCore

struct FakeSandbox: SandboxDetecting {
  var sandboxed: Set<String> = []
  func isSandboxed(appAt url: URL) -> Bool { sandboxed.contains(url.lastPathComponent) }
}

struct FakeStore: AppearanceStore {
  var readings: [BundleIdentifier: AppearanceReading] = [:]
  func read(for app: AppTarget) -> AppearanceReading {
    readings[app.bundleIdentifier] ?? AppearanceReading(appearance: .system, access: .available)
  }
  func write(_ appearance: Appearance, for app: AppTarget) throws {}
}

@Suite struct AppScannerTests {
  private func scanner(
    _ dirs: [AppScanner.Location], sandboxed: Set<String> = [], store: FakeStore = FakeStore(),
    excluded: Set<String> = ["x.excluded"]
  ) -> AppScanner {
    AppScanner(locations: dirs, excludedBundleIdentifiers: excluded, sandboxDetector: FakeSandbox(sandboxed: sandboxed), store: store)
  }

  @Test func findsNestedAppsButNotInsideBundles() async throws {
    let temp = try TempDirectory()
    try temp.makeApp("Apps/Top.app", id: "t.top")
    try temp.makeApp("Apps/Utilities/Deep.app", id: "t.deep")
    try temp.makeApp("Apps/Top.app/Contents/Embedded/Inner.app", id: "t.inner")
    let apps = await scanner([.init(url: temp.url.appendingPathComponent("Apps"))]).scan()
    #expect(apps.map(\.bundleIdentifier.rawValue) == ["t.deep", "t.top"])
  }

  @Test func overlappingScansAllComplete() async throws {
    let temp = try TempDirectory()
    for index in 0..<20 { try temp.makeApp("Apps/App\(index).app", id: "t.app\(index)") }
    let scanner = scanner([.init(url: temp.url.appendingPathComponent("Apps"))])
    let counts = await withTaskGroup(of: Int.self) { group in
      for _ in 0..<4 { group.addTask { await scanner.scan().count } }
      return await group.reduce(into: []) { $0.append($1) }
    }
    #expect(counts == [20, 20, 20, 20])
  }

  @Test func nonRecursiveLocationIgnoresSubfolders() async throws {
    let temp = try TempDirectory()
    try temp.makeApp("Flat/A.app", id: "t.a")
    try temp.makeApp("Flat/Sub/B.app", id: "t.b")
    let apps = await scanner([.init(url: temp.url.appendingPathComponent("Flat"), recursive: false)]).scan()
    #expect(apps.map(\.bundleIdentifier.rawValue) == ["t.a"])
  }

  @Test func dedupesByBundleIdentifierFirstLocationWins() async throws {
    let temp = try TempDirectory()
    try temp.makeApp("One/Same.app", id: "t.same")
    try temp.makeApp("Two/Renamed.app", id: "t.same")
    try temp.makeApp("Two/Same.app", id: "t.other")
    let apps = await scanner([
      .init(url: temp.url.appendingPathComponent("One")),
      .init(url: temp.url.appendingPathComponent("Two")),
    ]).scan()
    #expect(apps.count == 2)
    #expect(apps.first { $0.bundleIdentifier.rawValue == "t.same" }?.url.path.contains("/One/") == true)
  }

  @Test func sameNameDifferentIdentifierBothSurvive() async throws {
    let temp = try TempDirectory()
    try temp.makeApp("One/Twin.app", id: "t.twin1", executable: "Twin")
    try temp.makeApp("Two/Twin.app", id: "t.twin2", executable: "Twin")
    let apps = await scanner([
      .init(url: temp.url.appendingPathComponent("One")),
      .init(url: temp.url.appendingPathComponent("Two")),
    ]).scan()
    #expect(apps.count == 2)
  }

  @Test func appliesExclusions() async throws {
    let temp = try TempDirectory()
    try temp.makeApp("A/Good.app", id: "t.good")
    try temp.makeApp("A/Update Agent.app", id: "t.agent")
    try temp.makeApp("A/Install Thing.app", id: "t.install")
    try temp.makeApp("A/Excluded.app", id: "x.excluded")
    try temp.makeApp("A/BadId.app", id: "bad;id")
    try temp.makeApp("A/NoId.app", id: nil)
    try temp.makeApp("A/NoExec.app", id: "t.noexec", executable: nil)
    let apps = await scanner([.init(url: temp.url.appendingPathComponent("A"))]).scan()
    #expect(apps.map(\.bundleIdentifier.rawValue) == ["t.good"])
  }

  @Test func coreServicesWithoutIconAreSkipped() async throws {
    let temp = try TempDirectory()
    try temp.makeApp("System/Library/CoreServices/Finder.app", id: "t.finder", icon: true)
    try temp.makeApp("System/Library/CoreServices/Daemon.app", id: "t.daemon")
    let apps = await scanner([.init(url: temp.url.appendingPathComponent("System/Library/CoreServices"), recursive: false)]).scan()
    #expect(apps.map(\.bundleIdentifier.rawValue) == ["t.finder"])
    #expect(apps.first?.isCoreService == true)
  }

  @Test func sortsCaseInsensitivelyAndCarriesSandboxAndStoreState() async throws {
    let temp = try TempDirectory()
    try temp.makeApp("A/banana.app", id: "t.banana")
    try temp.makeApp("A/Apple.app", id: "t.apple")
    try temp.makeApp("A/Cherry.app", id: "t.cherry")
    let store = FakeStore(readings: [
      BundleIdentifier("t.apple")!: .init(appearance: .light, access: .available),
      BundleIdentifier("t.cherry")!: .init(appearance: .system, access: .locked),
    ])
    let apps = await scanner([.init(url: temp.url.appendingPathComponent("A"))], sandboxed: ["Cherry.app"], store: store).scan()
    #expect(apps.map(\.name) == ["Apple", "banana", "Cherry"])
    #expect(apps[0].appearance == .light)
    #expect(apps[2].isSandboxed && apps[2].access == .locked)
    #expect(!apps[1].isSandboxed)
  }

  @Test func fastScanThenResolve() async throws {
    let temp = try TempDirectory()
    try temp.makeApp("A/Boxed.app", id: "t.boxed")
    let store = FakeStore(readings: [BundleIdentifier("t.boxed")!: .init(appearance: .dark, access: .available)])
    let s = scanner([.init(url: temp.url.appendingPathComponent("A"))], sandboxed: ["Boxed.app"], store: store)
    let fast = await s.scan(readSandboxedPreferences: false)
    #expect(fast[0].isSandboxPending && !fast[0].isSandboxed)
    let resolved = await s.resolveSandboxedPreferences(in: fast)
    #expect(resolved[0].appearance == .dark)
    #expect(resolved[0].isSandboxed && !resolved[0].isSandboxPending)
  }

  @Test func missingDirectoriesAreIgnored() async {
    let apps = await scanner([.init(url: URL(fileURLWithPath: "/nonexistent/\(UUID())"))]).scan()
    #expect(apps.isEmpty)
  }

  @Test func symlinkedAppsAreFullCandidates() async throws {
    let temp = try TempDirectory()
    let real = try temp.makeApp("Cryptex/Safari.app", id: "t.safari")
    try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("Apps"), withIntermediateDirectories: true)
    let link = temp.url.appendingPathComponent("Apps/Safari.app")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let apps = await scanner([.init(url: temp.url.appendingPathComponent("Apps"))]).scan()
    #expect(apps.map(\.bundleIdentifier.rawValue) == ["t.safari"])
    #expect(apps.first?.url.lastPathComponent == "Safari.app")
    let fingerprint = AppMetadataCache.fingerprint(of: link)
    #expect(fingerprint != nil && fingerprint == AppMetadataCache.fingerprint(of: real))
  }

  @Test func hiddenFlaggedAppsAreFound() async throws {
    let temp = try TempDirectory()
    var app = try temp.makeApp("Apps/Flagged.app", id: "t.flagged")
    var values = URLResourceValues()
    values.isHidden = true
    try app.setResourceValues(values)
    try temp.makeApp("Apps/Plain.app", id: "t.plain")
    let apps = await scanner([.init(url: temp.url.appendingPathComponent("Apps"))]).scan()
    #expect(apps.map(\.bundleIdentifier.rawValue) == ["t.flagged", "t.plain"])
  }

  @Test func symlinkLoopsTerminateWithoutDuplicates() async throws {
    let temp = try TempDirectory()
    try temp.makeApp("Apps/Sub/Real.app", id: "t.real")
    let apps = temp.url.appendingPathComponent("Apps")
    try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("loop"), withDestinationURL: apps)
    try FileManager.default.createSymbolicLink(
      at: apps.appendingPathComponent("Sub/up"), withDestinationURL: URL(fileURLWithPath: "..", relativeTo: apps.appendingPathComponent("Sub")))
    try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("Loop.app"), withDestinationURL: apps)
    let found = await scanner([.init(url: apps)]).scan()
    #expect(found.map(\.bundleIdentifier.rawValue) == ["t.real"])
  }

  @Test func dotFoldersAreSkipped() async throws {
    let temp = try TempDirectory()
    try temp.makeApp("Apps/.Hidden/Secret.app", id: "t.secret")
    try temp.makeApp("Apps/.Trash/Gone.app", id: "t.gone")
    try temp.makeApp("Apps/.Dot.app", id: "t.dotapp")
    try temp.makeApp("Apps/Visible.app", id: "t.visible")
    let apps = await scanner([.init(url: temp.url.appendingPathComponent("Apps"))]).scan()
    #expect(apps.map(\.bundleIdentifier.rawValue) == ["t.visible"])
  }
}
