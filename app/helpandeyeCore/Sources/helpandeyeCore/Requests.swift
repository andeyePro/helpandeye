import Foundation

/// The ways a request can travel (decision 8).
public enum Route: String, Sendable, CaseIterable, Codable {
    case internet, sms, mesh
}

public enum RouteState: Equatable, Sendable, Codable {
    case sending
    case sent
    case failed(String)
}

/// What the caller is shown. There is deliberately no "delivered" state: a route accepting a
/// message is not a person reading it (decision 7). Only a responder's acknowledgement moves a
/// request to `seen`, and nothing moves it on a timer.
public enum CallerStatus: Equatable, Sendable {
    case sending
    case waitingForResponder
    case seen(responder: UInt16)
    /// The cross: nothing could be sent on any route.
    case notSent
}

/// A request as the caller's app tracks it.
public struct OutgoingRequest: Equatable, Sendable, Codable {
    public let unit: UInt32
    public let number: UInt16
    public let colour: Colour
    public let createdAt: Date
    public private(set) var routes: [Route: RouteState] = [:]
    public private(set) var categories: [CallCategory] = []
    /// The follow-up part each category went in, so it can be taken back.
    private var categoryParts: [CallCategory: UInt8] = [:]
    public private(set) var notes: [String] = []
    public private(set) var acknowledgedBy: [UInt16] = []
    /// Takes back acknowledgements from people no longer in the group: one heard from a phone
    /// before this phone learned it had been removed must not go on reassuring the caller.
    public mutating func revoke(keeping members: Set<UInt16>) {
        acknowledgedBy.removeAll { !members.contains($0) }
    }

    /// Follow-ups, notes and positions share one numbering, so each part is distinct.
    private var parts: UInt8 = 0
    /// How many times the call has been sent again (see `Resend`).
    public private(set) var resends = 0

    /// Records a resend. After a long sleep, slots that were missed are skipped rather than sent
    /// back to back.
    public mutating func markResent(at now: Date) {
        resends += 1
        while now >= Resend.due(resends + 1, after: createdAt) { resends += 1 }
    }

    public init(unit: UInt32, number: UInt16, colour: Colour, createdAt: Date) {
        self.unit = unit; self.number = number; self.colour = colour; self.createdAt = createdAt
    }

    public mutating func update(_ route: Route, _ state: RouteState) { routes[route] = state }

    /// Returns the follow-up frame to send, numbered after any categories already added.
    public mutating func add(_ category: CallCategory) -> HelpFrame {
        categories.append(category)
        let part = nextPart()
        categoryParts[category] = part
        return .followUp(unit: unit, request: number, part: part, category: category)
    }

    /// Takes back a category, in the same part, so responders' phones remove it.
    public mutating func withdraw(_ category: CallCategory) -> HelpFrame? {
        guard let part = categoryParts[category] else { return nil }
        categories.removeAll { $0 == category }
        categoryParts[category] = nil
        return .followUp(unit: unit, request: number, part: part, category: .withdrawn)
    }

    public mutating func addNote(_ typed: String) -> HelpFrame {
        let frame = HelpFrame.note(unit: unit, request: number, part: nextPart(), typed: typed)
        if case let .note(_, _, _, text) = frame { notes.append(text) }
        return frame
    }

    private mutating func nextPart() -> UInt8 {
        parts = parts == 255 ? 255 : parts + 1
        return parts
    }

    /// How far a responder's clock may be behind the caller's.
    public static let clockAllowance: TimeInterval = 300

    /// Records an acknowledgement that came back over any route. Only a frame for this request
    /// counts, so an acknowledgement of some other request can never reassure this caller, and
    /// nor can one made before this request existed (a stale one for a reused number). Check the
    /// signature with `HelpFrame.isValidAck` before calling this.
    public mutating func receive(_ frame: HelpFrame) {
        guard case let .ack(u, r, who, at, _) = frame, u == unit, r == number,
              TimeInterval(at) >= createdAt.timeIntervalSince1970 - Self.clockAllowance else { return }
        if !acknowledgedBy.contains(who) { acknowledgedBy.append(who) }
    }

    public var status: CallerStatus {
        if let first = acknowledgedBy.first { return .seen(responder: first) }
        let states = Array(routes.values)
        if states.contains(.sent) { return .waitingForResponder }
        if states.contains(.sending) { return .sending }
        // Nothing attempted is nothing sent: the caller gets the cross, not "Sending…" for ever.
        return .notSent
    }

    public var callFrame: HelpFrame {
        .call(unit: unit, request: number, colour: colour, sentAt: UInt32(createdAt.timeIntervalSince1970))
    }
}

