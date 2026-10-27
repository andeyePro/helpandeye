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
        Section("Text size") {
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
