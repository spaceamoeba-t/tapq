import Foundation

/// The delegate CLI versions TapQ supports (D5): a floor and a cap, both inclusive, both
/// dotted numeric.
///
/// A cap with fewer components than the version is a prefix: "0.161" admits every 0.161.x,
/// while "2.1.293" admits nothing above 2.1.293. Missing components count as zero, so "2.1"
/// is 2.1.0. A version that is not dotted numeric ("0.161.0-alpha", "") is never contained.
public struct VersionRange: Sendable, Equatable {
    public let floor: String
    public let cap: String

    public init(floor: String, cap: String) {
        self.floor = floor
        self.cap = cap
    }

    public func contains(_ version: String) -> Bool {
        guard let found = Self.components(version),
              let floor = Self.components(floor),
              let cap = Self.components(cap) else { return false }
        return !Self.precedes(found, floor) && !Self.precedes(cap, Array(found.prefix(cap.count)))
    }

    /// "Claude Code 2.1.300 is not supported. TapQ supports 2.1.260 through 2.1.293."
    /// A prefix cap reads as its whole family: "… 0.161.0 through 0.161.x."
    public func refusal(for agent: AgentID, found: String) -> String {
        let capCount = Self.components(cap)?.count ?? 0
        let floorCount = Self.components(floor)?.count ?? 0
        let upper = capCount < floorCount ? cap + ".x" : cap
        return "\(agent.displayName) \(found) is not supported. TapQ supports \(floor) through \(upper)."
    }

    private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    /// `lhs < rhs`, component by component, a missing component counting as zero.
    private static func precedes(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
