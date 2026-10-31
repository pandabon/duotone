import AppKit
import DuotoneCore
import SwiftUI
import UniformTypeIdentifiers

enum ViewMode: String {
  case grid
  case list
}

@MainActor @Observable
final class WindowState {
  var isImporting = false
  var isExporting = false
}

extension AppLibrary.Filter: Identifiable {
  public var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .all: "All Apps"
    case .customized: "Customized"
    case .light: "Light"
    case .dark: "Dark"
    case .needsAttention: "Needs Attention"
    }
  }

  var symbol: String {
    switch self {
    case .all: "square.grid.2x2"
    case .customized: "slider.horizontal.3"
    case .light: "sun.max"
    case .dark: "moon"
    case .needsAttention: "exclamationmark.triangle"
    }
  }
}

private struct Notice: Equatable {
  let id = UUID()
  var message: String
  var link: (title: LocalizedStringKey, url: URL)?

  static func == (lhs: Notice, rhs: Notice) -> Bool { lhs.id == rhs.id }
}

struct ContentView: View {
  @Bindable var library: AppLibrary
  let system: SystemAppearanceController
  @Bindable var windowState: WindowState
  @State private var coordinator: ChangeCoordinator
  @State private var notice: Notice?
  @AppStorage("viewMode") private var viewMode = ViewMode.list
  @AppStorage("compactBars") private var compactBars = false
  @AppStorage("didChooseLayout") private var didChooseLayout = false
  @State private var showLayoutChoice = false
  @State private var typeSelect = TypeSelect()
  @State private var typeTarget: BundleIdentifier?
  @State private var typeReset: Task<Void, Never>?
  @FocusState private var contentFocused: Bool
  @AppStorage(ChangeCoordinator.suppressKey) private var suppressDialog = false

