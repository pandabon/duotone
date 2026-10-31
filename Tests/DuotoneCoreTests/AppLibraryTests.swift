import Foundation
import Testing
@testable import DuotoneCore

@MainActor @Suite struct AppLibraryTests {
  private struct Fixture {
    let temp: TempDirectory
    let store: RecordingStore
    let relauncher: FakeRelauncher
    let library: AppLibrary
  }

  private func fixture(
    readings: [BundleIdentifier: AppearanceReading] = [:], sandboxed: Set<String> = []
  ) throws -> Fixture {
    let temp = try TempDirectory()
    try temp.makeApp("A/Safari.app", id: "t.safari")
    try temp.makeApp("A/Notes.app", id: "t.notes")
    try temp.makeApp("A/Mail.app", id: "t.mail")
    let scanner = AppScanner(
      locations: [.init(url: temp.url.appendingPathComponent("A"))], excludedBundleIdentifiers: [],
      sandboxDetector: FakeSandbox(sandboxed: sandboxed), store: FakeStore(readings: readings))
    let store = RecordingStore()
    let relauncher = FakeRelauncher()
    let service = AppearanceService(scanner: scanner, store: store, relauncher: relauncher)
    return Fixture(temp: temp, store: store, relauncher: relauncher, library: AppLibrary(service: service, relauncher: relauncher))
  }

  @Test func filtersBySearchAndCustomized() async throws {
    let f = try fixture(readings: [BundleIdentifier("t.notes")!: .init(appearance: .dark, access: .available)])
    await f.library.loadList()
    await f.library.resolveSandboxed()
    #expect(f.library.visibleApps.map(\.name) == ["Mail", "Notes", "Safari"])
    f.library.searchText = "  SAF "
    #expect(f.library.visibleApps.map(\.name) == ["Safari"])
    f.library.searchText = ""
    f.library.filter = .customized
    #expect(f.library.visibleApps.map(\.name) == ["Notes"])
  }

  @Test func sandboxedAppsAreResolvedAfterTheFirstList() async throws {
    let f = try fixture(
      readings: [BundleIdentifier("t.mail")!: .init(appearance: .light, access: .locked)], sandboxed: ["Mail.app"])
    await f.library.loadList()
    #expect(f.library.isResolvingSandboxed)
    #expect(f.library.apps.allSatisfy { $0.isSandboxPending })
    await f.library.resolveSandboxed()
    #expect(!f.library.isResolvingSandboxed)
    let mail = f.library.apps.first { $0.name == "Mail" }
    #expect(mail?.appearance == .light && mail?.access == .locked)
  }

  @Test func setAppearanceUpdatesStateAndRecordsOutcome() async throws {
    let f = try fixture()
    await f.library.loadList()
    let notes = f.library.apps.first { $0.name == "Notes" }!
    await f.library.setAppearance(.dark, for: notes, restart: false)
    #expect(f.library.apps.first { $0.name == "Notes" }?.appearance == .dark)
    #expect(f.library.outcomes[notes.id] == .applied(.appliesOnNextLaunch))
    #expect(f.library.inFlight.isEmpty)
    #expect(f.store.writes.map(\.0) == [.dark])
  }

  @Test func failedChangeKeepsValueAndPermissionLocksTheApp() async throws {
    let f = try fixture()
    await f.library.loadList()
    let notes = f.library.apps.first { $0.name == "Notes" }!
    f.store.preflightFailure = .needsPermission(notes.id)
    await f.library.setAppearance(.dark, for: notes)
    let after = f.library.apps.first { $0.name == "Notes" }!
    #expect(after.appearance == .system && after.access == .locked)
    #expect(f.library.outcomes[notes.id] == .failed(.needsPermission(notes.id)))
    #expect(f.relauncher.events.isEmpty)
  }

  @Test func isRunningAsksTheRelauncher() async throws {
    let f = try fixture()
    await f.library.loadList()
    let app = f.library.apps[0]
    #expect(!f.library.isRunning(app))
    f.relauncher.running = true
    #expect(f.library.isRunning(app))
  }

  @Test func refreshAddsNewAppsAndThrottles() async throws {
    let f = try fixture()
    await f.library.loadList()
    await f.library.resolveSandboxed()
    try f.temp.makeApp("A/Zed.app", id: "t.zed")

    await f.library.refreshIfStale(minimumInterval: .seconds(60))
    #expect(f.library.apps.count == 3)
    await f.library.refreshIfStale(minimumInterval: .zero)
    #expect(f.library.apps.map(\.name) == ["Mail", "Notes", "Safari", "Zed"])
  }

