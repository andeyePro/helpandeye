import CryptoKit
import Foundation

/// The home Wi-Fi route (decision 19): the group's phones on the same Wi-Fi network find each
/// other with Bonjour and pass every message straight to each other, with no server and no
/// internet. Each message is sealed with the group key, as for the relay, so another phone on the
/// network learns nothing but that some Help&I group is there.
@MainActor public protocol LocalLink: AnyObject {
    /// Whether this phone takes part at all; off on a watch, which goes through its phone.
    var isEnabled: Bool { get }
    /// Another of the group's phones is reachable on this network now.
    var hasPeers: Bool { get }
    var unavailableReason: String { get }
    func configure(group: GroupState?)
    /// Hands the frame to every one of the group's phones on the network. Nil once at least one
    /// took it.
    func send(_ frame: HelpFrame) async -> String?
}

/// No home Wi-Fi route: a watch, or a test that does not need one.
@MainActor public final class NoLocalLink: LocalLink {
    public init() {}
    public var isEnabled: Bool { false }
    public var hasPeers: Bool { false }
    public var unavailableReason: String { "Not used here" }
    public func configure(group: GroupState?) {}
    public func send(_ frame: HelpFrame) async -> String? { unavailableReason }
}

/// How phones on one network find and talk to each other.
public enum LocalWire {
    /// The Bonjour service type, also listed in the app's Info.plist.
    public static let serviceType = "_helpandi._tcp"

    /// The name a group's phones advertise under: from the group ID, so they find each other, but
    /// say nothing about the group to anyone else on the network.
    public static func serviceName(for group: GroupState) -> String {
        let hash = SHA256.hash(data: Data("HELPA-LAN-1".utf8) + group.secrets.groupID)
        return "helpandi-" + hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The most one message may be: a group's settings, sealed, with room to spare.
    public static let maxMessage = 8192

    /// One message on the wire: its length, then the sealed frame.
    public static func message(_ frame: HelpFrame, in group: GroupState) -> Data? {
        guard let sealed = try? RelayProtocol.seal(frame, with: group.secrets), sealed.utf8.count <= maxMessage else { return nil }
        let body = Data(sealed.utf8)
        return Data([UInt8(body.count >> 8), UInt8(body.count & 0xFF)]) + body
    }

    /// Collects bytes from one connection and gives back each whole message, sealed.
    public struct Reader: Sendable {
        private var buffer = Data()
        public private(set) var broken = false

        public init() {}

        public mutating func take(_ bytes: Data) -> [String] {
            buffer.append(bytes)
            var out: [String] = []
            while buffer.count >= 2 {
                let n = Int(buffer[buffer.startIndex]) << 8 | Int(buffer[buffer.startIndex + 1])
                // Nothing the app sends is empty or that long: the stream is not ours, or broken.
                guard n > 0, n <= LocalWire.maxMessage else { broken = true; buffer = Data(); return out }
                guard buffer.count >= 2 + n else { break }
                let body = buffer.subdata(in: buffer.startIndex + 2..<buffer.startIndex + 2 + n)
                buffer = Data(buffer.dropFirst(2 + n))
                if let s = String(data: body, encoding: .utf8) { out.append(s) }
            }
            return out
        }
    }

    /// The frame inside a message, if it opens with one of the group's keys in use.
    public static func open(_ sealed: String, in group: GroupState, at now: Date) -> HelpFrame? {
        RelayProtocol.open(sealed, with: group.listening(at: now))
    }
}
