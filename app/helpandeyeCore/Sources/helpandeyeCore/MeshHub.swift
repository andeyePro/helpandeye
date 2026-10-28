import Foundation

/// One box, many groups: what the box's link must offer so a responder in several groups can use
/// a single box (TODO: responders in more than one group). It listens on every group's channels
/// and sends each frame only on its own group's.
@MainActor public protocol SharedBox: AnyObject {
    var isReady: Bool { get }
    var radio: RadioSettings? { get }
    var boxPublicKey: Data? { get }
    var unavailableReason: String { get }
    /// The channel secrets to listen on, each group's current first, in order of group.
    var channelGroups: [[Data]] { get set }
    /// Whether the box holds the channel with this secret, so the group can use the radio at all.
    func hasChannel(_ secret: Data) -> Bool
    /// Sends on the channels of these secrets only.
    func send(_ frame: HelpFrame, urgent: Bool, on secrets: [Data]) async -> MeshSendResult
    func sendText(_ text: String, to key: Data) async -> MeshSendResult
    func addContact(_ key: Data, name: String) async
}

/// Shared between every group's engine on one box, so together they stay inside the band's
/// duty cycle (IR 2030).
@MainActor public final class AirtimeLedger {
    public var budget: AirtimeBudget? { didSet { onChange?(budget) } }
    /// Saves the budget, so a relaunch never gives a fresh allowance within the hour.
    public var onChange: ((AirtimeBudget?) -> Void)?
    public init(budget: AirtimeBudget? = nil) { self.budget = budget }
}

/// Gives each group's engine its own view of one shared box.
@MainActor public final class MeshHub {
    public let box: SharedBox
    public let airtime: AirtimeLedger
    private var links: [Data: HubLink] = [:]
    private var order: [Data] = []

    public init(box: SharedBox, airtime: AirtimeLedger = AirtimeLedger()) { self.box = box; self.airtime = airtime }

    /// The view for the group with this ID, made the first time it is asked for.
    public func link(for groupID: Data) -> HubLink {
        if let l = links[groupID] { return l }
        let l = HubLink(hub: self)
        links[groupID] = l
        order.append(groupID)
        return l
    }

    /// A group left on this phone: its channels are given up.
    public func remove(_ groupID: Data) {
        links[groupID] = nil
        order.removeAll { $0 == groupID }
        updateChannels()
    }

    /// A frame the box heard on the channel with this secret goes to that group's engine only.
    public func received(_ frame: HelpFrame, on secret: Data) {
        for id in order where links[id]?.secrets.contains(secret) == true { links[id]?.onFrame?(frame) }
    }

    /// A direct message goes to every group's engine; each keeps only what a member's box sent.
    public func receivedText(from prefix: Data, _ text: String) {
        for id in order { links[id]?.onText?(prefix, text) }
    }

    fileprivate func updateChannels() {
        box.channelGroups = order.compactMap { links[$0]?.secrets }.filter { !$0.isEmpty }
    }
}

/// One group's view of the shared box.
@MainActor public final class HubLink: MeshLink {
    private unowned let hub: MeshHub
    public var onFrame: ((HelpFrame) -> Void)?
    public var onText: ((Data, String) -> Void)?

    fileprivate init(hub: MeshHub) { self.hub = hub }

    /// Ready only if the box holds this group's current channel: a group squeezed off a full box
    /// says so, with the cross, rather than seeming covered.
    public var isReady: Bool { hub.box.isReady && secrets.first.map(hub.box.hasChannel) == true }
    public var radio: RadioSettings? { hub.box.radio }
    public var boxPublicKey: Data? { hub.box.boxPublicKey }
    public var unavailableReason: String {
        hub.box.isReady ? "The box has no free channel for this group" : hub.box.unavailableReason
    }
    public var channelsPerSend: Int { max(secrets.count, 1) }
    public var secrets: [Data] = [] { didSet { if secrets != oldValue { hub.updateChannels() } } }
    public var sharedAirtime: AirtimeLedger? { hub.airtime }

    public func send(_ frame: HelpFrame, urgent: Bool) async -> MeshSendResult {
        guard !secrets.isEmpty else { return .refused("No channel for this group") }
        return await hub.box.send(frame, urgent: urgent, on: secrets)
    }

    public func sendText(_ text: String, to key: Data) async -> MeshSendResult { await hub.box.sendText(text, to: key) }
    public func addContact(_ key: Data, name: String) async { await hub.box.addContact(key, name: name) }
}
