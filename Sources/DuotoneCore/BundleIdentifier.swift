/// A bundle identifier restricted to the characters Apple documents for CFBundleIdentifier
/// (minus non-ASCII). The restriction is what keeps identifiers safe to use as preference
/// domains and file names, so every identifier from disk or from an import goes through it.
public struct BundleIdentifier: Sendable, Hashable, Comparable, CustomStringConvertible, RawRepresentable {
  public let rawValue: String

  public init?(rawValue: String) {
    self.init(rawValue)
  }

  public init?(_ string: String) {
    guard Self.isValid(string) else { return nil }
    rawValue = string
  }

  public static func isValid(_ string: String) -> Bool {
    guard !string.isEmpty else { return false }
    // A dot-only value like ".." would turn into a path component.
    guard string.contains(where: { $0 != "." }) else { return false }
    return string.utf8.allSatisfy { byte in
      switch byte {
      case UInt8(ascii: "a")...UInt8(ascii: "z"),
           UInt8(ascii: "A")...UInt8(ascii: "Z"),
           UInt8(ascii: "0")...UInt8(ascii: "9"),
           UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "_"):
        return true
      default:
        return false
      }
    }
  }

  public var description: String { rawValue }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
