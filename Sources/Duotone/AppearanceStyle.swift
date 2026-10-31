import DuotoneCore
import SwiftUI

/// The one place that says what each appearance is called and drawn as.
extension Appearance {
  var titleResource: LocalizedStringResource {
    switch self {
    case .system: "System"
    case .dark: "Dark"
    case .light: "Light"
    }
  }

  var title: LocalizedStringKey { LocalizedStringKey(String(localized: titleResource)) }

  var symbol: String {
    switch self {
    case .system: "circle.lefthalf.filled"
    case .dark: "moon.fill"
    case .light: "sun.max.fill"
    }
  }
}
