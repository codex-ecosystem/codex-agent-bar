import Foundation

struct QuotaWindow: Identifiable, Sendable {
    let id: String
    let title: String
    let shortTitle: String
    let usedPercent: Double
    let remainingPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Date?
}

struct RateLimitResetCredit: Identifiable, Sendable {
    let id: String
    let resetType: String
    let status: String
    let grantedAt: Date?
    let expiresAt: Date?
    let title: String?
    let detailText: String?
}

struct QuotaSnapshot: Sendable {
    var fiveHour: QuotaWindow?
    var weekly: QuotaWindow
    var availableResetCredits: Int?
    var resetCredits: [RateLimitResetCredit]?
    var lastUpdated: Date
    var planType: String? = nil

    func preservingResetCreditDetails(from previous: QuotaSnapshot?) -> QuotaSnapshot {
        guard
            resetCredits == nil,
            availableResetCredits != 0,
            previous?.availableResetCredits == availableResetCredits,
            let previousCredits = previous?.resetCredits
        else {
            return self
        }

        var merged = self
        merged.resetCredits = previousCredits
        return merged
    }
}

struct TokenUsageDay: Identifiable, Sendable {
    let date: Date
    let tokens: Int

    var id: TimeInterval {
        date.timeIntervalSince1970
    }
}

struct TokenUsageSnapshot: Sendable {
    let todayTokens: Int
    let yesterdayTokens: Int
    let totalTokens: Int?
    let averageWeeklyTokens: Int
    let dailyUsage: [TokenUsageDay]
    let hasDailyUsageBuckets: Bool
    let lastUpdated: Date
}

struct CodexCLIVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    var displayText: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: CodexCLIVersion, rhs: CodexCLIVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }

        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }

        return lhs.patch < rhs.patch
    }

    static func parse(_ text: String) -> CodexCLIVersion? {
        let pattern = #"(\d+)\.(\d+)\.(\d+)"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges == 4
        else {
            return nil
        }

        let values = (1..<4).compactMap { index -> Int? in
            guard let range = Range(match.range(at: index), in: text) else {
                return nil
            }

            return Int(text[range])
        }

        guard values.count == 3 else {
            return nil
        }

        return CodexCLIVersion(major: values[0], minor: values[1], patch: values[2])
    }
}

struct CodexAccount: Sendable {
    let type: String?
    let email: String?
    let planType: String?
    let requiresOpenaiAuth: Bool

    var isProPlan: Bool {
        planType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "pro"
    }
}

enum QuotaError: LocalizedError, Sendable {
    case codexCLINotFound
    case appServerStartFailed(String)
    case initializationFailed(String)
    case notSignedIn
    case unsupportedAuthMode(String?)
    case unsupportedCodexCLIVersion(current: String, required: String)
    case rpcError(String)
    case parsingFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexCLINotFound:
            return I18n.current.codexCLINotFound
        case .appServerStartFailed(let message):
            return I18n.current.appServerStartFailed(message)
        case .initializationFailed(let message):
            return I18n.current.initializationFailed(message)
        case .notSignedIn:
            return I18n.current.notSignedIn
        case .unsupportedAuthMode(let mode):
            return I18n.current.unsupportedAuthMode(mode)
        case .unsupportedCodexCLIVersion(let current, let required):
            return I18n.current.unsupportedCodexCLIVersion(current: current, required: required)
        case .rpcError(let message):
            return message
        case .parsingFailed(let message):
            return I18n.current.parsingFailed(message)
        }
    }
}
