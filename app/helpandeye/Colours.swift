import helpandeyeCore
import SwiftUI

extension Colour {
    var color: Color {
        // Dark enough for white words on red and green, light enough for black on amber: every
        // button's words are at least 5:1 against it.
        switch self {
        case .red: Color(red: 0xC0 / 255, green: 0x10 / 255, blue: 0x1A / 255)
        case .amber: Color(red: 1, green: 0xB0 / 255, blue: 0)
        case .green: Color(red: 0, green: 0x7A / 255, blue: 0x33 / 255)
        }
    }

    var onColor: Color { self == .amber ? .black : .white }
}
