import Foundation

enum I18n {
    enum Language {
        case english
        case simplifiedChinese
    }

    struct Strings {
        let codexQuota: String
        let loadingQuota: String
        let refreshingQuota: String
        let quotaLoaded: String
        let loading: String
        let notRefreshed: String
        let lastRefreshPrefix: String
        let refreshNow: String
        let aboutUs: String
        let quit: String
        let checkForUpdates: String
        let checkingForUpdates: String
        let updateCheckUpToDate: String
        let updateCheckFailed: String
        let updateAvailable: String
        let downloadingUpdate: String
        let updateDownloaded: String
        let installUpdate: String
        let recentWeek: String
        let shortWeek: String
        let resetTimeUnavailable: String
        let resetSoon: String
        let refreshAtSuffix: String
        let dayUnit: String
        let hourUnit: String
        let minuteUnit: String
        let refreshAfterSuffix: String
        let dateLocaleIdentifier: String
        let dateFormat: String
        let quotaFallbackTitle: String
        let windowSuffix: String
        let codexCLINotFound: String
        let notSignedIn: String
        let appServerAlreadyStarting: String
        let processStopped: String
        let missingAccountResult: String
        let missingRateLimitResult: String
        let missingTokenUsageResult: String
        let missingWeeklyQuotaWindow: String
        let availableResetCredits: String
        let resetCreditNeverExpires: String
        let resetCreditDetailsUnavailable: String
        let noAvailableResetCredits: String
        let todayTokenUsage: String
        let yesterdayTokenUsage: String
        let totalTokenUsage: String
        let averageWeeklyTokenUsage: String
        let tokenUsageChartTitle: String
        let tokenUsageUnavailable: String
        let codexCLIUpgradeAlertTitle: String
        let appUpdateAvailableTitle: String

