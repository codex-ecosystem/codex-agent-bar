import Combine
import Foundation

@MainActor
final class QuotaStore: ObservableObject {
    enum SuspensionReason: Hashable {
        case systemSleep
        case memoryPressure
    }

    @Published var snapshot: QuotaSnapshot?
    @Published var tokenUsageSnapshot: TokenUsageSnapshot?
    @Published var tokenUsageErrorMessage: String?
    @Published var statusMessage = I18n.current.loadingQuota
    @Published var isLoading = false
    @Published var cliUpgradeMessage: String?
    @Published var cliUpgradeAlertMessage: String?
    @Published private(set) var currentAccount: CodexAccount?
    @Published private(set) var accountErrorMessage: String?

    private let client: CodexAppServerClient
    private let accountService = CodexAccountService()
    private let rateLimitService = CodexRateLimitService()
    private let tokenUsageService = CodexTokenUsageService()
    private var refreshTimer: Timer?
    private var hasStarted = false
    private var hasValidatedCLIVersion = false
    private var suspensionReasons = Set<SuspensionReason>()
    private var lifecycleID = UUID()
    private var needsAccountRefresh = false

    var displaysFiveHourQuota: Bool {
        let planType = snapshot?.planType ?? currentAccount?.planType
        if planType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pro" {
            return false
        }