/// A request as a responder's app sees it, assembled from frames that may arrive in any order,
/// more than once, and over several routes.
public struct IncomingRequest: Equatable, Sendable, Identifiable, Codable {
    public struct Key: Hashable, Sendable, Codable {
        public let unit: UInt32
        public let request: UInt16
        public init(unit: UInt32, request: UInt16) { self.unit = unit; self.request = request }
    }
    public var id: Key { key }
    public let key: Key
    public internal(set) var colour: Colour?
    public internal(set) var firstHeardAt: Date
    /// When the caller pressed, from the call itself. Escalation counts from this, so every phone
    /// works out the same turns however late it heard.
    public internal(set) var sentAt: Date?
    public internal(set) var categories: [UInt8: CallCategory] = [:]
    /// Parts the caller took back. A copy of the original heard late does not bring one back.
    public internal(set) var withdrawnParts: Set<UInt8> = []
    public internal(set) var heardOn: Set<Route> = []
    public internal(set) var acknowledgedBy: [UInt16] = []
    public internal(set) var notes: [UInt8: String] = [:]
    /// The signed acknowledgements heard, so any phone can pass one on to a caller still waiting.
    public internal(set) var acks: [UInt16: HelpFrame] = [:]
    public internal(set) var position: Position?

    public struct Position: Equatable, Sendable, Codable {
        public let latitude: Double
        public let longitude: Double
        public let accuracy: Double
    }

    public var isAcknowledged: Bool { !acknowledgedBy.isEmpty }
    public var orderedNotes: [String] { notes.keys.sorted().compactMap { notes[$0] } }
    public var orderedCategories: [CallCategory] { categories.keys.sorted().compactMap { categories[$0] } }
}

public enum InboxEvent: Equatable, Sendable {
    /// A request this phone had not heard before: sound the alert.
    case new(IncomingRequest.Key)
    case updated(IncomingRequest.Key)
    case duplicate
    case ignored
}

/// The responder's list of requests. It never closes, expires or acknowledges anything by itself:
/// a request leaves the open list only when a person presses acknowledge (decision 6).
public struct ResponderInbox: Sendable, Codable {
    public private(set) var requests: [IncomingRequest.Key: IncomingRequest] = [:]

    public init() {}

    @discardableResult
    public mutating func receive(_ frame: HelpFrame, via route: Route, at now: Date) -> InboxEvent {
        switch frame {
        case let .call(unit, request, colour, sentAt):
            let key = IncomingRequest.Key(unit: unit, request: request)
            let pressed = Date(timeIntervalSince1970: TimeInterval(sentAt))
            // The same numbers pressed at a different time are a new call (the caller's phone was
            // restored from a backup, say), never a repeat of an old one.
            if let old = requests[key]?.sentAt, abs(old.timeIntervalSince(pressed)) > OutgoingRequest.clockAllowance {
                requests[key] = IncomingRequest(key: key, colour: colour, firstHeardAt: now, sentAt: pressed, heardOn: [route])
                return .new(key)
            }
            if var existing = requests[key] {
                let changed = existing.colour == nil || !existing.heardOn.contains(route)
                existing.colour = existing.colour ?? colour
                if existing.sentAt == nil {
                    existing.sentAt = pressed
                    // Acknowledgements heard before the call can now be checked: ones from before
                    // it was pressed belong to an older call with the same numbers.
                    let cutoff = pressed.timeIntervalSince1970 - OutgoingRequest.clockAllowance
                    let wasAcknowledged = existing.isAcknowledged
                    for (who, f) in existing.acks {
                        if case let .ack(_, _, _, at, _) = f, TimeInterval(at) < cutoff {
                            existing.acks[who] = nil
                            existing.acknowledgedBy.removeAll { $0 == who }
                        }
                    }
                    if wasAcknowledged && !existing.isAcknowledged {
                        existing.heardOn.insert(route)
                        requests[key] = existing
                        return .new(key)
                    }
                }
                existing.heardOn.insert(route)
                requests[key] = existing
                return changed ? .updated(key) : .duplicate
            }
            requests[key] = IncomingRequest(key: key, colour: colour, firstHeardAt: now, sentAt: pressed, heardOn: [route])
            return .new(key)
        case let .followUp(unit, request, part, category):
            let key = IncomingRequest.Key(unit: unit, request: request)
            // A follow-up can overtake its call. Keep it, so the call completes the request when it
            // arrives, and alert now: a follow-up means somebody pressed for help.
            var r = requests[key] ?? IncomingRequest(key: key, colour: nil, firstHeardAt: now)
            let isNew = requests[key] == nil && !r.isAcknowledged
            let wanted = category == .withdrawn || r.withdrawnParts.contains(part) ? nil : category
            let changed = r.categories[part] != wanted
            r.categories[part] = wanted
            if category == .withdrawn { r.withdrawnParts.insert(part) }
            r.heardOn.insert(route)
            requests[key] = r
            return isNew ? .new(key) : (changed ? .updated(key) : .duplicate)
        case let .ack(unit, request, responder, ackedAt, _):
            // Check the signature with `HelpFrame.isValidAck` before calling this. An ack can
            // overtake its call; keep it, so the call arrives already acknowledged and nobody is
            // alerted for something already in hand. An ack from before the call was pressed is
            // stale, as on the caller's side, so both sides agree on whether it counts.
            let key = IncomingRequest.Key(unit: unit, request: request)
            var r = requests[key] ?? IncomingRequest(key: key, colour: nil, firstHeardAt: now)
            if let s = r.sentAt, TimeInterval(ackedAt) < s.timeIntervalSince1970 - OutgoingRequest.clockAllowance { return .ignored }
            guard !r.acknowledgedBy.contains(responder) else { return .duplicate }
            r.acknowledgedBy.append(responder)
            r.acks[responder] = frame
            r.heardOn.insert(route)
            requests[key] = r
            return .updated(key)
        case let .note(unit, request, part, text):
            let key = IncomingRequest.Key(unit: unit, request: request)
            var r = requests[key] ?? IncomingRequest(key: key, colour: nil, firstHeardAt: now)
            let isNew = requests[key] == nil && !r.isAcknowledged
            let changed = r.notes[part] != text
            r.notes[part] = text
            r.heardOn.insert(route)
            requests[key] = r
            return isNew ? .new(key) : (changed ? .updated(key) : .duplicate)
        case let .position(unit, request, lat, lon, accuracy):
            let key = IncomingRequest.Key(unit: unit, request: request)
            var r = requests[key] ?? IncomingRequest(key: key, colour: nil, firstHeardAt: now)
            let isNew = requests[key] == nil && !r.isAcknowledged
            let p = IncomingRequest.Position(latitude: Double(lat) / 1e7, longitude: Double(lon) / 1e7, accuracy: Double(accuracy))
            let changed = r.position != p
            r.position = p
            r.heardOn.insert(route)
            requests[key] = r
            return isNew ? .new(key) : (changed ? .updated(key) : .duplicate)
        case .availability, .noticeAck, .checkIns, .board, .signed, .memberAdded, .memberRemoved, .memberName, .memberRole, .memberPhone, .forResponders:
            return .ignored
        }
    }

