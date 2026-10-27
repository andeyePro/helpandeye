import Foundation

/// The ways a request can travel (decision 8).
public enum Route: String, Sendable, CaseIterable, Codable {
    case internet, sms, mesh
}

public enum RouteState: Equatable, Sendable {
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
public struct OutgoingRequest: Equatable, Sendable {
    public let unit: UInt32
    public let number: UInt16
    public let colour: Colour
    public let createdAt: Date
    public private(set) var routes: [Route: RouteState] = [:]
    public private(set) var categories: [CallCategory] = []
    public private(set) var acknowledgedBy: [UInt16] = []

    public init(unit: UInt32, number: UInt16, colour: Colour, createdAt: Date) {
        self.unit = unit; self.number = number; self.colour = colour; self.createdAt = createdAt
    }

    public mutating func update(_ route: Route, _ state: RouteState) { routes[route] = state }

    /// Returns the follow-up frame to send, numbered after any categories already added.
    public mutating func add(_ category: CallCategory) -> HelpFrame {
        categories.append(category)
        return .followUp(unit: unit, request: number, part: UInt8(min(categories.count, 255)), category: category)
    }

    /// Records an acknowledgement that came back over any route. Only a frame for this request
    /// counts, so an acknowledgement of some other request can never reassure this caller.
    public mutating func receive(_ frame: HelpFrame) {
        guard case let .ack(u, r, who, _) = frame, u == unit, r == number else { return }
        if !acknowledgedBy.contains(who) { acknowledgedBy.append(who) }
    }

    public var status: CallerStatus {
        if let first = acknowledgedBy.first { return .seen(responder: first) }
        let states = Array(routes.values)
        if states.contains(.sent) { return .waitingForResponder }
        if states.contains(.sending) || states.isEmpty { return .sending }
        return .notSent
    }

    public var callFrame: HelpFrame {
        .call(unit: unit, request: number, colour: colour, sentAt: UInt32(createdAt.timeIntervalSince1970))
    }
}

/// A request as a responder's app sees it, assembled from frames that may arrive in any order,
/// more than once, and over several routes.
public struct IncomingRequest: Equatable, Sendable, Identifiable {
    public struct Key: Hashable, Sendable { public let unit: UInt32; public let request: UInt16 }
    public var id: Key { key }
    public let key: Key
    public internal(set) var colour: Colour?
    public internal(set) var firstHeardAt: Date
    public internal(set) var categories: [UInt8: CallCategory] = [:]
    public internal(set) var heardOn: Set<Route> = []
    public internal(set) var acknowledgedBy: [UInt16] = []

    public var isAcknowledged: Bool { !acknowledgedBy.isEmpty }
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
public struct ResponderInbox: Sendable {
    public private(set) var requests: [IncomingRequest.Key: IncomingRequest] = [:]

    public init() {}

    @discardableResult
    public mutating func receive(_ frame: HelpFrame, via route: Route, at now: Date) -> InboxEvent {
        switch frame {
        case let .call(unit, request, colour, _):
            let key = IncomingRequest.Key(unit: unit, request: request)
            if var existing = requests[key] {
                let changed = existing.colour == nil || !existing.heardOn.contains(route)
                existing.colour = existing.colour ?? colour
                existing.heardOn.insert(route)
                requests[key] = existing
                return changed ? .updated(key) : .duplicate
            }
            requests[key] = IncomingRequest(key: key, colour: colour, firstHeardAt: now, heardOn: [route])
            return .new(key)
        case let .followUp(unit, request, part, category):
            let key = IncomingRequest.Key(unit: unit, request: request)
            // A follow-up can overtake its call. Keep it, so the call completes the request when it
            // arrives, and alert now: a follow-up means somebody pressed for help.
            var r = requests[key] ?? IncomingRequest(key: key, colour: nil, firstHeardAt: now)
            let isNew = requests[key] == nil
            let changed = r.categories[part] != category
            r.categories[part] = category
            r.heardOn.insert(route)
            requests[key] = r
            return isNew ? .new(key) : (changed ? .updated(key) : .duplicate)
        case let .ack(unit, request, responder, _):
            let key = IncomingRequest.Key(unit: unit, request: request)
            guard var r = requests[key] else { return .ignored }
            guard !r.acknowledgedBy.contains(responder) else { return .duplicate }
            r.acknowledgedBy.append(responder)
            requests[key] = r
            return .updated(key)
        case .availability, .noticeAck:
            return .ignored
        }
    }

    /// Called only from the acknowledge button. Returns the frame to send back to the caller.
    public mutating func acknowledge(_ key: IncomingRequest.Key, by responder: UInt16, at now: Date) -> HelpFrame? {
        guard var r = requests[key] else { return nil }
        if !r.acknowledgedBy.contains(responder) { r.acknowledgedBy.append(responder) }
        requests[key] = r
        return .ack(unit: key.unit, request: key.request, responder: responder, ackedAt: UInt32(now.timeIntervalSince1970))
    }

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
