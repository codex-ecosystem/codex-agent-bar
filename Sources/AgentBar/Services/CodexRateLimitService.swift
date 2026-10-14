import Foundation

struct CodexRateLimitService {
    func readRateLimits(client: CodexAppServerClient, completion: @escaping @Sendable (Result<QuotaSnapshot, Error>) -> Void) {
        client.sendRequest(method: "account/rateLimits/read") { result in
            switch result {
            case .success(let response):
                do {
                    completion(.success(try parseRateLimitResponse(response)))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func parseRateLimitResponse(_ response: CodexAppServerClient.JSONDictionary) throws -> QuotaSnapshot {
        guard let result = response["result"] as? CodexAppServerClient.JSONDictionary else {
            throw QuotaError.parsingFailed(I18n.current.missingRateLimitResult)
        }

        let fallbackBucket = result["rateLimits"] as? CodexAppServerClient.JSONDictionary
        let codexBucket = (result["rateLimitsByLimitId"] as? CodexAppServerClient.JSONDictionary)?["codex"] as? CodexAppServerClient.JSONDictionary
        let buckets = [codexBucket, fallbackBucket].compactMap { $0 }

        var windows: [QuotaWindow] = []
        for bucket in buckets {
            appendWindow(named: "primary", from: bucket, into: &windows)
            appendWindow(named: "secondary", from: bucket, into: &windows)
        }

        windows = uniqueWindows(windows).sorted { lhs, rhs in
            (lhs.windowDurationMins ?? Int.max) < (rhs.windowDurationMins ?? Int.max)
        }

        guard let weekly = windows.first(where: { $0.windowDurationMins == 10080 }) else {
            throw QuotaError.parsingFailed(I18n.current.missingWeeklyQuotaWindow)
        }

        let fiveHour = windows.first(where: { $0.windowDurationMins == 300 })
        let resetCredits = resetCreditsSummary(from: result)
        let snapshot = QuotaSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            availableResetCredits: resetCredits.availableCount,
            resetCredits: resetCredits.credits,
            lastUpdated: Date(),
            planType: buckets.compactMap { stringValue($0["planType"]) }.first
        )

        return snapshot
    }

    private func appendWindow(
        named fieldName: String,
        from bucket: CodexAppServerClient.JSONDictionary,
        into windows: inout [QuotaWindow]
    ) {
        guard let window = bucket[fieldName] as? CodexAppServerClient.JSONDictionary else {
            return
        }

        let duration = intValue(window["windowDurationMins"])
        let used = doubleValue(window["usedPercent"]) ?? 0
        let remaining = max(0, min(100, 100 - used))
        let resetTimestamp = doubleValue(window["resetsAt"])
        let resetDate = resetTimestamp.map { Date(timeIntervalSince1970: $0) }
        let title = windowTitle(durationMins: duration, fallback: bucket["limitName"] as? String ?? bucket["limitId"] as? String)
        let shortTitle = shortWindowTitle(durationMins: duration, fallback: title)

        windows.append(
            QuotaWindow(
                id: "\(bucket["limitId"] as? String ?? "codex")-\(fieldName)-\(duration.map(String.init) ?? "unknown")",
                title: "\(title) \(I18n.current.windowSuffix)",
                shortTitle: shortTitle,
                usedPercent: max(0, min(100, used)),
                remainingPercent: remaining,
                windowDurationMins: duration,
                resetsAt: resetDate
            )
        )
    }

    private func uniqueWindows(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        var seen = Set<String>()
        return windows.filter { window in
            let key = window.windowDurationMins.map(String.init) ?? window.id
            if seen.contains(key) {
                return false
            }

            seen.insert(key)
            return true
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }

        if let value = value as? Double {
            return Int(value)
        }

        if let value = value as? String {
            return Int(value)
        }

        return nil
    }

    private func resetCreditsSummary(
        from result: CodexAppServerClient.JSONDictionary
    ) -> (availableCount: Int?, credits: [RateLimitResetCredit]?) {
        guard let resetCredits = result["rateLimitResetCredits"] as? CodexAppServerClient.JSONDictionary else {
            return (nil, nil)
        }

        let availableCount = intValue(resetCredits["availableCount"])
        guard let rawCredits = resetCredits["credits"], !(rawCredits is NSNull) else {
            return (availableCount, nil)
        }

        guard let creditRows = rawCredits as? [Any] else {
            return (availableCount, nil)
        }

        let credits = creditRows.enumerated().compactMap { index, rawCredit -> RateLimitResetCredit? in
            guard let credit = rawCredit as? CodexAppServerClient.JSONDictionary else {
                return nil
            }

            let grantedAt = doubleValue(credit["grantedAt"])
                .map(Date.init(timeIntervalSince1970:))
            let expiresAt = doubleValue(credit["expiresAt"])
                .map(Date.init(timeIntervalSince1970:))
            let fallbackID = "reset-credit-\(index)-\(grantedAt?.timeIntervalSince1970 ?? 0)"

            return RateLimitResetCredit(
                id: stringValue(credit["id"]) ?? fallbackID,
                resetType: stringValue(credit["resetType"]) ?? "unknown",
                status: stringValue(credit["status"]) ?? "unknown",
                grantedAt: grantedAt,
                expiresAt: expiresAt,
                title: stringValue(credit["title"]),
                detailText: stringValue(credit["description"])
            )
        }
        .sorted { lhs, rhs in
            switch (lhs.expiresAt, rhs.expiresAt) {
            case let (lhsDate?, rhsDate?):
                if lhsDate == rhsDate {
                    return lhs.id < rhs.id
                }

                return lhsDate < rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.id < rhs.id
            }
        }

        return (availableCount, credits)
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }

        if let value = value as? Int {
            return Double(value)
        }

        if let value = value as? String {
            return Double(value)
        }

        return nil
    }

    private func windowTitle(durationMins: Int?, fallback: String?) -> String {
        guard let durationMins else {
            return fallback ?? I18n.current.quotaFallbackTitle
        }

        switch durationMins {
        case 10080:
            return "1w"
        case ..<1440:
            return "\(max(1, durationMins / 60))h"
        default:
            return "\(max(1, durationMins / 1440))d"
        }
    }

    private func shortWindowTitle(durationMins: Int?, fallback: String) -> String {
        guard let durationMins else {
            return fallback
        }

        switch durationMins {
        case 10080:
            return I18n.current.shortWeek
        case ..<1440:
            return "\(max(1, durationMins / 60))h"
        default:
            return "\(max(1, durationMins / 1440))d"
        }
    }

}