  init(library: AppLibrary, system: SystemAppearanceController, windowState: WindowState) {
    self.library = library
    self.system = system
    self.windowState = windowState
    _coordinator = State(initialValue: ChangeCoordinator(library: library))
  }

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      detail
    }
    .frame(minWidth: 560, minHeight: 520)
    .searchable(text: $library.searchText, prompt: "Search")
    .environment(coordinator)
    .confirmationDialog(
      LocalizedStringKey("Restart \(coordinator.pending?.app.name ?? "") to apply?"),
      isPresented: Binding(
        get: { coordinator.pending != nil },
        set: { if !$0 { coordinator.cancel() } }
      ),
      titleVisibility: .visible,
      presenting: coordinator.pending
    ) { pending in
      Button("Restart Now") { coordinator.confirm(restart: true) }
      Button("Apply on Next Launch") { coordinator.confirm(restart: false) }
      Button("Cancel", role: .cancel) { coordinator.cancel() }
    } message: { pending in
      if pending.app.isCoreService {
        Text("\(pending.app.name) is part of macOS. Applying this restarts it, so Finder or the Dock may briefly disappear.")
      } else {
        Text("\(pending.app.name) quits and reopens to apply the new appearance. It may ask to save changes first.")
      }
    }
    .dialogSuppressionToggle(isSuppressed: $suppressDialog)
    // In the window, not a sheet, so ⌘Q and window close are never blocked. Only built while shown.
    .overlay {
      if showLayoutChoice {
        LayoutChoiceOverlay {
          didChooseLayout = true  // the only place this is written
          showLayoutChoice = false
        }
      }
    }
    .fileExporter(
      isPresented: $windowState.isExporting,
      document: PlainTextDocument(text: windowState.isExporting ? library.exportText() : ""),
      contentType: .plainText,
      defaultFilename: String(localized: "Duotone Settings")
    ) { result in
      if case .failure(let error) = result { notice = Notice(message: error.localizedDescription) }
    }
    .fileImporter(isPresented: $windowState.isImporting, allowedContentTypes: [.plainText]) { result in
      Task { await importSettings(result) }
    }
    .onChange(of: system.failure) { _, failure in showSystemFailure(failure) }
    .onChange(of: library.searchText) { clearTypeSelect() }
    .onChange(of: library.filter) { clearTypeSelect() }
    .onChange(of: library.isLoaded) { _, loaded in if loaded { Launch.mark("list on screen") } }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await library.refreshOnActivation(minimumInterval: .seconds(15)) }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
      library.stopWatching()
    }
    .task { await load() }
  }

  private var sidebar: some View { SidebarView(library: library, system: system) }

  // MARK: - Detail

  private var detail: some View {
    content
      .navigationTitle(library.filter.title)
      .navigationSubtitle(library.visibleItems.count == 1 ? "1 app" : "\(library.visibleItems.count) apps")
      .toolbar {
        ToolbarItem {
          Picker("View", selection: $viewMode) {
            Label("Grid", systemImage: "square.grid.2x2").tag(ViewMode.grid)
            Label("List", systemImage: "list.bullet").tag(ViewMode.list)
          }
          .pickerStyle(.segmented)
          .help("Switch between grid and list")
        }
      }
      .overlay(alignment: .bottom) { noticeBar }
      .animation(.smooth, value: notice)
  }

  @ViewBuilder
  private var content: some View {
    let items = library.visibleItems
    let tokens = coordinator.resetTokens
    Group {
      if !library.isLoaded {
        DelayedProgress()
      } else if items.isEmpty {
        if library.isResolvingSandboxed {
          Color.clear  // Filters are unknown until preferences are read; avoid flashing "nothing".
        } else if library.searchText.isEmpty {
          ContentUnavailableView(
            "Nothing Here", systemImage: "circle.lefthalf.filled",
            description: Text("Apps that match this filter appear here."))
        } else {
          ContentUnavailableView.search(text: library.searchText)
        }
      } else if viewMode == .list {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(items) { item in
                AppRow(item: item, compact: compactBars, isTarget: typeTarget == item.id)
                  .equatable()
              }
            }
          }
          .typeSelectable(focus: $contentFocused) { handleKey($0, proxy: proxy) }
        }
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 170), spacing: 12, alignment: .top)], alignment: .center, spacing: 8) {
              ForEach(items) { item in
                AppTile(item: item, resetToken: tokens[item.id, default: 0], isTarget: typeTarget == item.id)
                  .equatable()
              }
            }
            .padding(16)
          }
          .typeSelectable(focus: $contentFocused) { handleKey($0, proxy: proxy) }
        }
      }
    }
    // Loading and resolving replace many rows at once; animating that would cost frames for nothing.
    .transaction(value: items) { $0.animation = nil }
  }

  // MARK: - Type to select

  private func handleKey(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
    if press.key == .escape {
      guard !typeSelect.buffer.isEmpty else { return .ignored }
      clearTypeSelect()
      return .handled
    }
    guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
          press.characters.count == 1, let scalar = press.characters.unicodeScalars.first,
          ![.control, .privateUse, .format, .unassigned].contains(scalar.properties.generalCategory)
    else { return .ignored }

    let apps = library.visibleItems.map(\.app)
    guard let id = typeSelect.type(press.characters, in: apps, now: .now) else { return .handled }
    typeTarget = id
    // Instant: no animation, whatever transaction this runs in.
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { proxy.scrollTo(id, anchor: .top) }
    if let name = apps.first(where: { $0.id == id })?.name { AccessibilityNotification.Announcement(name).post() }
    typeReset?.cancel()
    typeReset = Task {
      try? await Task.sleep(for: .seconds(1))
      if !Task.isCancelled { clearTypeSelect() }
    }
    return .handled
  }

  private func clearTypeSelect() {
    typeReset?.cancel()
    typeSelect.reset()
    typeTarget = nil
  }

  @ViewBuilder
  private var noticeBar: some View {
    if let notice {
      NoticeCapsule(message: notice.message, link: notice.link) { self.notice = nil }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  // MARK: - Actions

  private func load() async {
    Launch.mark("window task started")
    let list = await library.loadList()
    Launch.logger.info(
      "scan without sandboxed preferences: \(list.count, privacy: .public) apps in \(Launch.milliseconds(list.duration), format: .fixed(precision: 1), privacy: .public) ms")
    Launch.mark("first list ready")
    // After the list exists, so the choice never delays loading.
    if !didChooseLayout { showLayoutChoice = true }
    let resolved = await library.resolveSandboxed()
    Launch.logger.info(
      "resolved \(resolved.count, privacy: .public) sandboxed apps in \(Launch.milliseconds(resolved.duration), format: .fixed(precision: 1), privacy: .public) ms")
    Launch.mark("sandboxed apps resolved")
    // After first paint and after resolve, so neither competes with showing the list.
    await library.checkFullDiskAccess()
    await library.startWatching()
  }

  private func importSettings(_ result: Result<URL, Error>) async {
    do {
      let url = try result.get()
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= 1_000_000 else {
        notice = Notice(message: String(localized: "That file is too large to be a Duotone settings file."))
        return
      }
      let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
      let report = await library.importSettings(from: text)
      notice = Notice(message: Self.summary(of: report))
    } catch {
      notice = Notice(message: error.localizedDescription)
    }
  }

  private func showSystemFailure(_ failure: SystemAppearanceController.Failure?) {
    switch failure {
    case .automationDenied:
      notice = Notice(
        message: String(localized: "Duotone needs permission to control System Events to change the system appearance."),
        link: (
          "Open Privacy & Security",
          URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation")!
        ))
    case .other(let message):
      notice = Notice(message: message.isEmpty ? String(localized: "The system appearance could not be changed.") : message)
    case nil:
      break
    }
  }

  static func summary(of report: ApplyReport) -> String {
    var parts: [String] = []
    if !report.applied.isEmpty { parts.append(String(localized: "\(report.applied.count) applied")) }
    if !report.unchanged.isEmpty { parts.append(String(localized: "\(report.unchanged.count) unchanged")) }
    if !report.missing.isEmpty { parts.append(String(localized: "\(report.missing.count) not installed")) }
    if !report.failed.isEmpty { parts.append(String(localized: "\(report.failed.count) failed")) }
    if report.rejectedLineCount > 0 { parts.append(String(localized: "\(report.rejectedLineCount) lines ignored")) }
    if parts.isEmpty { return String(localized: "Nothing to import.") }
    return String(localized: "Imported: \(parts.joined(separator: ", ")).")
  }
}

/// Fast loads never show it; a slow one gets a spinner after a short grace period.
private struct DelayedProgress: View {
  @State private var visible = false

  var body: some View {
    ProgressView()
      .opacity(visible ? 1 : 0)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .task {
        try? await Task.sleep(for: .milliseconds(500))
        visible = true
      }
  }
}

/// The only custom glass in the app: it floats above the content, which is the navigation layer.
struct NoticeCapsule: View {
  let message: String
  var link: (title: LocalizedStringKey, url: URL)?
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Text(message)
        .font(.callout)
        .lineLimit(2)
      if let link {
        Link(destination: link.url) { Text(link.title) }
          .font(.callout)
      }
      Button(action: dismiss) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .glassEffect(.regular, in: .capsule)
    .padding(16)
  }
}

