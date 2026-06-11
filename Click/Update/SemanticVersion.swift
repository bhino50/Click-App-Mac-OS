// Only the self-updater compares versions; exclude from the App Store build
// alongside UpdateChecker.
#if !MAS_BUILD

import Foundation

/// A dot-separated numeric version such as "1.0" or "2.3.1".
///
/// Foundation-only on purpose so the comparison logic can be unit tested
/// without AppKit or networking. Missing components compare as zero, so
/// "1.0" == "1" and "1.0.1" > "1.0".
struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    let components: [Int]

    /// Parses strings like "1.0", "v2.3.1", or "1.2.3-beta". A leading
    /// "v"/"V" is dropped and anything after "-" or "+" (pre-release or
    /// build metadata) is ignored. Returns `nil` when any remaining
    /// component is not a non-negative integer.
    init?(_ string: String) {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            trimmed = String(trimmed.dropFirst())
        }
        let core = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
        let parts = core.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            parsed.append(value)
        }
        self.components = parsed
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        for (left, right) in paddedPairs(lhs, rhs) where left != right {
            return left < right
        }
        return false
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        for (left, right) in paddedPairs(lhs, rhs) where left != right {
            return false
        }
        return true
    }

    /// Pairs up components of both versions, padding the shorter one with
    /// zeros so "1.0" and "1.0.0" compare equal.
    private static func paddedPairs(
        _ lhs: SemanticVersion,
        _ rhs: SemanticVersion
    ) -> [(Int, Int)] {
        let count = max(lhs.components.count, rhs.components.count)
        return (0..<count).map { index in
            (
                index < lhs.components.count ? lhs.components[index] : 0,
                index < rhs.components.count ? rhs.components[index] : 0
            )
        }
    }
}

#endif
