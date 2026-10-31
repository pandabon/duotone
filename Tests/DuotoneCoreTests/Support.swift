import Foundation

/// A throwaway directory removed when the value is released.
final class TempDirectory: @unchecked Sendable {
  let url: URL

  init() throws {
    url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("duotonecore-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }

  @discardableResult
  func makeApp(
    _ path: String, id: String?, executable: String? = "Exec", icon: Bool = false
  ) throws -> URL {
    let app = url.appendingPathComponent(path, isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var plist: [String: Any] = [:]
    if let id { plist["CFBundleIdentifier"] = id }
    if let executable { plist["CFBundleExecutable"] = executable }
    if icon { plist["CFBundleIconFile"] = "icon" }
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    return app
  }
}
