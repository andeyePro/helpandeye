import Foundation

/// LoRa radio settings, as reported by the board in SELF_INFO.
public struct RadioSettings: Equatable, Sendable {
    public var frequencyMHz: Double
    public var bandwidthKHz: Double
    public var spreadingFactor: Int
    /// MeshCore reports the coding rate denominator (5...8, for 4/5...4/8).
    public var codingRate: Int
    public var preambleSymbols: Int

    public init(frequencyMHz: Double, bandwidthKHz: Double, spreadingFactor: Int, codingRate: Int, preambleSymbols: Int = 16) {
        self.frequencyMHz = frequencyMHz; self.bandwidthKHz = bandwidthKHz
        self.spreadingFactor = spreadingFactor; self.codingRate = codingRate; self.preambleSymbols = preambleSymbols
    }

    /// Time on air for one LoRa packet of `bytes` (Semtech AN1200.13), explicit header, CRC on.
    public func airtime(bytes: Int) -> TimeInterval {
        let sf = Double(spreadingFactor), bw = bandwidthKHz * 1000
        let tSym = pow(2, sf) / bw
        let de = tSym > 0.016 ? 1.0 : 0.0
        let cr = Double(min(max(codingRate, 5), 8) - 4)
        let preamble = (Double(preambleSymbols) + 4.25) * tSym
        let num = 8 * Double(bytes) - 4 * sf + 28 + 16
        let symbols = 8 + max(ceil(num / (4 * (sf - 2 * de))) * (cr + 4), 0)
        return preamble + symbols * tSym
    }

    /// The licence-exempt sub-band this frequency is in (Ofcom IR 2030), with its duty-cycle limit.
    public var band: Band? { Band.all.first { $0.contains(frequencyMHz) } }
}

public struct Band: Equatable, Sendable {
    public let name: String
    public let lowMHz: Double
    public let highMHz: Double
    public let dutyCycle: Double
    public let maxERPmW: Double

    func contains(_ f: Double) -> Bool { f >= lowMHz && f <= highMHz }

    /// The IR 2030 short-range-device bands MeshCore uses in the UK. A board outside these is
    /// treated as having no allowance, so the app sends nothing optional on it.
    public static let all = [
        Band(name: "868.0–868.6 MHz", lowMHz: 868.0, highMHz: 868.6, dutyCycle: 0.01, maxERPmW: 25),
        Band(name: "869.4–869.65 MHz", lowMHz: 869.4, highMHz: 869.65, dutyCycle: 0.10, maxERPmW: 500),
    ]
}

/// Keeps this phone's own mesh sending well inside the band's duty cycle. Calls for help may use
/// the whole legal allowance; follow-ups, text and position only the part left after keeping
/// half of it free for other people's calls (decision 12, "only when there is airtime to spare").
public struct AirtimeBudget: Sendable, Codable {
    public enum Kind: Sendable { case call, optional }
    struct Entry: Codable, Sendable { let id: UUID; let at: Date; let seconds: TimeInterval }
    public var window: TimeInterval { 3600 }
    public let dutyCycle: Double
    /// Saved with the app's activity, so re-pairing the box or relaunching never gives a fresh
    /// allowance within the hour.
    private var log: [Entry] = []

    public init(dutyCycle: Double) { self.dutyCycle = max(dutyCycle, 0) }

    public func used(at now: Date) -> TimeInterval {
        log.filter { now.timeIntervalSince($0.at) < window }.reduce(0) { $0 + $1.seconds }
    }

    /// Calls may use up to 90% of the legal allowance, leaving a margin for what the firmware sends
    /// itself (adverts, direct-message acknowledgements), which is not counted here.
    public func allows(_ seconds: TimeInterval, kind: Kind, at now: Date) -> Bool {
        let limit = dutyCycle * window * (kind == .call ? 0.9 : 0.5)
        return used(at: now) + seconds <= limit
    }

    /// Reserves airtime before sending, so sends that overlap cannot each see the same allowance.
    @discardableResult
    public mutating func record(_ seconds: TimeInterval, at now: Date) -> UUID {
        let w = window
        log.removeAll { now.timeIntervalSince($0.at) >= w }
        let id = UUID()
        log.append(Entry(id: id, at: now, seconds: seconds))
        return id
    }

    /// Gives back a reservation for a send the board refused, which never went on air.
    public mutating func cancel(_ id: UUID) { log.removeAll { $0.id == id } }
}

/// Rough size on air of a MeshCore group datagram carrying `payload` bytes: packet header, path
/// length, channel hash and MAC, the data type, then AES blocks of 16 bytes.
public func meshPacketBytes(payload: Int, pathBytes: Int = 0) -> Int {
    let plaintext = 2 + payload
    return 2 + pathBytes + 1 + 2 + Int(ceil(Double(plaintext) / 16)) * 16
}
