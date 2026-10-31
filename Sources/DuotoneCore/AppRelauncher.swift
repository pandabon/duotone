import AppKit

public enum QuitResult: Sendable, Equatable {
  case notRunning
  case quit
  /// The app is still running after the timeout, typically an unsaved-changes dialog.
  case stillRunning
}

@MainActor
public protocol AppRelauncher: Sendable {
  /// Asks every instance to quit and waits until they have. Never force-kills.
  func quit(_ app: AppInfo, timeout: Duration) async -> QuitResult
  func reopen(_ app: AppInfo) async throws
  func isRunning(_ app: AppInfo) -> Bool
  /// For CoreServices that launchd restarts on its own.
  func forceTerminate(_ app: AppInfo) -> Bool
}

/// A running process, abstracted so quit/timeout logic can be tested without real apps.
@MainActor
public protocol RunningProcess: Sendable {
  var isTerminated: Bool { get }
  func terminate() -> Bool
  func forceTerminate() -> Bool
  /// Returns once the process has exited; must honour task cancellation.
  func waitForTermination() async
}

@MainActor
public protocol WorkspaceProviding: Sendable {
  func runningProcesses(bundleIdentifier: BundleIdentifier) -> [any RunningProcess]
  func open(applicationAt url: URL) async throws
}

@MainActor
public struct WorkspaceRelauncher: AppRelauncher {
  public typealias Sleeper = @Sendable (Duration) async throws -> Void

  /// Pauses before each attempt, about 1.85 s in all. LaunchServices is still tearing the old
  /// instance down for a moment after it exits, and opening then fails with a "miscellaneous error".
  static let retryDelays: [Duration] = [.zero, .milliseconds(100), .milliseconds(250), .milliseconds(500), .milliseconds(1000)]
  private static let overallBudget = Duration.seconds(2)
  private static let pollInterval = Duration.milliseconds(50)

  private let workspace: any WorkspaceProviding
  private let sleep: Sleeper

  public init(
    workspace: any WorkspaceProviding = SystemWorkspace(),
    sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
  ) {
    self.workspace = workspace
    self.sleep = sleep
  }

  public func quit(_ app: AppInfo, timeout: Duration) async -> QuitResult {
    let processes = workspace.runningProcesses(bundleIdentifier: app.bundleIdentifier).filter { !$0.isTerminated }
    guard !processes.isEmpty else { return .notRunning }

    for process in processes { _ = process.terminate() }

    let allQuit = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await waitForAll(processes)
        return true
      }
      group.addTask {
        do {
          try await Task.sleep(for: timeout)
          return false
        } catch {
          return true  // cancelled because the wait finished first
        }
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
    return allQuit ? .quit : .stillRunning
  }

  /// Retries with backoff, and before each retry waits while the old instance is still listed,
  /// all within one budget. The last error is thrown, never swallowed.
  public func reopen(_ app: AppInfo) async throws {
    var lastError: Error?
    var elapsed = Duration.zero
    for (attempt, delay) in Self.retryDelays.enumerated() {
      try Task.checkCancellation()
      if attempt > 0 {
        try await sleep(delay)
        elapsed += delay
        while elapsed < Self.overallBudget,
              workspace.runningProcesses(bundleIdentifier: app.bundleIdentifier).contains(where: { !$0.isTerminated }) {
          try await sleep(Self.pollInterval)
          elapsed += Self.pollInterval
        }
        try Task.checkCancellation()
      }
      do {
        try await workspace.open(applicationAt: app.url)
        return
      } catch {
        lastError = error
      }
    }
    throw lastError ?? CancellationError()
  }

  public func isRunning(_ app: AppInfo) -> Bool {
    workspace.runningProcesses(bundleIdentifier: app.bundleIdentifier).contains { !$0.isTerminated }
  }

  public func forceTerminate(_ app: AppInfo) -> Bool {
    var sent = false
    for process in workspace.runningProcesses(bundleIdentifier: app.bundleIdentifier) {
      sent = process.forceTerminate() || sent
    }
    return sent
  }
}

@MainActor
public struct SystemWorkspace: WorkspaceProviding {
  public init() {}

  public func runningProcesses(bundleIdentifier: BundleIdentifier) -> [any RunningProcess] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier.rawValue)
      .map(SystemProcess.init)
  }

  public func open(applicationAt url: URL) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
  }
}

@MainActor
struct SystemProcess: RunningProcess {
  let application: NSRunningApplication

  var isTerminated: Bool { application.isTerminated }
  func terminate() -> Bool { application.terminate() }
  func forceTerminate() -> Bool { application.forceTerminate() }

  func waitForTermination() async {
    await waitForExit(of: application.processIdentifier)
  }
}

/// Resumes exactly once, from whichever of exit, cancellation or an already-gone pid comes first.
private final class OneShot: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var finished = false
  private var source: (any DispatchSourceProcess)?

  func install(_ continuation: CheckedContinuation<Void, Never>, source: any DispatchSourceProcess) {
    lock.lock()
    if finished {
      lock.unlock()
      source.cancel()
      continuation.resume()
      return
    }
    self.continuation = continuation
    self.source = source
    lock.unlock()
  }

  func finish() {
    lock.lock()
    finished = true
    let continuation = continuation
    let source = source
    self.continuation = nil
    self.source = nil
    lock.unlock()
    source?.cancel()
    continuation?.resume()
  }
}

/// A process source reports the exit without needing a run loop, and unlike an
/// NSWorkspace notification subscription it cannot miss an exit that happens while subscribing.
private func waitForExit(of pid: pid_t) async {
  let shot = OneShot()
  await withTaskCancellationHandler {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
      source.setEventHandler { shot.finish() }
      shot.install(continuation, source: source)
      source.activate()
      // The exit may have happened before the source existed, which would never fire.
      if kill(pid, 0) != 0 && errno == ESRCH { shot.finish() }
    }
  } onCancel: {
    shot.finish()
  }
}

private func waitForAll(_ processes: [any RunningProcess]) async {
  for process in processes { await process.waitForTermination() }
}
