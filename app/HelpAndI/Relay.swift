import Foundation
import HelpAndICore

/// The internet route through the Help&I relay. Not set up yet in this prototype, so the app
/// says so plainly and uses the other routes.
@MainActor
final class Relay: ObservableObject {
    var onFrame: ((HelpFrame) -> Void)?
    @Published private(set) var isConfigured = false

    func configure(group: GroupState?, identity: DeviceIdentity) {}

    func send(_ frame: HelpFrame) async -> String? { "Internet route not set up yet" }
}