  @Test func exportRoundTripsThroughSettingsFile() async throws {
    let f = try fixture(readings: [
      BundleIdentifier("t.notes")!: .init(appearance: .dark, access: .available),
      BundleIdentifier("t.mail")!: .init(appearance: .light, access: .available),
    ])
    await f.library.loadList()
    await f.library.resolveSandboxed()
    let text = f.library.exportText()
    #expect(text == """
    defaults write t.mail NSRequiresAquaSystemAppearance -bool true
    defaults write t.notes NSRequiresAquaSystemAppearance -bool false

    """)
  }

  @Test func importReportsAndRefreshes() async throws {
    let f = try fixture()
    await f.library.loadList()
    let report = await f.library.importSettings(from: """
    defaults write t.notes NSRequiresAquaSystemAppearance -bool false
    defaults write t.gone NSRequiresAquaSystemAppearance -bool true
    nonsense
    """)
    #expect(report.applied.map(\.rawValue) == ["t.notes"])
    #expect(report.missing.map(\.rawValue) == ["t.gone"])
    #expect(report.rejectedLineCount == 1)
    #expect(f.library.lastImport == report)
  }

  @Test func countsAndFiltersCoverEveryCategory() async throws {
    let f = try fixture(readings: [
      BundleIdentifier("t.notes")!: .init(appearance: .dark, access: .available),
      BundleIdentifier("t.mail")!: .init(appearance: .light, access: .available),
      BundleIdentifier("t.safari")!: .init(appearance: .system, access: .locked),
    ])
    await f.library.loadList()
    #expect(f.library.count(for: .customized) == 0, "pending apps count nowhere until resolved")
    await f.library.resolveSandboxed()
    let library = f.library
    #expect(library.count(for: .all) == 3)
    #expect(library.count(for: .customized) == 2)
    #expect(library.count(for: .light) == 1)
    #expect(library.count(for: .dark) == 1)
    #expect(library.count(for: .needsAttention) == 1)
    library.filter = .light
    #expect(library.visibleApps.map(\.name) == ["Mail"])
    library.filter = .dark
    #expect(library.visibleApps.map(\.name) == ["Notes"])
    library.filter = .needsAttention
    #expect(library.visibleApps.map(\.name) == ["Safari"])
    library.searchText = "zzz"
    #expect(library.visibleItems.isEmpty)
    #expect(library.count(for: .needsAttention) == 1, "counts ignore the search")
  }

  @Test func changesMoveAppsBetweenCountsAndEmptyFilterFallsBack() async throws {
    let f = try fixture()
    await f.library.loadList()
    await f.library.resolveSandboxed()
    let notes = f.library.apps.first { $0.name == "Notes" }!
    f.store.failure = .writeFailed(notes.id, reason: "x")
    await f.library.setAppearance(.dark, for: notes, restart: false)
    #expect(f.library.count(for: .needsAttention) == 1)
    f.library.filter = .needsAttention
    #expect(f.library.visibleItems.first?.outcome != nil)
    f.store.failure = nil
    f.library.clearOutcome(for: notes.id)
    #expect(f.library.filter == .all, "the selected Needs Attention entry vanished")
    await f.library.setAppearance(.dark, for: notes, restart: false)
    #expect(f.library.count(for: .dark) == 1 && f.library.count(for: .customized) == 1)
  }

  @Test func idsStayUniqueAndStableAcrossEveryUpdate() async throws {
    let f = try fixture(
      readings: [
        BundleIdentifier("t.notes")!: .init(appearance: .dark, access: .available),
        BundleIdentifier("t.mail")!: .init(appearance: .light, access: .locked),
      ], sandboxed: ["Mail.app"])
    let library = f.library
    func expectUnique(_ label: String) {
      let ids = library.visibleItems.map(\.id)
      #expect(Set(ids).count == ids.count, "duplicate ids after \(label)")
      let all = library.apps.map(\.id)
      #expect(Set(all).count == all.count, "duplicate app ids after \(label)")
    }

    await library.loadList()
    expectUnique("list")
    let listed = Set(library.apps.map(\.id))

    await library.resolveSandboxed()
    expectUnique("resolve")
    #expect(Set(library.apps.map(\.id)) == listed, "resolve must not add, drop or rename ids")

    try f.temp.makeApp("A/Zed.app", id: "t.zed")
    await library.refresh()
    expectUnique("rescan")
    #expect(listed.isSubset(of: Set(library.apps.map(\.id))))

    for filter in AppLibrary.Filter.allCases {
      library.filter = filter
      expectUnique("filter \(filter)")
    }
    library.searchText = "o"
    expectUnique("search")
    library.searchText = ""

    // A change while a filter is selected (the fallback itself is covered above).
    library.filter = .needsAttention
    #expect(library.count(for: .needsAttention) == 1)
    let mail = library.apps.first { $0.name == "Mail" }!
    f.store.failure = nil
    await library.setAppearance(.dark, for: mail, restart: false)
    expectUnique("change while filtered")
    #expect(library.visibleItems.allSatisfy { Set(library.apps.map(\.id)).contains($0.id) })
  }
}
