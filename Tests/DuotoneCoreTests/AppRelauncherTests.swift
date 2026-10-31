import Foundation
import Testing
@testable import DuotoneCore

@MainActor
final class FakeProcess: RunningProcess {
  var isTerminated = false
  var terminateCalls = 0
  var forceCalls = 0
  /// Whether `terminate()` makes the process exit (false models an unsaved-changes dialog).
  let quitsOnTerminate: Bool

  init(quitsOnTerminate: Bool) { self.quitsOnTerminate = quitsOnTerminate }

  func terminate() -> Bool {
    terminateCalls += 1
    if quitsOnTerminate { exit() }
    return true
  }

  func forceTerminate() -> Bool {
    forceCalls += 1
    exit()
    return true
  }

  func waitForTermination() async {
    while !isTerminated && !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(2))
    }
  }

  private func exit() { isTerminated = true }
}

@MainActor
final class FakeWorkspace: WorkspaceProviding {
  struct OpenFailure: Error, Equatable { let attempt: Int }

  var processes: [FakeProcess] = []
  var opened: [URL] = []
  var openCalls = 0
  /// The first this many calls to `open` throw.
  var failures = 0
  func runningProcesses(bundleIdentifier: BundleIdentifier) -> [any RunningProcess] { processes }
  func open(applicationAt url: URL) async throws {
    openCalls += 1
    if openCalls <= failures { throw OpenFailure(attempt: openCalls) }
    opened.append(url)
  }
}

@MainActor
final class FakeRelauncher: AppRelauncher {
  var quitResult = QuitResult.notRunning
  var reopenError: Error?
  var events: [String] = []
  var running = false
  func isRunning(_ app: AppInfo) -> Bool { running }
  func quit(_ app: AppInfo, timeout: Duration) async -> QuitResult { events.append("quit"); return quitResult }
  func reopen(_ app: AppInfo) async throws { events.append("reopen"); if let reopenError { throw reopenError } }
  func forceTerminate(_ app: AppInfo) -> Bool { events.append("force"); return quitResult != .notRunning }
}

final class RecordingStore: AppearanceStore, @unchecked Sendable {
  private let lock = NSLock()
  private var _writes: [(Appearance, BundleIdentifier)] = []
  private var _targets: [AppTarget] = []
  var failure: AppearanceError?
  var preflightFailure: AppearanceError?
  func preflight(for app: AppTarget) throws { if let preflightFailure { throw preflightFailure } }
  var writes: [(Appearance, BundleIdentifier)] { lock.withLock { _writes } }
  var targets: [AppTarget] { lock.withLock { _targets } }
  func read(for app: AppTarget) -> AppearanceReading { .init(appearance: .system, access: .available) }
  func write(_ appearance: Appearance, for app: AppTarget) throws {
    if let failure { throw failure }
    lock.withLock {
      _writes.append((appearance, app.bundleIdentifier))
      _targets.append(app)
    }
  }
}

func makeApp(_ id: String = "t.app", core: Bool = false, appearance: Appearance = .system) -> AppInfo {
  AppInfo(
    bundleIdentifier: BundleIdentifier(id)!, name: id, url: URL(fileURLWithPath: "/tmp/\(id).app"),
    isSandboxed: false, isCoreService: core, appearance: appearance, access: .available)
}

@MainActor @Suite struct WorkspaceRelauncherTests {
  @Test func isRunningReflectsLiveProcesses() {
    let workspace = FakeWorkspace()
    let relauncher = WorkspaceRelauncher(workspace: workspace)
    #expect(!relauncher.isRunning(makeApp()))
    let process = FakeProcess(quitsOnTerminate: true)
    workspace.processes = [process]
    #expect(relauncher.isRunning(makeApp()))
    _ = process.terminate()
    #expect(!relauncher.isRunning(makeApp()))
  }

  @Test func notRunning() async {
    let relauncher = WorkspaceRelauncher(workspace: FakeWorkspace())
    #expect(await relauncher.quit(makeApp(), timeout: .milliseconds(50)) == .notRunning)
  }