        return currentAccount != nil || snapshot?.fiveHour != nil
    }

    init(client: CodexAppServerClient = CodexAppServerClient()) {
        self.client = client
        client.notificationHandler = { [weak self] method, _ in
            switch method {
            case "account/updated":
                self?.refreshAccountAndRateLimitsIfIdle()
            case "account/rateLimits/updated":
                self?.refreshRateLimitsOnlyIfIdle()
            default:
                return
            }
        }
    }

    func start() {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        beginRefreshing()
    }

    private func beginRefreshing() {
        guard hasStarted, suspensionReasons.isEmpty else {
            return
        }

        if hasValidatedCLIVersion {
            installRefreshTimer()
            refreshAccountAndRateLimits()
            return
        }

        isLoading = true
        statusMessage = I18n.current.loadingQuota
        checkCodexCLIVersionThenStart()
    }

    private func checkCodexCLIVersionThenStart() {
        let lifecycleID = self.lifecycleID
        client.checkMinimumResetCreditsVersion { [weak self] result in
            Task { @MainActor in
                guard let self, self.acceptsCallback(lifecycleID) else {
                    return
                }

                switch result {
                case .success:
                    self.hasValidatedCLIVersion = true
                    self.cliUpgradeMessage = nil
                    self.cliUpgradeAlertMessage = nil
                    self.refreshAccountAndRateLimits()
                    self.installRefreshTimer()
                case .failure(let error):
                    self.apply(error: error)
                }
            }
        }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        hasStarted = false
        invalidateRefresh(completion: completion)
    }

    func suspend(for reason: SuspensionReason) {
        guard suspensionReasons.insert(reason).inserted else {
            return
        }

        invalidateRefresh()
    }

    func resume(after reason: SuspensionReason) {
        guard suspensionReasons.remove(reason) != nil, suspensionReasons.isEmpty else {
            return
        }

        beginRefreshing()
    }

    func releaseIdleResources() {
        if !isLoading {
            client.stop()
        }
    }

    private func invalidateRefresh(completion: (@Sendable () -> Void)? = nil) {
        lifecycleID = UUID()
        needsAccountRefresh = false
        isLoading = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        client.stop(completion: completion)
    }

    private func installRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRateLimitsOnlyIfIdle()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func acceptsCallback(_ lifecycleID: UUID) -> Bool {
        hasStarted && suspensionReasons.isEmpty && self.lifecycleID == lifecycleID
    }

    func refresh() {
        guard hasStarted, suspensionReasons.isEmpty, !isLoading, hasValidatedCLIVersion else {
            return
        }

        refreshAccountAndRateLimits()
    }

    private func refreshAccountAndRateLimits() {
        let lifecycleID = self.lifecycleID
        isLoading = true
        cliUpgradeMessage = nil
        statusMessage = snapshot == nil ? I18n.current.loadingQuota : I18n.current.refreshingQuota

        client.start { [weak self] result in
            Task { @MainActor in
                guard let self, self.acceptsCallback(lifecycleID) else {
                    return
                }

                switch result {
                case .success:
                    self.readAccountAndRateLimits(lifecycleID: lifecycleID)
                case .failure(let error):
                    self.apply(error: error)
                }
            }
        }
    }

    private func refreshAccountAndRateLimitsIfIdle() {
        guard hasStarted, suspensionReasons.isEmpty, hasValidatedCLIVersion else {
            return
        }

        guard !isLoading else {
            needsAccountRefresh = true
            return
        }

        refreshAccountAndRateLimits()
    }

    private func readAccountAndRateLimits(lifecycleID: UUID) {
        accountService.readAccount(client: client) { [weak self] result in
            Task { @MainActor in
                guard let self, self.acceptsCallback(lifecycleID) else {
                    return
                }

                switch result {
                case .success(let account):
                    self.accountErrorMessage = nil
                    self.validate(account: account, lifecycleID: lifecycleID)
                case .failure(let error):
                    if case QuotaError.rpcError("workspace routing discovery timed out") = error {
                        // This server-side lookup can fail while the independent quota endpoint still works.
                        self.clearAccountData()
                        self.accountErrorMessage = error.localizedDescription
                        self.readRateLimits(account: nil, lifecycleID: lifecycleID)
                    } else {
                        self.apply(error: error)
                    }
                }
            }
        }
    }

    private func validate(account: CodexAccount, lifecycleID: UUID) {
        guard account.type != nil else {
            clearAccountData()
            apply(error: QuotaError.notSignedIn)
            return
        }

        guard account.type == "chatgpt" else {
            clearAccountData()
            apply(error: QuotaError.unsupportedAuthMode(account.type))
            return
        }

        currentAccount = account
        readRateLimits(account: account, lifecycleID: lifecycleID)
    }

    private func clearAccountData() {
        currentAccount = nil
        accountErrorMessage = nil
        snapshot = nil
        tokenUsageSnapshot = nil
        tokenUsageErrorMessage = nil
    }

    private func refreshRateLimitsOnly() {
        let lifecycleID = self.lifecycleID
        guard currentAccount != nil || snapshot != nil else {
            refreshAccountAndRateLimits()
            return
        }

        isLoading = true
        cliUpgradeMessage = nil
        statusMessage = snapshot == nil ? I18n.current.loadingQuota : I18n.current.refreshingQuota

        client.start { [weak self] result in
            Task { @MainActor in
                guard let self, self.acceptsCallback(lifecycleID) else {
                    return
                }

                switch result {
                case .success:
                    self.readRateLimits(account: self.currentAccount, lifecycleID: lifecycleID)
                case .failure(let error):
                    self.apply(error: error)
                }
            }
        }
    }

    private func refreshRateLimitsOnlyIfIdle() {
        guard hasStarted, suspensionReasons.isEmpty, hasValidatedCLIVersion, !isLoading else {
            return
        }

        refreshRateLimitsOnly()
    }

    private func readRateLimits(account: CodexAccount?, lifecycleID: UUID) {
        rateLimitService.readRateLimits(client: client) { [weak self] result in
            Task { @MainActor in
                guard let self, self.acceptsCallback(lifecycleID) else {
                    return
                }

                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot.preservingResetCreditDetails(from: self.snapshot)
                    self.readTokenUsage(account: account, lifecycleID: lifecycleID)
                case .failure(let error):
                    self.apply(error: error)
                }
            }
        }
    }

    private func readTokenUsage(account: CodexAccount?, lifecycleID: UUID) {
        tokenUsageService.readTokenUsage(client: client) { [weak self] result in
            Task { @MainActor in
                guard let self, self.acceptsCallback(lifecycleID) else {
                    return
                }

                switch result {
                case .success(let snapshot):
                    self.tokenUsageSnapshot = snapshot
                    self.tokenUsageErrorMessage = nil
                case .failure(let error):
                    self.tokenUsageErrorMessage = error.localizedDescription
                    print("[AgentBar] Token usage refresh failed: \(error.localizedDescription)")
                }

                if let accountErrorMessage = self.accountErrorMessage {
                    self.statusMessage = I18n.current.quotaLoadedWithAccountWarning(accountErrorMessage)
                } else {
                    self.statusMessage = account?.planType.map { I18n.current.signedInAs($0) } ?? I18n.current.quotaLoaded
                }
                self.finishRefresh()
            }
        }
    }

    private func finishRefresh() {
        isLoading = false
        if needsAccountRefresh {
            needsAccountRefresh = false
            refreshAccountAndRateLimitsIfIdle()
        }
    }

    private func apply(error: Error) {
        if case QuotaError.unsupportedCodexCLIVersion(let current, let required) = error {
            statusMessage = I18n.current.loadingQuota
            cliUpgradeMessage = I18n.current.codexCLIUpgradeInlineMessage(current: current, required: required)
            cliUpgradeAlertMessage = I18n.current.codexCLIUpgradeAlertMessage(current: current, required: required)
            isLoading = false
            print("[AgentBar] Quota refresh failed: \(error.localizedDescription)")
            return
        }

        statusMessage = error.localizedDescription
        finishRefresh()
        print("[AgentBar] Quota refresh failed: \(error.localizedDescription)")
    }
}
