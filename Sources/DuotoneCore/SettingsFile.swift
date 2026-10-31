/// The plain-text export format, one line per app:
/// `defaults write <bundle-id> NSRequiresAquaSystemAppearance -bool true|false`.
/// Files are only ever parsed into data; nothing in them is executed.
public struct SettingsFile: Sendable, Equatable {
  public struct Entry: Sendable, Hashable {
    public var bundleIdentifier: BundleIdentifier
    public var appearance: Appearance

    public init(bundleIdentifier: BundleIdentifier, appearance: Appearance) {
      self.bundleIdentifier = bundleIdentifier
      self.appearance = appearance
    }
  }

  /// Valid entries in file order. A repeated bundle id keeps its last value.
  public var entries: [Entry]
  /// Non-blank lines that did not match the format exactly.
  public var rejectedLineCount: Int

  public init(entries: [Entry] = [], rejectedLineCount: Int = 0) {
    self.entries = entries
    self.rejectedLineCount = rejectedLineCount
  }

  public init(parsing text: String) {
    var order: [BundleIdentifier] = []
    var values: [BundleIdentifier: Appearance] = [:]
    var rejected = 0

    for line in text.split(whereSeparator: \.isNewline) {
      let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
      if words.isEmpty { continue }
      guard let entry = Self.entry(from: words) else {
        rejected += 1
        continue
      }
      if values.updateValue(entry.appearance, forKey: entry.bundleIdentifier) == nil {
        order.append(entry.bundleIdentifier)
      }
    }

    entries = order.map { Entry(bundleIdentifier: $0, appearance: values[$0]!) }
    rejectedLineCount = rejected
  }

  /// `.system` entries have no line in this format and are skipped.
  public func serialized() -> String {
    entries.compactMap { entry in
      switch entry.appearance {
      case .light: Self.line(entry.bundleIdentifier, "true")
      case .dark: Self.line(entry.bundleIdentifier, "false")
      case .system: nil
      }
    }
    .joined()
  }

  private static func line(_ id: BundleIdentifier, _ value: String) -> String {
    "defaults write \(id.rawValue) NSRequiresAquaSystemAppearance -bool \(value)\n"
  }

  private static func entry(from words: [Substring]) -> Entry? {
    guard words.count == 6,
          words[0] == "defaults",
          words[1] == "write",
          words[3] == "NSRequiresAquaSystemAppearance",
          words[4] == "-bool",
          let id = BundleIdentifier(String(words[2]))
    else { return nil }

    switch words[5] {
    case "true": return Entry(bundleIdentifier: id, appearance: .light)
    case "false": return Entry(bundleIdentifier: id, appearance: .dark)
    default: return nil
    }
  }
}
