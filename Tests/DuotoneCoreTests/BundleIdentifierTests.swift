import Testing
@testable import DuotoneCore

@Suite struct BundleIdentifierTests {
  @Test(arguments: ["com.apple.Safari", "a", "com.foo-bar.Baz_1", "local.scratch.aquasandbox"])
  func accepts(_ id: String) {
    #expect(BundleIdentifier(id)?.rawValue == id)
  }

  @Test(arguments: ["", ".", "..", "com apple", "a/b", "../x", "a;b", "a$(x)", "a|b", "é.app", "a\nb", "a`b`", "a&b", "a'b", "a\"b", "a\u{0}b"])
  func rejects(_ id: String) {
    #expect(BundleIdentifier(id) == nil)
  }
}
