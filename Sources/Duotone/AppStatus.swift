import DuotoneCore
import SwiftUI

/// What a row says about an app, and whether it may be changed right now.
enum AppStatus: Equatable {
  /// Sandboxed app whose preferences have not been read yet.
  case unresolved
  case current(Appearance)
  case appliesNextLaunch
  /// Music's and TV's preferences are never read, so whether macOS let the write through is unknown.
  case mediaAccessUnknown
  case stillRunning(String)
  case containerMissing(String)
  case needsPermission
  case reopenFailed(String)
  case writeFailed(String)

  init(app: AppInfo, outcome: SetAppearanceOutcome?) {
    if app.isSandboxPending {
      self = .unresolved
    } else if app.access == .locked {
      self = .needsPermission
    } else {
      switch outcome {
      case .applied(.stillRunning): self = .stillRunning(app.name)
      case .applied(.appliesOnNextLaunch): self = PreferencesAppearanceStore.isProtected(app.id) ? .mediaAccessUnknown : .appliesNextLaunch
      case .applied(.reopenFailed): self = .reopenFailed(app.name)
      case .applied where PreferencesAppearanceStore.isProtected(app.id): self = .mediaAccessUnknown
      case .failed(.containerMissing): self = .containerMissing(app.name)
      case .failed(.needsPermission): self = .needsPermission
      case .failed(.writeFailed(_, let reason)): self = .writeFailed(reason)
      default: self = .current(app.appearance)
      }
    }
  }

  /// Plain states say nothing: the picker already shows the value.
  var hasMessage: Bool {
    switch self {
    case .unresolved, .current: false
    default: true
    }
  }

  var allowsChanges: Bool {
    switch self {
    case .unresolved, .needsPermission: false
    default: true
    }
  }

  var isIssue: Bool {
    switch self {
    case .unresolved, .current, .appliesNextLaunch, .mediaAccessUnknown: false
    default: true
    }
  }

  var text: Text {
    switch self {
    case .unresolved: Text(" ")
    case .current: Text(" ")
    case .appliesNextLaunch: Text("Applies next launch")
    case .mediaAccessUnknown: Text("Applies next launch if Duotone has media access")
    case .stillRunning(let name): Text("Applies next launch: \(name) didn’t quit")
    case .containerMissing(let name): Text("Open \(name) once, then try again")
    case .needsPermission: Text("Duotone needs Full Disk Access to change this app.")
    case .reopenFailed(let name): Text("Saved, but \(name) could not be reopened.")
    case .writeFailed(let reason): Text("Could not save: \(reason)")
    }
  }
}

/// One line, whatever the width; the full sentence is in the help tag.
struct StatusLine: View {
  let status: AppStatus
  @Environment(\.openURL) private var openURL

  static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!

  var body: some View {
    Group {
      if status == .needsPermission {
        // The whole status is the link, short enough never to truncate.
        Button {
          openURL(Self.fullDiskAccessURL)
        } label: {
          Text("Needs Full Disk Access").lineLimit(1)
        }
        .buttonStyle(.link)
      } else {
        status.text
          .foregroundStyle(status.isIssue ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .font(.caption)
    .help(status.text)
  }
}