  @Test func quitsGracefullyWithoutForce() async {
    let workspace = FakeWorkspace()
    let process = FakeProcess(quitsOnTerminate: true)
    workspace.processes = [process]
    let result = await WorkspaceRelauncher(workspace: workspace).quit(makeApp(), timeout: .seconds(5))
    #expect(result == .quit)
    #expect(process.terminateCalls == 1 && process.forceCalls == 0)
  }

  @Test func refusingAppReportsStillRunningAndIsNeverForceKilled() async {
    let workspace = FakeWorkspace()
    let process = FakeProcess(quitsOnTerminate: false)
    workspace.processes = [process]
    let result = await WorkspaceRelauncher(workspace: workspace).quit(makeApp(), timeout: .milliseconds(50))
    #expect(result == .stillRunning)
    #expect(process.forceCalls == 0 && !process.isTerminated)
  }

  @Test func waitsForEveryInstance() async {
    let workspace = FakeWorkspace()
    let quits = FakeProcess(quitsOnTerminate: true)
    let refuses = FakeProcess(quitsOnTerminate: false)
    workspace.processes = [quits, refuses]
    let result = await WorkspaceRelauncher(workspace: workspace).quit(makeApp(), timeout: .milliseconds(50))
    #expect(result == .stillRunning)
  }

  @Test func reopenUsesAppURL() async throws {
    let workspace = FakeWorkspace()
    try await WorkspaceRelauncher(workspace: workspace).reopen(makeApp("t.x"))
    #expect(workspace.opened == [URL(fileURLWithPath: "/tmp/t.x.app")])
  }

  @Test func forceTerminateHitsAllInstances() {
    let workspace = FakeWorkspace()
    let a = FakeProcess(quitsOnTerminate: true), b = FakeProcess(quitsOnTerminate: true)
    workspace.processes = [a, b]
    #expect(WorkspaceRelauncher(workspace: workspace).forceTerminate(makeApp()))
    #expect(a.forceCalls == 1 && b.forceCalls == 1)
  }
}

@MainActor @Suite struct AppearanceServiceTests {
  private func service(_ store: RecordingStore, _ relauncher: FakeRelauncher) -> AppearanceService {
    AppearanceService(scanner: AppScanner(locations: []), store: store, relauncher: relauncher)
  }

  @Test func runningAppIsQuitThenWrittenThenReopened() async {
    let store = RecordingStore()
    let relauncher = FakeRelauncher()
    relauncher.quitResult = .quit
    let outcome = await service(store, relauncher).setAppearance(.light, for: makeApp())
    #expect(outcome == .applied(.relaunched))
    #expect(relauncher.events == ["quit", "reopen"])
    #expect(store.writes.map(\.0) == [.light])
  }

  @Test func notRunningAppIsWrittenAndNotOpened() async {
    let store = RecordingStore()
    let relauncher = FakeRelauncher()
    let outcome = await service(store, relauncher).setAppearance(.dark, for: makeApp())
    #expect(outcome == .applied(.notRunning))
    #expect(!relauncher.events.contains("reopen"))
  }

  @Test func stillRunningStillSavesButDoesNotReopen() async {
    let store = RecordingStore()
    let relauncher = FakeRelauncher()
    relauncher.quitResult = .stillRunning
    let outcome = await service(store, relauncher).setAppearance(.dark, for: makeApp())
    #expect(outcome == .applied(.stillRunning))
    #expect(!relauncher.events.contains("reopen") && !relauncher.events.contains("force"))
    #expect(store.writes.count == 1)
  }

  @Test func failedWriteStillReopensTheQuitApp() async {
    let store = RecordingStore()
    let id = BundleIdentifier("t.app")!
    store.failure = .needsPermission(id)
    let relauncher = FakeRelauncher()
    relauncher.quitResult = .quit
    let outcome = await service(store, relauncher).setAppearance(.light, for: makeApp())
    #expect(outcome == .failed(.needsPermission(id)))
    #expect(relauncher.events == ["quit", "reopen"])
  }

  @Test func failedPreflightNeverQuitsOrWrites() async {
    let store = RecordingStore()
    let id = BundleIdentifier("t.app")!
    store.preflightFailure = .containerMissing(id)
    let relauncher = FakeRelauncher()
    relauncher.quitResult = .quit
    let outcome = await service(store, relauncher).setAppearance(.light, for: makeApp())
    #expect(outcome == .failed(.containerMissing(id)))
    #expect(relauncher.events.isEmpty)
    #expect(store.writes.isEmpty)
  }

