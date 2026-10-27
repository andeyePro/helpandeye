import SwiftUI

/// The reader's own text size, made larger still if they choose. Kept on this phone only.
enum TextSize: String, CaseIterable, Identifiable {
    case asPhone, larger, largest

    static let key = "textSize"
    var id: Self { self }

    var label: String {
        switch self {
        case .asPhone: "As set for this phone"
        case .larger: "Larger"
        case .largest: "Largest"
        }
    }

    /// Never smaller than the choice; the phone's own setting can still make it bigger.
    var sizes: ClosedRange<DynamicTypeSize> {
        switch self {
        case .asPhone: .xSmall ... .accessibility5
        case .larger: .xxLarge ... .accessibility5
        case .largest: .accessibility2 ... .accessibility5
        }
    }
}

struct DisplaySection: View {
    @AppStorage(TextSize.key) private var size = TextSize.asPhone

    var body: some View {
        Section(header: Header("Text size")) {
            Picker("Text size", selection: $size) {
                ForEach(TextSize.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

extension View {
    /// A keyboard can always be put away: by scrolling, or with Done above it (a phone-number
    /// keyboard has no return key).
    func keyboardDismissable() -> some View {
        scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
    }
}

/// Colours chosen for contrast (WCAG AA, 4.5:1 for text): the action blue takes white text at
/// 6.5:1 in either mode; links and switches use a lighter blue in dark mode (8.6:1 on black).
extension Color {
    static let action = Color(red: 0, green: 0x55 / 255, blue: 0xD4 / 255)
    static let link = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x64 / 255, green: 0xA8 / 255, blue: 1, alpha: 1)
        : UIColor(red: 0, green: 0x55 / 255, blue: 0xD4 / 255, alpha: 1) })
    /// For warnings in words: the system red is too light on white (3.6:1).
    static let warning = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1, green: 0x6B / 255, blue: 0x6B / 255, alpha: 1)
        : UIColor(red: 0xC0 / 255, green: 0, blue: 0, alpha: 1) })
}

/// The app's buttons: a solid blue one for the main action, an outlined one for the rest, both
/// at least 44 points high.
struct ActionButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, prominent: prominent)
    }

    private struct Styled: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.vertical, 10).padding(.horizontal, 14)
                .frame(minHeight: 44)
                .foregroundStyle(solid ? Color.white : Color.primary)
                .background(solid ? Color.action : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(solid ? Color.clear : Color.primary, style: StrokeStyle(lineWidth: 2, dash: enabled ? [] : [6, 4])))
                .opacity(configuration.isPressed ? 0.7 : 1)
        }

        /// A button that cannot be pressed yet is drawn outlined and dashed, never faded, so its
        /// words stay as readable as everything else.
        private var solid: Bool { prominent && enabled }
    }
}

extension ButtonStyle where Self == ActionButtonStyle {
    static var action: ActionButtonStyle { ActionButtonStyle() }
    static var secondaryAction: ActionButtonStyle { ActionButtonStyle(prominent: false) }
}

/// A text box with its label always shown above it, rather than as a placeholder that vanishes
/// once typing starts or is cut off at large text sizes.
struct LabeledField: View {
    let label: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
            TextField(label, text: $text, prompt: Text(""))
                .accessibilityLabel(label)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .URL ? .never : .sentences)
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// A section heading in the normal text colour: the system's grey ones are too faint to read.
struct Header: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View { Text(title).font(.headline).foregroundStyle(Color.primary).textCase(nil) }
}
