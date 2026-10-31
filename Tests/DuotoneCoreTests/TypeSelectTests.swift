import Foundation
import Testing
@testable import DuotoneCore

@Suite struct TypeSelectTests {
  private let apps = ["Activity Monitor", "Safari", "Sail", "Slack", "Åpp", "Notes", "Numbers"].enumerated().map { index, name in
    AppInfo(
      bundleIdentifier: BundleIdentifier("t.app\(index)")!, name: name,
      url: URL(fileURLWithPath: "/tmp/\(index).app"), isSandboxed: false, isCoreService: false,
      appearance: .system, access: .available)
  }
  private let t0 = ContinuousClock.now

  private func name(_ id: BundleIdentifier?) -> String? { apps.first { $0.id == id }?.name }

  @Test func firstLetterJumpsToTheFirstMatch() {
    var select = TypeSelect()
    #expect(name(select.type("s", in: apps, now: t0)) == "Safari")
  }

  @Test func moreLettersNarrowWithinTheTimeout() {
    var select = TypeSelect()
    select.type("s", in: apps, now: t0)
    #expect(name(select.type("a", in: apps, now: t0 + .milliseconds(200))) == "Safari")
    #expect(name(select.type("i", in: apps, now: t0 + .milliseconds(400))) == "Sail")
    #expect(select.buffer == "sai")
  }

  @Test func theBufferStartsOverAfterOneIdleSecond() {
    var select = TypeSelect()
    select.type("s", in: apps, now: t0)
    select.type("l", in: apps, now: t0 + .milliseconds(300))
    #expect(name(select.target) == "Slack")
    #expect(name(select.type("n", in: apps, now: t0 + .milliseconds(1500))) == "Notes", "a new search, not 'sln'")
    #expect(select.buffer == "n")
  }

  @Test func matchingIgnoresCaseAndDiacritics() {
    var select = TypeSelect()
    #expect(name(select.type("A", in: apps, now: t0)) == "Activity Monitor")
    select.reset()
    select.type("a", in: apps, now: t0)
    #expect(name(select.type("p", in: apps, now: t0 + .milliseconds(100))) == "Åpp", "'ap' finds Åpp")
  }

  @Test func theSameLetterRepeatedNarrowsFirstAndCyclesWhenNothingLongerMatches() {
    var select = TypeSelect()
    #expect(name(select.type("s", in: apps, now: t0)) == "Safari")
    #expect(name(select.type("s", in: apps, now: t0 + .milliseconds(100))) == "Sail", "no 'ss...' app, so it cycles")
    #expect(name(select.type("s", in: apps, now: t0 + .milliseconds(200))) == "Slack")
    #expect(name(select.type("s", in: apps, now: t0 + .milliseconds(300))) == "Safari", "and wraps")
    #expect(select.buffer == "s")
  }

  @Test func noMatchKeepsTheLastTarget() {
    var select = TypeSelect()
    select.type("n", in: apps, now: t0)
    #expect(name(select.type("z", in: apps, now: t0 + .milliseconds(100))) == "Notes")
  }

  @Test func spacesOnlyCountOnceThereIsSomethingTyped() {
    var select = TypeSelect()
    #expect(select.type(" ", in: apps, now: t0) == nil)
    #expect(select.buffer.isEmpty)
    select.type("a", in: apps, now: t0)
    select.type("c", in: apps, now: t0 + .milliseconds(100))
    #expect(name(select.type(" ", in: apps, now: t0 + .milliseconds(200))) == "Activity Monitor")
    #expect(select.buffer == "ac ")
  }

  @Test func anEmptyListSelectsNothingAndClearsTheBuffer() {
    var select = TypeSelect()
    select.type("a", in: apps, now: t0)
    #expect(select.type("b", in: [], now: t0 + .milliseconds(10)) == nil)
    #expect(select.buffer.isEmpty && select.target == nil)
  }

  @Test func resetClearsTheBufferAsAFilterOrSearchChangeDoes() {
    var select = TypeSelect()
    select.type("s", in: apps, now: t0)
    select.reset()
    #expect(select.buffer.isEmpty && select.target == nil)
    #expect(name(select.type("n", in: apps, now: t0 + .milliseconds(10))) == "Notes")
  }
}
