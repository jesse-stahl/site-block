import Foundation

/// The user-tunable lengths of the weaken gate: how long to wait before a weaken action can be
/// confirmed, and how long the confirmation window then stays open.
///
/// The defaults (5 min / 2 min) are also the floor — the user can make SiteBlock stricter, never
/// looser. Values are clamped on every path in, including decoding, so a hand-edited
/// `blocklist.json` can't shorten the gate either. Changing them is only allowed while blocking
/// is off (see `AppModel.setCooldownMinutes`).
public struct FrictionSettings: Codable, Equatable, Sendable {

    public static let cooldownRange = 5...120
    public static let windowRange = 2...30

    public private(set) var cooldownMinutes: Int
    public private(set) var windowMinutes: Int

    public init(cooldownMinutes: Int = cooldownRange.lowerBound, windowMinutes: Int = windowRange.lowerBound) {
        self.cooldownMinutes = Self.cooldownRange.clamp(cooldownMinutes)
        self.windowMinutes = Self.windowRange.clamp(windowMinutes)
    }

    private enum CodingKeys: String, CodingKey { case cooldownMinutes, windowMinutes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cooldownMinutes: try c.decodeIfPresent(Int.self, forKey: .cooldownMinutes) ?? Self.cooldownRange.lowerBound,
            windowMinutes: try c.decodeIfPresent(Int.self, forKey: .windowMinutes) ?? Self.windowRange.lowerBound)
    }

    public var cooldown: TimeInterval { TimeInterval(cooldownMinutes * 60) }
    public var window: TimeInterval { TimeInterval(windowMinutes * 60) }
}

private extension ClosedRange where Bound == Int {
    func clamp(_ value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
}
