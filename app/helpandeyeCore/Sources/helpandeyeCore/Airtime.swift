import Foundation

/// LoRa radio settings, as reported by the board in SELF_INFO.
public struct RadioSettings: Equatable, Sendable {
    public var frequencyMHz: Double
    public var bandwidthKHz: Double
    public var spreadingFactor: Int
    /// MeshCore reports the coding rate denominator (5...8, for 4/5...4/8).
    public var codingRate: Int
    public var preambleSymbols: Int

    /// MeshCore sends a 32-symbol preamble at spreading factor 8 and below, 16 above
    /// (`RadioLibWrapper::preambleLengthForSF`); the box does not report it.
    public init(frequencyMHz: Double, bandwidthKHz: Double, spreadingFactor: Int, codingRate: Int, preambleSymbols: Int? = nil) {
        self.frequencyMHz = frequencyMHz; self.bandwidthKHz = bandwidthKHz
        self.spreadingFactor = spreadingFactor; self.codingRate = codingRate
        self.preambleSymbols = preambleSymbols ?? (spreadingFactor <= 8 ? 32 : 16)
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

/// The antenna on a unit's box, set by its coordinator (decision 8). The transmit-power cap
/// follows from it: the band's ERP limit less the antenna's gain, allowing for the board's
/// amplifier. The two whips' gains are their makers' ratings, to be measured before boxes go out
/// (firmware/DESIGN.md, section 5).
public enum Antenna: Codable, Equatable, Hashable, Sendable {
    /// The whip that ships with the Heltec WiFi LoRa 32 V4.
    case standardWhip
    case higherGainWhip
    /// An external antenna, with its gain as rated, in dBi.
    case external(gainDBi: Double)

    public var isExternal: Bool { if case .external = self { true } else { false } }

    public var gainDBi: Double {
        switch self { case .standardWhip: 2; case .higherGainWhip: 5; case let .external(g): g }
    }

    public var words: String {
        switch self {
        case .standardWhip: "Standard whip, as supplied"
        case .higherGainWhip: "Higher-gain whip"
        case .external: "External antenna"
        }
    }

    /// The Heltec V4's amplifier after the SX1262: about 12 dB from its build comment, to be
    /// measured (firmware/DESIGN.md, section 5).
    public static let v4AmplifierGainDB: Double = 12
    /// The SX1262's output settings, in dBm.
    public static let radioSettings = -9...22
    /// The highest gain the antenna byte of set group carries (`HelpBox.antennaCode`).
    public static let maxGainDBi: Double = 63.5

    /// The gain a Help&I box is told of: rounded up to the half dB, so its cap is never looser
    /// than the antenna's, and no lower than 0 or higher than `maxGainDBi`.
    public var boxGainDBi: Double { min(max((gainDBi * 2).rounded(.up), 0), Antenna.maxGainDBi * 2) / 2 }
}

extension Band {
    /// The highest SX1262 output setting (dBm) that keeps a box inside this band's ERP limit with
    /// this antenna, allowing for the board's amplifier; nil when even the lowest setting is over,
    /// so the box must not send. The same arithmetic, on the same gain, as the firmware's
    /// `maxRadioPowerSetting`, for the box to take at provisioning. ERP is measured against a
    /// dipole, 2.15 dBi.
    public func maxRadioSetting(antenna: Antenna, amplifierGainDB: Double = Antenna.v4AmplifierGainDB) -> Int? {
        let conducted = 10 * log10(maxERPmW) + 2.15 - antenna.boxGainDBi
        let setting = Int(floor(conducted - amplifierGainDB))
        guard setting >= Antenna.radioSettings.lowerBound else { return nil }
        return min(setting, Antenna.radioSettings.upperBound)
    }
}

/// Keeps this phone's own mesh sending well inside the band's duty cycle. Calls for help may use
/// the whole legal allowance; follow-ups, text and position only the part left after keeping
/// half of it free for other people's calls (decision 12, "only when there is airtime to spare").
public struct AirtimeBudget: Sendable, Codable {
    /// A new press; a resend of a Help or Need a hand nobody has answered; anything else.
    public enum Kind: Sendable { case call, resend, optional }
    struct Entry: Codable, Sendable { let id: UUID; let at: Date; let seconds: TimeInterval }
    public var window: TimeInterval { 3600 }
    public let dutyCycle: Double
    /// Saved with the app's activity, so re-pairing the box or relaunching never gives a fresh
    /// allowance within the hour.
    private var log: [Entry] = []

    public init(dutyCycle: Double) { self.dutyCycle = max(dutyCycle, 0) }

    /// The same record under another sub-band's limit. Time used in the other sub-band still
    /// counts, which is more than the rules ask, so switching back and forth never gives a fresh
    /// allowance within the hour.
    public func moved(to dutyCycle: Double) -> AirtimeBudget {
        var b = AirtimeBudget(dutyCycle: dutyCycle)
        b.log = log
        return b
    }

    public func used(at now: Date) -> TimeInterval {
        log.filter { now.timeIntervalSince($0.at) < window }.reduce(0) { $0 + $1.seconds }
    }

    /// Calls may use up to 90% of the legal allowance, leaving a margin for what the firmware sends
    /// itself (adverts, direct-message acknowledgements), which is not counted here. Resends of
    /// unanswered calls may use up to 70%, so routine traffic (up to 50%) never leaves them none.
    public func allows(_ seconds: TimeInterval, kind: Kind, at now: Date) -> Bool {
        let share = switch kind { case .call: 0.9; case .resend: 0.7; case .optional: 0.5 }
        let limit = dutyCycle * window * share
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
    // MeshCore's group data puts its data type (2 bytes) and a length byte before the payload.
    let plaintext = 3 + payload
    return 2 + pathBytes + 1 + 2 + Int(ceil(Double(plaintext) / 16)) * 16
}
