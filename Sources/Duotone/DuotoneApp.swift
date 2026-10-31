import AppKit
import DuotoneCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  /// `.task` starting is not first paint; the occlusion state turning visible is when the window
  /// is actually on screen, and it also fires when the app was launched without activating.
  func applicationDidFinishLaunching(_ notification: Notification) {
    Launch.mark("did finish launching")
    _ = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        if NSApp.windows.contains(where: { $0.canBecomeMain && $0.occlusionState.contains(.visible) }) {
          Launch.markOnce("window visible")
        }
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DuotoneApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  @State private var library: AppLibrary
  @State private var system = SystemAppearanceController()
  @State private var windowState = WindowState()
  @AppStorage("viewMode") private var viewMode = ViewMode.list
  @AppStorage("compactBars") private var compactBars = false

  init() {
    Launch.mark("app init")
    let relauncher = WorkspaceRelauncher()
    _library = State(initialValue: AppLibrary(service: AppearanceService(scanner: AppScanner(cache: AppMetadataCache()), relauncher: relauncher), relauncher: relauncher))
  }

  var body: some Scene {
    Window("Duotone", id: "main") {
      ContentView(library: library, system: system, windowState: windowState)
    }
    .defaultSize(width: 760, height: 560)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("Import…") { windowState.isImporting = true }
          .keyboardShortcut("o")
      }
      CommandGroup(replacing: .saveItem) {
        Button("Export…") { windowState.isExporting = true }
          .keyboardShortcut("s")
          .disabled(library.isResolvingSandboxed)
      }
      CommandGroup(after: .toolbar) {
        Button("as Grid") { viewMode = .grid }
          .keyboardShortcut("1")
        Button("as List") { viewMode = .list }
          .keyboardShortcut("2")
        Toggle("Compact", isOn: $compactBars)
          .keyboardShortcut("3")
        Divider()
        Button("Refresh") { Task { await library.refresh() } }
          .keyboardShortcut("r")
      }
    }
  }
}
