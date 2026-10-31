import CoreServices
import Foundation

/// Calls `onChange` (coalesced by the system over `latency`) when an app appears, disappears or
/// has its Info.plist or code signature replaced inside the watched folders. Events are delivered
/// by the kernel, so there are no timers and nothing wakes up while idle.
public final class AppFolderWatcher: @unchecked Sendable {
  private let roots: [String]
  private let latency: TimeInterval
  fileprivate let onChange: @Sendable () -> Void
  private let queue = DispatchQueue(label: "dev.pandabon.duotone.folderwatch", qos: .utility)
  private var stream: FSEventStreamRef?

  public init(locations: [URL], latency: TimeInterval = 2, onChange: @escaping @Sendable () -> Void) {
    roots = locations.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
    self.latency = latency
    self.onChange = onChange
  }

  deinit { stop() }

  public func start() {
    guard stream == nil, !roots.isEmpty else { return }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
      guard let info else { return }
      let watcher = Unmanaged<AppFolderWatcher>.fromOpaque(info).takeUnretainedValue()
      let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
      for index in 0..<min(count, list.count)
      where AppFolderWatcher.isRelevant(path: list[index], flags: flags[index], roots: watcher.roots) {
        watcher.onChange()
        return
      }
    }
    let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
    guard let created = FSEventStreamCreate(
      nil, callback, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
    else { return }
    FSEventStreamSetDispatchQueue(created, queue)
    FSEventStreamStart(created)
    stream = created
  }

  public func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }

  /// Only an app bundle appearing, disappearing or being renamed, or its Info.plist or
  /// CodeResources changing, matters. Everything else inside a bundle (an app rewriting its own
  /// files, an update in progress, helper apps nested in it) is ignored.
  static func isRelevant(path: String, flags: FSEventStreamEventFlags, roots: [String]) -> Bool {
    var relative = Substring(path)
    if let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
      relative = relative.dropFirst(root.count)
    }
    let presenceChanged = flags & FSEventStreamEventFlags(
      kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0
    guard let end = relative.range(of: ".app/")?.upperBound else {
      return relative.hasSuffix(".app") && presenceChanged
    }
    let inside = relative[end...]
    return inside == "Contents/Info.plist" || inside == "Contents/_CodeSignature/CodeResources"
  }
}
