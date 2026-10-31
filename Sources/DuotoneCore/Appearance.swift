/// The per-app appearance Duotone manages. `system` means no override is stored.
public enum Appearance: String, Sendable, Hashable, CaseIterable, Codable {
  case light
  case dark
  case system
}
