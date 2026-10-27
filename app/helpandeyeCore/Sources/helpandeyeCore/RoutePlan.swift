import Foundation

/// Which routes a call goes out on. Red and amber go at once on every route that works without
/// the caller's help (decision 8). On iPhone an app cannot send an SMS by itself, so SMS is left
/// out of the first attempt and offered as a ready-written text only if everything else failed.
public enum RoutePlan {
    public static func firstAttempt(available: Set<Route>, smsIsAutomatic: Bool) -> [Route] {
        Route.allCases.filter { available.contains($0) && ($0 != .sms || smsIsAutomatic) }
    }

    public static func offerManualSMS(for request: OutgoingRequest, smsAvailable: Bool, smsIsAutomatic: Bool) -> Bool {
        smsAvailable && !smsIsAutomatic && request.status == .notSent
    }

    /// The text of a ready-written SMS. It names no one: the responder's app maps the unit number
    /// to the person.
    public static func smsBody(for request: OutgoingRequest) -> String {
        let word = switch request.colour { case .red: "Come now"; case .amber: "Come when convenient"; case .green: "I'm OK now" }
        return "Help&I \(word). Unit \(request.unit), request \(request.number). Reply in the Help&I app."
    }
}