    /// Called only from the acknowledge button. Returns the signed frame to send back.
    public mutating func acknowledge(_ key: IncomingRequest.Key, by responder: UInt16, at now: Date, identity: DeviceIdentity, group: Data) -> HelpFrame? {
        guard var r = requests[key] else { return nil }
        let frame = HelpFrame.signedAck(unit: key.unit, request: key.request, responder: responder, at: now, identity: identity, group: group)
        if !r.acknowledgedBy.contains(responder) { r.acknowledgedBy.append(responder) }
        r.acks[responder] = frame
        requests[key] = r
        return frame
    }

    /// Takes back acknowledgements from people no longer in the group. Returns the requests that
    /// are open again, so their alerts can start again.
    public mutating func revoke(keeping members: Set<UInt16>) -> [IncomingRequest.Key] {
        var reopened: [IncomingRequest.Key] = []
        for (k, var r) in requests where r.acknowledgedBy.contains(where: { !members.contains($0) }) {
            r.acknowledgedBy.removeAll { !members.contains($0) }
            r.acks = r.acks.filter { members.contains($0.key) }
            requests[k] = r
            if !r.isAcknowledged { reopened.append(k) }
        }
        return reopened
    }

    /// Forgets requests, for pruning old ones. Callers must never remove one nobody acknowledged.
    public mutating func remove(_ keys: [IncomingRequest.Key]) { for k in keys { requests[k] = nil } }

    /// Open requests, most urgent first: unacknowledged before acknowledged, red before amber
    /// before green, then oldest first.
    public var sorted: [IncomingRequest] {
        requests.values.sorted { a, b in
            if a.isAcknowledged != b.isAcknowledged { return !a.isAcknowledged }
            let ca = a.colour?.rawValue ?? 0, cb = b.colour?.rawValue ?? 0
            if ca != cb { return ca < cb }
            return a.firstHeardAt < b.firstHeardAt
        }
    }
}

// Saved requests are read tolerantly: a field added in a later version gets its default, so an
// update never throws away a request that is still open.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, or fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}

extension OutgoingRequest {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = try c.decode(UInt32.self, forKey: .unit)
        number = try c.decode(UInt16.self, forKey: .number)
        colour = try c.decode(Colour.self, forKey: .colour)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        routes = try c.value(.routes, or: [:])
        categories = try c.value(.categories, or: [])
        categoryParts = try c.value(.categoryParts, or: [:])
        notes = try c.value(.notes, or: [])
        acknowledgedBy = try c.value(.acknowledgedBy, or: [])
        parts = try c.value(.parts, or: 0)
        resends = try c.value(.resends, or: 0)
    }
}

extension IncomingRequest {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(Key.self, forKey: .key)
        colour = try c.decodeIfPresent(Colour.self, forKey: .colour)
        firstHeardAt = try c.decode(Date.self, forKey: .firstHeardAt)
        sentAt = try c.decodeIfPresent(Date.self, forKey: .sentAt)
        categories = try c.value(.categories, or: [:])
        withdrawnParts = try c.value(.withdrawnParts, or: [])
        heardOn = try c.value(.heardOn, or: [])
        acknowledgedBy = try c.value(.acknowledgedBy, or: [])
        notes = try c.value(.notes, or: [:])
        acks = try c.value(.acks, or: [:])
        position = try c.decodeIfPresent(Position.self, forKey: .position)
    }
}
