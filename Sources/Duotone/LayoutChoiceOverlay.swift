import DuotoneCore
import SwiftUI

/// Shown once on a fresh install, in the window rather than as a sheet: a sheet is modal, and a
/// modal sheet makes ⌘Q and AppleScript `quit` fail. The scrim only absorbs clicks, so quitting and
/// closing the window always work. It is only built while it is shown.
struct LayoutChoiceOverlay: View {
  let onContinue: () -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.35)
        .ignoresSafeArea()
        .contentShape(.rect)
        .onTapGesture {}  // swallows clicks meant for the window behind
        .accessibilityHidden(true)
      LayoutChoiceCard(onContinue: onContinue)
    }
    .transition(.opacity)
  }
}

/// Picking an option writes `compactBars` straight away, so the list behind already shows it.
/// `didChooseLayout` is written by the Continue button and nowhere else.
private struct LayoutChoiceCard: View {
  let onContinue: () -> Void
  @AppStorage("compactBars") private var compact = false
  @FocusState private var focused: Bool?

  var body: some View {
    VStack(spacing: 16) {
      Text("Choose a layout")
        .font(.title2.bold())
      VStack(spacing: 12) {
        option(title: "Regular", compact: false)
        option(title: "Compact", compact: true)
      }
      // Arrows move between the options, as they would in a segmented control.
      .onMoveCommand { direction in
        switch direction {
        case .up, .left: choose(false)
        case .down, .right: choose(true)
        default: break
        }
      }
      Button("Continue", action: onContinue)
        .keyboardShortcut(.return, modifiers: [])
        .controlSize(.large)
    }
    .padding(24)
    .frame(width: 468)
    .background(.regularMaterial, in: .rect(cornerRadius: 20))
    .onAppear { focused = compact }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
  }

  private func choose(_ isCompact: Bool) {
    compact = isCompact
    focused = isCompact
  }

  private func option(title: LocalizedStringKey, compact isCompact: Bool) -> some View {
    let selected = compact == isCompact
    return Button { choose(isCompact) } label: {
      VStack(spacing: 10) {
        SampleRow(compact: isCompact)
          .padding(10)
          .background(.background, in: .rect(cornerRadius: 8))
        Text(title).font(.headline)
      }
      .padding(12)
      .frame(width: 420)
      .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary), in: .rect(cornerRadius: 12))
      .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: selected ? 2 : 0) }
    }
    .buttonStyle(.plain)
    .focused($focused, equals: isCompact)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(isCompact ? Text("Compact layout, icon-only appearance bars") : Text("Regular layout, appearance bars with words"))
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }
}

/// A made-up row drawn with the real bar, which cannot be clicked here. Fixed sizes, and the name
/// never truncates, so it reads the same at any window width.
private struct SampleRow: View {
  let compact: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "app.fill")
        .font(.title2)
        .foregroundStyle(Color.accentColor)
        .frame(width: 28)
      Text("Sample App")
        .fixedSize()
      Spacer(minLength: 0)
      AppearanceBar(
        appearance: .dark, label: "", width: 225, compactWidth: 84, enabled: true, compact: compact
      ) { _ in }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
