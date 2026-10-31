import Darwin
import Foundation

/// Whether Duotone has Full Disk Access, asked without touching any other app's data.
public protocol FullDiskAccessChecking: Sendable {
  func hasFullDiskAccess() -> Bool
}

/// Opens the TCC database read-only and closes it again, reading no bytes. Without Full Disk
/// Access the open fails with EPERM or EACCES; opening it is not an access to another app's data,
/// so it does not raise macOS's "Data Access Blocked" notice.
public struct SystemFullDiskAccess: FullDiskAccessChecking {
  public init() {}

  public func hasFullDiskAccess() -> Bool {
    let path = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
    let descriptor = open(path, O_RDONLY)
    guard descriptor >= 0 else { return false }
    close(descriptor)
    return true
  }
}
