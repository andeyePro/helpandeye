import helpandeyeCore
import SwiftUI

extension Image {
    /// A button's symbol by name: one of Help&I's own figures, or Apple's.
    init(symbol name: String) {
        self = Profile.ownSymbols.contains(name) ? Image(name) : Image(systemName: name)
    }
}
