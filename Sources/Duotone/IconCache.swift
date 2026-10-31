import AppKit
import SwiftUI

private final class IconBox: @unchecked Sendable {
  let image: CGImage
  init(_ image: CGImage) { self.image = image }
}

/// Icons are rasterized once at a fixed size off the main actor, so scrolling only draws bitmaps.
/// NSWorkspace's icon appearance lookup serializes on a lock, so extra threads gain nothing: one
/// serial queue does the work, requests for the same URL share one render, and a request that is
/// cancelled before its turn (a row scrolled past) costs nothing.
final class IconCache: @unchecked Sendable {
  static let shared = IconCache()

  private static let pixelSize = 128
  private let cache = NSCache<NSURL, IconBox>()
  private let queue = DispatchQueue(label: "dev.pandabon.duotone.icons", qos: .utility)
  private let lock = NSLock()
  private var waiters: [URL: [UUID: CheckedContinuation<CGImage?, Never>]] = [:]

  init() { cache.countLimit = 400 }

  func cached(for url: URL) -> CGImage? {
    cache.object(forKey: url as NSURL)?.image
  }

  func icon(for url: URL) async -> CGImage? {
    if let hit = cached(for: url) { return hit }
    let token = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
        lock.lock()
        if Task.isCancelled {
          lock.unlock()
          continuation.resume(returning: nil)
          return
        }
        let first = waiters[url] == nil
        waiters[url, default: [:]][token] = continuation
        lock.unlock()
        if first { queue.async { self.process(url) } }
      }
    } onCancel: {
      lock.lock()
      let continuation = waiters[url]?.removeValue(forKey: token)
      if waiters[url]?.isEmpty == true { waiters[url] = nil }
      lock.unlock()
      continuation?.resume(returning: nil)
    }
  }

  private func process(_ url: URL) {
    lock.lock()
    let wanted = waiters[url]?.isEmpty == false
    lock.unlock()
    guard wanted else { return }

    let image = cached(for: url) ?? Self.render(url).map { box in
      cache.setObject(box, forKey: url as NSURL)
      return box.image
    }

    lock.lock()
    let continuations = waiters.removeValue(forKey: url)?.values ?? [:].values
    lock.unlock()
    for continuation in continuations { continuation.resume(returning: image) }
  }

  private static func render(_ url: URL) -> IconBox? {
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    var rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil).map(IconBox.init)
  }
}

struct AppIconView: View {
  let url: URL
  let size: CGFloat
  @State private var image: CGImage?

  var body: some View {
    Group {
      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .interpolation(.high)
      } else {
        Color.clear
      }
    }
    .frame(width: size, height: size)
    .task(id: url) {
      if let hit = IconCache.shared.cached(for: url) {
        image = hit
      } else {
        image = await IconCache.shared.icon(for: url)
      }
    }
    .accessibilityHidden(true)
  }
}
