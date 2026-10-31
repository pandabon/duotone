import Testing
@testable import DuotoneCore

@Suite struct SettingsFileTests {
  private func id(_ s: String) -> BundleIdentifier { BundleIdentifier(s)! }

  @Test func parsesOldFormat() {
    let text = """
    defaults write com.apple.Safari NSRequiresAquaSystemAppearance -bool true

    defaults write com.foo.Bar NSRequiresAquaSystemAppearance -bool false
    """
    let file = SettingsFile(parsing: text)
    #expect(file.rejectedLineCount == 0)
    #expect(file.entries == [
      .init(bundleIdentifier: id("com.apple.Safari"), appearance: .light),
      .init(bundleIdentifier: id("com.foo.Bar"), appearance: .dark),
    ])
  }

  @Test func roundTrips() {
    let original = SettingsFile(entries: [
      .init(bundleIdentifier: id("a.b"), appearance: .light),
      .init(bundleIdentifier: id("c.d"), appearance: .dark),
    ])
    #expect(SettingsFile(parsing: original.serialized()) == original)
    #expect(original.serialized() == """
    defaults write a.b NSRequiresAquaSystemAppearance -bool true
    defaults write c.d NSRequiresAquaSystemAppearance -bool false

    """)
  }

  @Test func systemEntriesAreNotExported() {
    let file = SettingsFile(entries: [.init(bundleIdentifier: id("a.b"), appearance: .system)])
    #expect(file.serialized().isEmpty)
  }

  @Test func handlesCRLFAndTabs() {
    let file = SettingsFile(parsing: "defaults\twrite a.b NSRequiresAquaSystemAppearance -bool true\r\n")
    #expect(file.entries.count == 1 && file.rejectedLineCount == 0)
  }

  @Test func repeatedIdKeepsLastValue() {
    let file = SettingsFile(parsing: """
    defaults write a.b NSRequiresAquaSystemAppearance -bool true
    defaults write a.b NSRequiresAquaSystemAppearance -bool false
    """)
    #expect(file.entries == [.init(bundleIdentifier: id("a.b"), appearance: .dark)])
  }

  @Test func rejectsMaliciousAndMalformedLines() {
    let lines = [
      "defaults write ;curl${IFS}x|sh;y NSRequiresAquaSystemAppearance -bool true",
      "defaults write a.b; rm -rf ~ NSRequiresAquaSystemAppearance -bool true",
      "defaults write $(whoami) NSRequiresAquaSystemAppearance -bool true",
      "defaults write a.b NSRequiresAquaSystemAppearance -bool true; echo hi",
      "defaults write a.b NSRequiresAquaSystemAppearance -bool yes",
      "defaults write a.b NSSomethingElse -bool true",
      "defaults delete a.b NSRequiresAquaSystemAppearance -bool true",
      "defaults write a.b NSRequiresAquaSystemAppearance -string true",
      "sudo defaults write a.b NSRequiresAquaSystemAppearance -bool true",
      "defaults write ../../etc/passwd NSRequiresAquaSystemAppearance -bool true",
      "echo hello",
    ]
    let file = SettingsFile(parsing: lines.joined(separator: "\n") + "\ndefaults write ok.app NSRequiresAquaSystemAppearance -bool true")
    #expect(file.rejectedLineCount == lines.count)
    #expect(file.entries == [.init(bundleIdentifier: id("ok.app"), appearance: .light)])
  }
}
