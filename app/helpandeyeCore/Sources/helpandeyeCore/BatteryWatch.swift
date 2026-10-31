import Foundation

/// Guesses the mains from a stock MeshCore box's battery voltage, which is all such a box tells
/// the phone, the way a Help&I box without the mains wire does (`MainsEstimate` in the firmware's
/// `core/power.hpp`, firmware/DESIGN.md section 10), with the same numbers, so the thresholds set
/// from a box's own recordings (MANUAL-TESTS 53) serve both. On mains the charger holds the cell
/// near its charged level; when the mains goes the cell sags under the box's load and keeps
/// falling. One reading a minute, kept for two hours and compared as five-minute means: a cut is
/// the newest mean well under the highest of the two hours and still falling against half an
/// hour before, so a charger finishing and a full cell resting never show one.
public struct BatteryWatch: Equatable, Sendable {
    public typealias Mains = MeshCore.BoxInfo.Mains
    public static let sampleEvery: TimeInterval = 60
    static let block = 5
    static let blocks = 24
    static let leastBlocks = 7
    static let fallMV = 40
    static let stillFallingMV = 8
    static let riseMV = 25
    static let flatMV = 6
    static let flatBlocks = 6
    static let chargedMV = 4050
    static let confirm = 3

    private var samples: [Int] = []
    private var lastAt: Date?
    public private(set) var mains = Mains.unknown
    private var pending = Mains.unknown
    private var agreed = 0

    public init() {}

    public var probablePowerCut: Bool { mains == .off }

    /// A reading; one within a minute of the last is not taken. A verdict counts once three
    /// readings in a row agree.
    public mutating func add(_ millivolts: Int, at now: Date) {
        if let lastAt, now.timeIntervalSince(lastAt) < Self.sampleEvery { return }
        lastAt = now
        samples.append(millivolts)
        if samples.count > Self.block * Self.blocks { samples.removeFirst() }
        guard samples.count >= Self.leastBlocks * Self.block else { return }
        let reading = read()
        if reading == .unknown || reading == mains { agreed = 0; return }
        agreed = reading == pending ? agreed + 1 : 1
        pending = reading
        if agreed >= Self.confirm { mains = reading }
    }

    /// The mean of block `j` back from now: 0 is the newest five minutes.
    private func block(_ j: Int) -> Int {
        let end = samples.count - j * Self.block
        return samples[(end - Self.block)..<end].reduce(0, +) / Self.block
    }

    private func read() -> Mains {
        let means = (0..<(samples.count / Self.block)).map(block)
        let newest = means[0]
        if means.max()! - newest >= Self.fallMV, means[Self.flatBlocks] - newest >= Self.stillFallingMV { return .off }
        if newest - means.min()! >= Self.riseMV { return .on }
        let flat = means.prefix(Self.flatBlocks)
        if flat.max()! - flat.min()! <= Self.flatMV, flat.min()! >= Self.chargedMV { return .on }
        return .unknown
    }
}
