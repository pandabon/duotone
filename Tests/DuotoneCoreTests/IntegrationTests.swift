import Foundation
import AppKit
import Testing
@testable import DuotoneCore

/// End to end against real throwaway apps. Run with `DUOTONE_INTEGRATION=1 swift test`.
/// Touches only the `local.scratch.*` preference domains and the existing
/// ~/Library/Containers/local.scratch.aquasandbox container.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DUOTONE_INTEGRATION"] == "1"))
struct IntegrationTests {
  /// Removes the value and the file. cfprefsd can still write an empty plist for the domain when
  /// this process exits, which no in-process step prevents; `removeStaleScratchPlists` sweeps those
  /// up at the start of the next run, and only ever touches `local.scratch.*`.
  static func scrubPreferences(of id: String) {
    precondition(id.hasPrefix("local.scratch."))
    CFPreferencesSetAppValue("NSRequiresAquaSystemAppearance" as CFString, nil, id as CFString)
    CFPreferencesAppSynchronize(id as CFString)
    try? FileManager.default.removeItem(
      at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(id).plist"))
    CFPreferencesAppSynchronize(id as CFString)
  }

  static func removeStaleScratchPlists() {
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasPrefix("local.scratch.") && name.hasSuffix(".plist") {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  static let source = """
  import Cocoa
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  class D: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        let m = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "nil"
        print("RESULT \\(m)")
        fflush(stdout)
        NSApp.terminate(nil)
      }
    }
  }
  let d = D(); app.delegate = d; app.run()
  """

  static let entitlements = """
  <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
  """

  struct Built {
    let app: URL
    let id: BundleIdentifier
    var executable: URL { app.appendingPathComponent("Contents/MacOS/Scratch") }
  }

  static func run(_ path: String, _ args: [String]) throws -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  /// Stays alive until terminated and appends "<pid> <effective appearance>" to the file named by
  /// `ScratchOut` on every launch. With `ScratchStubborn` it cancels every quit request.
  static let keepAliveSource = """
  import Cocoa
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  class D: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        let m = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "nil"
        let data = "\\(getpid()) \\(m)\\n".data(using: .utf8)!
        let path = Bundle.main.object(forInfoDictionaryKey: "ScratchOut") as! String
        if let h = FileHandle(forWritingAtPath: path) {
          h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
          FileManager.default.createFile(atPath: path, contents: data)
        }
      }
    }
    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
      Bundle.main.object(forInfoDictionaryKey: "ScratchStubborn") as? Bool == true ? .terminateCancel : .terminateNow
    }
  }
  let d = D(); app.delegate = d; app.run()
  """

  static func build(
    in dir: URL, id: String, sandboxed: Bool, source: String = source, extraInfo: [String: Any] = [:]
  ) throws -> Built {
    let src = dir.appendingPathComponent("\(id).swift")
    try source.write(to: src, atomically: true, encoding: .utf8)
    let app = dir.appendingPathComponent("\(id).app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let info: [String: Any] = [
      "CFBundleIdentifier": id, "CFBundleExecutable": "Scratch", "CFBundleName": "Scratch",
      "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
    ].merging(extraInfo) { $1 }
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let compile = try run("/usr/bin/swiftc", [src.path, "-o", macOS.appendingPathComponent("Scratch").path])
    try #require(compile.status == 0, "swiftc failed: \(compile.out)")
    var sign = ["--force", "--sign", "-"]
    if sandboxed {
      let ent = dir.appendingPathComponent("\(id).entitlements")
      try entitlements.write(to: ent, atomically: true, encoding: .utf8)
      sign += ["--entitlements", ent.path]
    }
    let signed = try run("/usr/bin/codesign", sign + [app.path])
    try #require(signed.status == 0, "codesign failed: \(signed.out)")
    return Built(app: app, id: BundleIdentifier(id)!)
  }

  static func effectiveAppearance(of built: Built) throws -> String {
    let result = try run(built.executable.path, [])
    return result.out.split(separator: "\n").first { $0.hasPrefix("RESULT ") }.map { String($0.dropFirst(7)) } ?? "no result: \(result.out)"
  }

  static var systemIsDark: Bool {
    UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
  }

  @Test func storeWriteChangesEffectiveAppearance() throws {
    IntegrationTests.removeStaleScratchPlists()
    let temp = try TempDirectory()
    let store = PreferencesAppearanceStore()
    let detector = CodeSignatureSandboxDetector()

    let boxed = try Self.build(in: temp.url, id: "local.scratch.aquasandbox", sandboxed: true)
    let plain = try Self.build(in: temp.url, id: "local.scratch.aquaplain", sandboxed: false)
    defer {
      for built in [boxed, plain] {
        let sandboxed = detector.isSandboxed(appAt: built.app)
        try? store.write(.system, for: AppTarget(bundleIdentifier: built.id, isSandboxed: sandboxed))
      }
      for id in ["local.scratch.aquaplain", "local.scratch.aquasandbox"] { Self.scrubPreferences(of: id) }
    }

    #expect(detector.isSandboxed(appAt: boxed.app))
    #expect(!detector.isSandboxed(appAt: plain.app))

    for built in [boxed, plain] {
      let target = AppTarget(bundleIdentifier: built.id, isSandboxed: detector.isSandboxed(appAt: built.app))
      do {
        try store.write(.light, for: target)
      } catch AppearanceError.containerMissing {
        _ = try Self.effectiveAppearance(of: built)  // first launch creates the container
        try store.write(.light, for: target)
      }
      #expect(store.read(for: target) == AppearanceReading(appearance: .light, access: .available))
      #expect(try Self.effectiveAppearance(of: built) == "NSAppearanceNameAqua", "\(built.id): light")

      if Self.systemIsDark {
        try store.write(.dark, for: target)
        #expect(try Self.effectiveAppearance(of: built) == "NSAppearanceNameDarkAqua", "\(built.id): dark")
        try store.write(.system, for: target)
        #expect(try Self.effectiveAppearance(of: built) == "NSAppearanceNameDarkAqua", "\(built.id): system")
      }
    }

    // The failure the old app had: writing the plain domain for a sandboxed app does nothing.
    if Self.systemIsDark {
      let wrong = PreferencesAppearanceStore()
      try wrong.write(.light, for: AppTarget(bundleIdentifier: boxed.id, isSandboxed: false))
      defer { try? wrong.write(.system, for: AppTarget(bundleIdentifier: boxed.id, isSandboxed: false)) }
      #expect(try Self.effectiveAppearance(of: boxed) == "NSAppearanceNameDarkAqua", "plain-domain write must not affect a sandboxed app")
    }
  }
}

/// The real relauncher and service against real running scratch apps.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DUOTONE_INTEGRATION"] == "1"))
struct RelaunchIntegrationTests {
  private let store = PreferencesAppearanceStore()

  private struct Scratch {
    let built: IntegrationTests.Built
    let out: URL
    var info: AppInfo {
      AppInfo(
        bundleIdentifier: built.id, name: "Scratch", url: built.app, isSandboxed: false,
        isCoreService: false, appearance: .system, access: .available)
    }
    var running: [NSRunningApplication] { NSRunningApplication.runningApplications(withBundleIdentifier: built.id.rawValue) }
    var lines: [(pid: Int32, appearance: String)] {
      ((try? String(contentsOf: out, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
        let parts = $0.split(separator: " ")
        guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
        return (pid, String(parts[1]))
      }
    }
  }

  private func scratch(_ temp: TempDirectory, _ id: String, stubborn: Bool = false) throws -> Scratch {
    IntegrationTests.removeStaleScratchPlists()
    let out = temp.url.appendingPathComponent("\(id).out")
    let built = try IntegrationTests.build(
      in: temp.url, id: id, sandboxed: false, source: IntegrationTests.keepAliveSource,
      extraInfo: ["ScratchOut": out.path, "ScratchStubborn": stubborn])
    return Scratch(built: built, out: out)
  }

  private func service(timeout: Duration = .seconds(5)) -> AppearanceService {
    AppearanceService(relauncher: WorkspaceRelauncher(), quitTimeout: timeout)
  }

  private func launch(_ app: Scratch) async throws {
    try await SystemWorkspace().open(applicationAt: app.built.app)
    try await wait("\(app.built.id) first report") { !app.lines.isEmpty }
  }

  private func wait(_ what: String, seconds: Double = 15, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition() {
      try #require(ContinuousClock.now < deadline, "timed out waiting for \(what)")
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  /// Runs even when an expectation fails, so nothing keeps running and no preference survives.
  private func cleanUp(_ apps: [Scratch]) {
    for app in apps {
      for process in app.running { process.forceTerminate() }
      IntegrationTests.scrubPreferences(of: app.built.id.rawValue)
    }
  }

  private func read(_ app: Scratch) -> Appearance {
    store.read(for: AppTarget(bundleIdentifier: app.built.id, isSandboxed: false)).appearance
  }

  private func seed(_ app: Scratch, _ appearance: Appearance) throws {
    try store.write(appearance, for: AppTarget(bundleIdentifier: app.built.id, isSandboxed: false))
  }

  @Test func runningAppIsQuitWrittenAndReopened() async throws {
    let temp = try TempDirectory()
    let app = try scratch(temp, "local.scratch.aquarelaunch")
    defer { cleanUp([app]) }
    try seed(app, .light)
    try await launch(app)
    #expect(app.lines[0].appearance == "NSAppearanceNameAqua")
    let oldPID = try #require(app.running.first?.processIdentifier)

    let outcome = await service().setAppearance(.dark, for: app.info)
    #expect(outcome == .applied(.relaunched), "\(outcome)")
    try await wait("new instance report") { app.lines.count >= 2 && !app.running.isEmpty }
    let newPID = try #require(app.running.first?.processIdentifier)
    #expect(newPID != oldPID)
    #expect(app.lines[1].pid == newPID)
    #expect(app.lines[1].appearance == "NSAppearanceNameDarkAqua")
    #expect(read(app) == .dark)
  }

  @Test func appThatRefusesToQuitIsKeptAndValueSaved() async throws {
    let temp = try TempDirectory()
    let app = try scratch(temp, "local.scratch.aquastubborn", stubborn: true)
    defer { cleanUp([app]) }
    try seed(app, .light)
    try await launch(app)
    let pid = try #require(app.running.first?.processIdentifier)

    let outcome = await service(timeout: .seconds(1)).setAppearance(.dark, for: app.info)
    #expect(outcome == .applied(.stillRunning))
    #expect(app.running.map(\.processIdentifier) == [pid])
    #expect(app.running.first?.isTerminated == false)
    #expect(read(app) == .dark)
  }

  @Test func appThatIsNotRunningIsWrittenButNotLaunched() async throws {
    let temp = try TempDirectory()
    let app = try scratch(temp, "local.scratch.aquaidle")
    defer { cleanUp([app]) }

    let outcome = await service().setAppearance(.dark, for: app.info)
    #expect(outcome == .applied(.notRunning))
    try await Task.sleep(for: .seconds(1))
    #expect(app.running.isEmpty)
    #expect(app.lines.isEmpty)
    #expect(read(app) == .dark)
  }

  @Test func withoutRestartARunningAppKeepsItsProcess() async throws {
    let temp = try TempDirectory()
    let app = try scratch(temp, "local.scratch.aquanorestart")
    defer { cleanUp([app]) }
    try seed(app, .light)
    try await launch(app)
    let pid = try #require(app.running.first?.processIdentifier)

    let outcome = await service().setAppearance(.dark, for: app.info, restart: false)
    #expect(outcome == .applied(.appliesOnNextLaunch))
    try await Task.sleep(for: .seconds(1))
    #expect(app.running.map(\.processIdentifier) == [pid])
    #expect(app.lines.count == 1)
    #expect(read(app) == .dark)
  }
}