        func signedInAs(_ planType: String) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "已登录：\(planType)"
            case .english:
                return "Signed in as \(planType)"
            }
        }

        var accountInfoUnavailable: String {
            switch I18n.language {
            case .simplifiedChinese:
                return "账号信息暂不可用"
            case .english:
                return "Account info unavailable"
            }
        }

        func quotaLoadedWithAccountWarning(_ message: String) -> String {
            "\(quotaLoaded) \(accountInfoUnavailable): \(message)"
        }

        func appServerStartFailed(_ message: String) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "启动 codex app-server 失败：\(message)"
            case .english:
                return "Failed to start codex app-server: \(message)"
            }
        }

        func initializationFailed(_ message: String) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "JSON-RPC 初始化失败：\(message)"
            case .english:
                return "JSON-RPC initialization failed: \(message)"
            }
        }

        func unsupportedAuthMode(_ mode: String?) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "当前登录方式不支持 ChatGPT 额度\(mode.map { "：\($0)" } ?? "。")"
            case .english:
                return "Current auth mode does not support ChatGPT rate limits\(mode.map { ": \($0)" } ?? ".")"
            }
        }

        func unsupportedCodexCLIVersion(current: String, required: String) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "当前 Codex CLI 版本 \(current) 低于 \(required)，请升级 @openai/codex。"
            case .english:
                return "Current Codex CLI version \(current) is lower than \(required). Upgrade @openai/codex."
            }
        }

        func codexCLIUpgradeInlineMessage(current: String, required: String) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "当前版本 \(current) 低于 \(required)，请升级 CLI"
            case .english:
                return "Version \(current) is below \(required). Upgrade the CLI."
            }
        }

        func codexCLIUpgradeAlertMessage(current: String, required: String) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "当前 @openai/codex CLI 版本为 \(current)，低于最低要求 \(required)。请升级到 \(required) 或更高版本后重新启动 AgentBar。"
            case .english:
                return "Your @openai/codex CLI version is \(current), below the required \(required). Upgrade to \(required) or later, then restart AgentBar."
            }
        }

        func appUpdateAvailableMessage(version: String) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "发现 AgentBar \(version)，点击查看并更新。"
            case .english:
                return "AgentBar \(version) is available. Click to review and update."
            }
        }

        func parsingFailed(_ message: String) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "解析额度信息失败：\(message)"
            case .english:
                return "Failed to parse rate limits: \(message)"
            }
        }

        func appServerExited(status: Int32) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "进程已退出，状态码 \(status)。"
            case .english:
                return "Process exited with status \(status)."
            }
        }

        func appServerInitializationTimedOut(seconds: Int) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "等待 app-server 初始化超过 \(seconds) 秒。"
            case .english:
                return "Timed out waiting \(seconds) seconds for app-server initialization."
            }
        }

        func rpcRequestTimedOut(method: String, seconds: Int) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "RPC 请求 \(method) 在 \(seconds) 秒内未响应。"
            case .english:
                return "RPC request \(method) did not respond within \(seconds) seconds."
            }
        }

        func rpcResponseExceededLimit(megabytes: Int) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "app-server 返回了超过 \(megabytes) MB 的未分帧响应。"
            case .english:
                return "app-server returned an unframed response larger than \(megabytes) MB."
            }
        }

        var tooManyRPCRequests: String {
            switch I18n.language {
            case .simplifiedChinese:
                return "等待响应的 RPC 请求过多。"
            case .english:
                return "Too many RPC requests are waiting for a response."
            }
        }

        func resetIn(days: Int, hours: String, minutes: String) -> String {
            if days > 0 {
                return "\(days)\(dayUnit)\(hours)\(hourUnit)\(minutes)\(minuteUnit)\(refreshAfterSuffix)"
            }

            return "\(hours)\(hourUnit)\(minutes)\(minuteUnit)\(refreshAfterSuffix)"
        }

        func refreshAt(_ dateText: String) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "\(dateText)\(refreshAtSuffix)"
            case .english:
                return "Refresh at \(dateText)"
            }
        }

        func resetCreditExpiresOn(_ dateText: String) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "\(dateText) 到期"
            case .english:
                return "Expires \(dateText)"
            }
        }

        func additionalResetCredits(_ count: Int) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "另有 \(count) 次重置"
            case .english:
                return "\(count) more reset\(count == 1 ? "" : "s")"
            }
        }

        func durationTitle(minutes: Int) -> String {
            switch minutes {
            case 10080:
                return recentWeek
            case ..<1440:
                let hours = max(1, minutes / 60)
                switch I18n.language {
                case .simplifiedChinese:
                    return "\(hours) 小时\(windowSuffix)"
                case .english:
                    return "\(hours)h \(windowSuffix)"
                }
            default:
                let days = max(1, minutes / 1440)
                switch I18n.language {
                case .simplifiedChinese:
                    return "\(days) 天\(windowSuffix)"
                case .english:
                    return "\(days)d \(windowSuffix)"
                }
            }
        }

        func tokenUsageTooltip(dateText: String, tokenText: String) -> String {
            switch I18n.language {
            case .simplifiedChinese:
                return "\(dateText)使用了 \(tokenText) 个 Token"
            case .english:
                return "\(dateText) used \(tokenText) tokens"
            }
        }
    }

    static var current: Strings {
        switch language {
        case .simplifiedChinese:
            return simplifiedChinese
        case .english:
            return english
        }
    }

    static var language: Language {
        let preferredLanguage = Locale.preferredLanguages.first ?? Locale.current.identifier
        let normalized = preferredLanguage
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        if normalized == "zh" || normalized.hasPrefix("zh-") {
            return .simplifiedChinese
        }

        return .english
    }

    private static let english = Strings(
        codexQuota: "Codex quota",
        loadingQuota: "Loading Codex quota...",
        refreshingQuota: "Refreshing Codex quota...",
        quotaLoaded: "Codex quota loaded.",
        loading: "loading...",
        notRefreshed: "Not refreshed",
        lastRefreshPrefix: "Last refresh",
        refreshNow: "Refresh now",
        aboutUs: "About us",
        quit: "Quit",
        checkForUpdates: "Check for updates",
        checkingForUpdates: "Checking...",
        updateCheckUpToDate: "Up to date",
        updateCheckFailed: "Check failed",
        updateAvailable: "Update",
        downloadingUpdate: "Downloading...",
        updateDownloaded: "Downloaded",
        installUpdate: "Install update",
        recentWeek: "Past 1 week",
        shortWeek: "Weekly",
        resetTimeUnavailable: "Reset time unavailable",
        resetSoon: "Reset soon",
        refreshAtSuffix: " refresh",
        dayUnit: "d ",
        hourUnit: "h ",
        minuteUnit: "m",
        refreshAfterSuffix: " until refresh",
        dateLocaleIdentifier: "en_US",
        dateFormat: "yyyy-MM-dd HH:mm",
        quotaFallbackTitle: "Quota",
        windowSuffix: "window",
        codexCLINotFound: "Cannot find codex CLI. Install Codex or add it to PATH.",
        notSignedIn: "Not signed in. Run Codex login first.",
        appServerAlreadyStarting: "app-server is already starting.",
        processStopped: "Process stopped.",
        missingAccountResult: "Missing account result.",
        missingRateLimitResult: "Missing rate limit result.",
        missingTokenUsageResult: "Missing token usage result.",
        missingWeeklyQuotaWindow: "The weekly quota window was not returned.",
        availableResetCredits: "Available resets:",
        resetCreditNeverExpires: "Does not expire",
        resetCreditDetailsUnavailable: "Details unavailable",
        noAvailableResetCredits: "No reset credits available",
        todayTokenUsage: "Today tokens",
        yesterdayTokenUsage: "Yesterday tokens",
        totalTokenUsage: "Total tokens",
        averageWeeklyTokenUsage: "Weekly avg tokens",
        tokenUsageChartTitle: "Past 30 days",
        tokenUsageUnavailable: "Token usage unavailable",
        codexCLIUpgradeAlertTitle: "Codex CLI update required",
        appUpdateAvailableTitle: "AgentBar update available"
    )

    private static let simplifiedChinese = Strings(
        codexQuota: "Codex 额度",
        loadingQuota: "正在加载 Codex 额度...",
        refreshingQuota: "正在刷新 Codex 额度...",
        quotaLoaded: "Codex 额度已加载。",
        loading: "加载中...",
        notRefreshed: "尚未刷新",
        lastRefreshPrefix: "上次刷新",
        refreshNow: "立即刷新",
        aboutUs: "关于我们",
        quit: "退出",
        checkForUpdates: "检查更新",
        checkingForUpdates: "正在检查…",
        updateCheckUpToDate: "已是最新版本",
        updateCheckFailed: "检查失败",
        updateAvailable: "可更新",
        downloadingUpdate: "正在下载…",
        updateDownloaded: "已下载",
        installUpdate: "安装更新",
        recentWeek: "近 1 周",
        shortWeek: "周剩",
        resetTimeUnavailable: "刷新时间不可用",
        resetSoon: "即将刷新",
        refreshAtSuffix: "刷新",
        dayUnit: "天",
        hourUnit: "时",
        minuteUnit: "分钟",
        refreshAfterSuffix: "后刷新",
        dateLocaleIdentifier: "zh_CN",
        dateFormat: "yyyy-MM-dd HH:mm",
        quotaFallbackTitle: "额度",
        windowSuffix: "窗口",
        codexCLINotFound: "找不到 codex CLI。请安装 Codex，或将其加入 PATH。",
        notSignedIn: "尚未登录。请先运行 Codex login。",
        appServerAlreadyStarting: "app-server 已在启动中。",
        processStopped: "进程已停止。",
        missingAccountResult: "缺少账户结果。",
        missingRateLimitResult: "缺少额度结果。",
        missingTokenUsageResult: "缺少 token 消耗结果。",
        missingWeeklyQuotaWindow: "未返回周额度窗口。",
        availableResetCredits: "可用重置次数：",
        resetCreditNeverExpires: "不会到期",
        resetCreditDetailsUnavailable: "暂无重置详情",
        noAvailableResetCredits: "暂无可用重置次数",
        todayTokenUsage: "今日 Token 数",
        yesterdayTokenUsage: "昨日 Token 数",
        totalTokenUsage: "累计 Token 数",
        averageWeeklyTokenUsage: "周均 Token 数",
        tokenUsageChartTitle: "近 30 天",
        tokenUsageUnavailable: "Token 消耗不可用",
        codexCLIUpgradeAlertTitle: "需要升级 Codex CLI",
        appUpdateAvailableTitle: "AgentBar 有新版本"
    )
}