  @Test func withoutRestartOnlyWrites() async {
    let store = RecordingStore()
    let relauncher = FakeRelauncher()
    relauncher.quitResult = .quit
    let outcome = await service(store, relauncher).setAppearance(.dark, for: makeApp(), restart: false)
    #expect(outcome == .applied(.appliesOnNextLaunch))
    #expect(relauncher.events.isEmpty)
    #expect(store.writes.map(\.0) == [.dark])
  }

  @Test func coreServiceWithoutRestartIsNotTerminated() async {
    let store = RecordingStore()
    let relauncher = FakeRelauncher()
    let outcome = await service(store, relauncher).setAppearance(.dark, for: makeApp(core: true), restart: false)
    #expect(outcome == .applied(.appliesOnNextLaunch))
    #expect(relauncher.events.isEmpty)
  }

  @Test func coreServiceIsWrittenThenForceTerminatedNeverQuit() async {
    let store = RecordingStore()
    let relauncher = FakeRelauncher()
    relauncher.quitResult = .quit
    let outcome = await service(store, relauncher).setAppearance(.light, for: makeApp("com.apple.finder", core: true))
    #expect(outcome == .applied(.restartedBySystem))
    #expect(relauncher.events == ["force"])
    #expect(store.writes.count == 1)
  }

  @Test func coreServiceWriteFailureDoesNotKill() async {
    let store = RecordingStore()
    store.failure = .writeFailed(BundleIdentifier("t.app")!, reason: "x")
    let relauncher = FakeRelauncher()
    relauncher.quitResult = .quit
    let outcome = await service(store, relauncher).setAppearance(.light, for: makeApp(core: true))
    guard case .failed = outcome else { Issue.record("expected failure"); return }
    #expect(relauncher.events.isEmpty)
  }

  @Test func reopenFailureIsReported() async {
    struct Boom: Error {}
    let store = RecordingStore()
    let relauncher = FakeRelauncher()
    relauncher.quitResult = .quit
    relauncher.reopenError = Boom()
    let outcome = await service(store, relauncher).setAppearance(.light, for: makeApp())
    guard case .applied(.reopenFailed) = outcome else { Issue.record("got \(outcome)"); return }
  }

  @Test func applySettingsWritesOnlyInstalledChangedApps() async throws {
    let temp = try TempDirectory()
    try temp.makeApp("A/One.app", id: "t.one")
    try temp.makeApp("A/Two.app", id: "t.two")
    let scanner = AppScanner(
      locations: [.init(url: temp.url.appendingPathComponent("A"))], excludedBundleIdentifiers: [],
      sandboxDetector: FakeSandbox(),
      store: FakeStore(readings: [BundleIdentifier("t.two")!: .init(appearance: .dark, access: .available)]))
    let store = RecordingStore()
    let relauncher = FakeRelauncher()
    let service = AppearanceService(scanner: scanner, store: store, relauncher: relauncher)
    let file = SettingsFile(parsing: """
    defaults write t.one NSRequiresAquaSystemAppearance -bool true
    defaults write t.two NSRequiresAquaSystemAppearance -bool false
    defaults write t.gone NSRequiresAquaSystemAppearance -bool true
    defaults write ;curl${IFS}x|sh;y NSRequiresAquaSystemAppearance -bool true
    """)
    let report = await service.apply(settings: file)
    #expect(report.applied.map(\.rawValue) == ["t.one"])
    #expect(report.unchanged.map(\.rawValue) == ["t.two"])
    #expect(report.missing.map(\.rawValue) == ["t.gone"])
    #expect(report.rejectedLineCount == 1)
    #expect(relauncher.events.isEmpty)
  }
}

final class SleepLog: @unchecked Sendable {
  private let lock = NSLock()
  private var _delays: [Duration] = []
  var delays: [Duration] { lock.withLock { _delays } }
  var sleeper: WorkspaceRelauncher.Sleeper {
    { [self] duration in lock.withLock { _delays.append(duration) } }
  }
}