struct SidebarView: View {
  @Bindable var library: AppLibrary
  let system: SystemAppearanceController

  var body: some View {
    List(
      selection: Binding<AppLibrary.Filter?>(
        get: { library.filter },
        set: { if let filter = $0 { library.filter = filter } }
      )
    ) {
      ForEach(filters) { filter in
        Label(filter.title, systemImage: filter.symbol)
          .badge(badge(for: filter))
          .tag(filter)
      }
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SystemAppearanceSection(controller: system)
    }
  }

  private var filters: [AppLibrary.Filter] {
    AppLibrary.Filter.allCases.filter { $0 != .needsAttention || library.count(for: $0) > 0 }
  }

  /// Everything but the total depends on preferences that are still being read, so those badges
  /// appear together once they are known instead of counting up.
  private func badge(for filter: AppLibrary.Filter) -> Int {
    filter == .all || !library.isResolvingSandboxed ? library.count(for: filter) : 0
  }
}

extension View {
  /// Takes focus when it appears, so typing works at once; the search field keeps what it is given.
  /// Command, control and option combinations are left alone, so shortcuts, arrows and Tab work.
  fileprivate func typeSelectable(
    focus: FocusState<Bool>.Binding, onKey: @escaping (KeyPress) -> KeyPress.Result
  ) -> some View {
    focusable()
      .focusEffectDisabled()
      .focused(focus)
      .onAppear { focus.wrappedValue = true }
      .onKeyPress(phases: .down, action: onKey)
  }
}
