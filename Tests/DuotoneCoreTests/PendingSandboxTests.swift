import Foundation
import Testing
@testable import DuotoneCore

@MainActor @Suite struct PendingSandboxTests {
  private func setup() throws -> (TempDirectory, RecordingStore, AppearanceService, AppScanner) {
    let temp = try TempDirectory()
    try temp.makeApp("A/Boxed.app", id: "t.boxed")
    try temp.makeApp("A/Plain.app", id: "t.plain")
    let scanner = AppScanner(
      locations: [.init(url: temp.url.appendingPathComponent("A"))], excludedBundleIdentifiers: [],
      sandboxDetector: FakeSandbox(sandboxed: ["Boxed.app"]), store: FakeStore(readings: [:]))
    let store = RecordingStore()
    let service = AppearanceService(scanner: scanner, store: store, relauncher: FakeRelauncher())
    return (temp, store, service, scanner)
  }

  @Test func writeToPendingAppNeverUsesTheUnknownDomain() async throws {
    let (temp, store, service, scanner) = try setup()
    defer { withExtendedLifetime(temp) {} }
    let pending = await scanner.scan(readSandboxedPreferences: false)
    #expect(pending.allSatisfy { $0.isSandboxPending })
    let boxed = try #require(pending.first { $0.name == "Boxed" })
    let outcome = await service.setAppearance(.dark, for: boxed, restart: false)
    #expect(outcome == .applied(.appliesOnNextLaunch))
    #expect(store.targets.map(\.isSandboxed) == [true])
  }

  @Test func resolvedRescanNeverReintroducesPending() async throws {
    let (temp, _, service, _) = try setup()
    defer { withExtendedLifetime(temp) {} }
    let library = AppLibrary(service: service, relauncher: FakeRelauncher())
    await library.loadList()
    #expect(library.apps.allSatisfy { $0.isSandboxPending })
    await library.resolveSandboxed()
    #expect(library.apps.allSatisfy { !$0.isSandboxPending })
    await library.refresh()
    #expect(library.apps.allSatisfy { !$0.isSandboxPending })
    #expect(library.apps.first { $0.name == "Boxed" }?.isSandboxed == true)
  }

  @Test func applySettingsUsesResolvedData() async throws {
    let (temp, store, service, _) = try setup()
    defer { withExtendedLifetime(temp) {} }
    let report = await service.apply(settings: SettingsFile(parsing: "defaults write t.boxed NSRequiresAquaSystemAppearance -bool true\n"))
    #expect(report.applied.map(\.rawValue) == ["t.boxed"])
    #expect(store.targets.map(\.isSandboxed) == [true])
  }
}