@MainActor @Suite struct ReopenRetryTests {
  @Test func firstAttemptSucceedingNeverSleeps() async throws {
    let workspace = FakeWorkspace()
    let log = SleepLog()
    try await WorkspaceRelauncher(workspace: workspace, sleep: log.sleeper).reopen(makeApp())
    #expect(workspace.openCalls == 1)
    #expect(log.delays.isEmpty)
  }

  @Test func failingTwiceThenSucceedingRelaunches() async throws {
    let workspace = FakeWorkspace()
    workspace.failures = 2
    let log = SleepLog()
    try await WorkspaceRelauncher(workspace: workspace, sleep: log.sleeper).reopen(makeApp())
    #expect(workspace.openCalls == 3)
    #expect(log.delays == [.milliseconds(100), .milliseconds(250)])
  }

  @Test func throughTheServiceItIsRelaunched() async {
    let workspace = FakeWorkspace()
    workspace.failures = 2
    let relauncher = WorkspaceRelauncher(workspace: workspace, sleep: SleepLog().sleeper)
    let service = AppearanceService(store: RecordingStore(), relauncher: relauncher)
    let process = FakeProcess(quitsOnTerminate: true)
    workspace.processes = [process]
    let outcome = await service.setAppearance(.dark, for: makeApp())
    #expect(outcome == .applied(.relaunched))
    #expect(workspace.openCalls == 3)
  }

  @Test func alwaysFailingThrowsTheLastErrorAfterBoundedAttempts() async {
    let workspace = FakeWorkspace()
    workspace.failures = .max
    let relauncher = WorkspaceRelauncher(workspace: workspace, sleep: SleepLog().sleeper)
    do {
      try await relauncher.reopen(makeApp())
      Issue.record("expected a failure")
    } catch let error as FakeWorkspace.OpenFailure {
      #expect(error.attempt == 5, "the last error is the one thrown")
    } catch {
      Issue.record("unexpected \(error)")
    }
    #expect(workspace.openCalls == WorkspaceRelauncher.retryDelays.count)
  }

  @Test func throughTheServiceAFinalFailureStillSurfaces() async {
    let workspace = FakeWorkspace()
    workspace.failures = .max
    let service = AppearanceService(
      store: RecordingStore(), relauncher: WorkspaceRelauncher(workspace: workspace, sleep: SleepLog().sleeper))
    workspace.processes = [FakeProcess(quitsOnTerminate: true)]
    let outcome = await service.setAppearance(.dark, for: makeApp())
    guard case .applied(.reopenFailed) = outcome else { Issue.record("got \(outcome)"); return }
  }

  @Test func theOldInstanceStillListedIsWaitedForWithinTheBudget() async throws {
    let workspace = FakeWorkspace()
    workspace.failures = 1
    let lingering = FakeProcess(quitsOnTerminate: true)
    workspace.processes = [lingering]  // never reports terminated
    let log = SleepLog()
    try await WorkspaceRelauncher(workspace: workspace, sleep: log.sleeper).reopen(makeApp())
    let waited = log.delays.reduce(Duration.zero, +)
    #expect(waited <= .seconds(2) + .milliseconds(100))
    #expect(workspace.openCalls == 2)
  }

  @Test func cancellationStopsTheRetries() async {
    let workspace = FakeWorkspace()
    workspace.failures = .max
    let relauncher = WorkspaceRelauncher(workspace: workspace, sleep: { _ in throw CancellationError() })
    do {
      try await relauncher.reopen(makeApp())
      Issue.record("expected cancellation")
    } catch is CancellationError {
      #expect(workspace.openCalls == 1, "no attempt after the first sleep was cancelled")
    } catch {
      Issue.record("unexpected \(error)")
    }

    let task = Task { @MainActor in
      let again = FakeWorkspace()
      again.failures = .max
      withUnsafeCurrentTask { $0?.cancel() }
      try await WorkspaceRelauncher(workspace: again, sleep: SleepLog().sleeper).reopen(makeApp())
      return again.openCalls
    }
    let result = await task.result
    if case .success = result { Issue.record("a cancelled task must not keep opening") }
  }
}
