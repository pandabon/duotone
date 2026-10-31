import Foundation

/// Finder-style type to select: what has been typed so far, and which app it points at.
/// Matching is a case- and diacritic-insensitive prefix against the order given. The buffer
/// starts over after `timeout` without a keystroke (checked against the clock handed in, so no
/// timer is needed here).
public struct TypeSelect: Sendable {
  public private(set) var buffer = ""
  public private(set) var target: BundleIdentifier?

  private let timeout: Duration
  private var lastInput: ContinuousClock.Instant?

  public init(timeout: Duration = .seconds(1)) {
    self.timeout = timeout
  }

  public mutating func reset() {
    buffer = ""
    target = nil
    lastInput = nil
  }

  /// Returns the app to select, which stays the previous one when nothing matches.
  @discardableResult
  public mutating func type(_ character: String, in apps: [AppInfo], now: ContinuousClock.Instant) -> BundleIdentifier? {
    if let lastInput, lastInput.duration(to: now) > timeout { reset() }
    guard !apps.isEmpty else {
      reset()
      return nil
    }
    // A leading space is not a search; it would only ever match names starting with a space.
    if buffer.isEmpty && character.trimmingCharacters(in: .whitespaces).isEmpty { return target }
    lastInput = now

    let folded = apps.map { Self.fold($0.name) }
    let candidate = buffer + character
    let matches = folded.indices.filter { folded[$0].hasPrefix(Self.fold(candidate)) }
    if let first = matches.first {
      buffer = candidate
      target = apps[first].id
      return target
    }

    // The same letter again with nowhere further to narrow to: cycle through that letter's apps.
    if !buffer.isEmpty, Self.fold(buffer).allSatisfy({ String($0) == Self.fold(character) }) {
      let letter = Self.fold(character)
      let starts = folded.indices.filter { folded[$0].hasPrefix(letter) }
      if !starts.isEmpty {
        let current = apps.firstIndex { $0.id == target } ?? -1
        let next = starts.first { $0 > current } ?? starts[0]
        buffer = character
        target = apps[next].id
        return target
      }
    }

    buffer = candidate  // no match: the last target stays and nothing else happens
    return target
  }

  static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }
}
