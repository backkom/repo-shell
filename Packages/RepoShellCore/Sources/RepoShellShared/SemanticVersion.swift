import Foundation

public struct SemanticVersion: Comparable, Equatable, Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]

    public init(major: Int, minor: Int = 0, patch: Int = 0, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(parsing raw: String) {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty else { return nil }

        // Strip build metadata (+...)
        if let plusIdx = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[..<plusIdx])
        }

        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let corePart = String(parts[0])
        let prereleasePart = parts.count > 1 ? String(parts[1]) : ""

        let nums = corePart.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(nums.count),
              let maj = Int(nums[0]) else {
            return nil
        }
        let minVal = nums.count > 1 ? Int(nums[1]) : 0
        let patVal = nums.count > 2 ? Int(nums[2]) : 0
        guard let min = minVal, let pat = patVal, maj >= 0, min >= 0, pat >= 0 else {
            return nil
        }

        self.major = maj
        self.minor = min
        self.patch = pat
        self.prerelease = prereleasePart.isEmpty
            ? []
            : prereleasePart.split(separator: ".").map(String.init)
    }

    public var normalizedString: String {
        let base = "\(major).\(minor).\(patch)"
        if prerelease.isEmpty {
            return base
        }
        return "\(base)-\(prerelease.joined(separator: "."))"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // Stable release > prerelease
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true):
            return false
        case (true, false):
            return false
        case (false, true):
            return true
        case (false, false):
            let count = max(lhs.prerelease.count, rhs.prerelease.count)
            for idx in 0..<count {
                if idx >= lhs.prerelease.count { return true }
                if idx >= rhs.prerelease.count { return false }
                let a = lhs.prerelease[idx]
                let b = rhs.prerelease[idx]
                if a == b { continue }
                if let na = Int(a), let nb = Int(b) {
                    return na < nb
                }
                if Int(a) != nil { return true }
                if Int(b) != nil { return false }
                return a < b
            }
            return false
        }
    }

    public static func isUpdateAvailable(latest: String, current: String) -> Bool {
        guard let latestVer = SemanticVersion(parsing: latest),
              let currentVer = SemanticVersion(parsing: current) else {
            return false
        }
        return latestVer > currentVer
    }
}
