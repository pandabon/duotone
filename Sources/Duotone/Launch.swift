import Darwin
import Foundation
import os

/// Timings for `log show --predicate 'subsystem == "dev.pandabon.duotone"'`.
enum Launch {
  static let logger = Logger(subsystem: "dev.pandabon.duotone", category: "launch")

  static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }

  /// Milliseconds since the kernel created this process, so dyld and runtime start-up count too.
  static func sinceProcessStart() -> Double {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
    let start = info.kp_proc.p_un.__p_starttime
    let startSeconds = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
    return (Date().timeIntervalSince1970 - startSeconds) * 1000
  }

  nonisolated(unsafe) private static var marked = Set<String>()

  static func markOnce(_ event: String) {
    guard marked.insert(event).inserted else { return }
    mark(event)
  }

  static func mark(_ event: String) {
    let elapsed = sinceProcessStart()
    logger.info("\(event, privacy: .public) at \(elapsed, format: .fixed(precision: 1), privacy: .public) ms since process start")
  }
}
