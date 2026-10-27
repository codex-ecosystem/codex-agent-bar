import AppKit
import Darwin
import Foundation
import Testing
@testable import AgentBar

@MainActor
@Suite(.serialized)
final class ResourceLifetimeTests {
    @MainActor
    private final class PopoverObservation {
        var popover: NSPopover?
    }

    private var fixtureDirectories: [URL] = []
    private var clients: [CodexAppServerClient] = []

    deinit {
        clients.forEach { $0.stop() }
        fixtureDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
    }
    private func makeClient(
        mode: String = "normal",
        executableName: String = "codex",
        configure: (inout CodexAppServerClient.Configuration) -> Void = { _ in }
    ) throws -> CodexAppServerClient {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try #require(Bundle.module.url(forResource: "mock-codex", withExtension: "py", subdirectory: "Fixtures"))
        let executable = directory.appendingPathComponent(executableName)
        try FileManager.default.copyItem(at: fixture, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        fixtureDirectories.append(directory)
        var configuration = CodexAppServerClient.Configuration()
        configuration.arguments = [mode]
        configuration.initializationTimeout = 2
        configuration.requestTimeout = 2
        configuration.terminationGracePeriod = 0.1
        configure(&configuration)
        let client = CodexAppServerClient(configuration: configuration, resolveCLI: {
            CodexCLIResolver.ResolvedCLI(path: executable.path, environment: ProcessInfo.processInfo.environment)
        })
        clients.append(client)
        return client
    }

    private func start(_ client: CodexAppServerClient) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.start { continuation.resume(with: $0) }
        }
    }

    private func request(_ method: String, client: CodexAppServerClient) async throws -> CodexAppServerClient.JSONDictionary {
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UncheckedSendable<CodexAppServerClient.JSONDictionary>, Error>) in
            client.sendRequest(method: method) { result in
                continuation.resume(with: result.map(UncheckedSendable.init))
            }
        }
        return response.value
    }

    private func pid(_ client: CodexAppServerClient, method: String = "ping") async throws -> Int32 {
        let response = try await request(method, client: client)
        let result = try #require(response["result"] as? [String: Any])
        return Int32(try #require(result["pid"] as? Int))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Condition did not become true within 3 seconds")
    }

    private func physicalFootprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        try #require(status == KERN_SUCCESS)
        return info.phys_footprint
    }

    @Test func workspaceRoutingTimeoutStillLoadsQuota() async throws {
        let client = try makeClient(mode: "workspace-timeout")
        let store = QuotaStore(client: client)
        defer { store.stop() }
        store.start()
        try await waitUntil { store.snapshot != nil && !store.isLoading }
        #expect(store.currentAccount == nil)
        #expect(store.accountErrorMessage == "workspace routing discovery timed out")
        #expect(store.snapshot?.fiveHour?.remainingPercent == 85)
        #expect(store.snapshot?.weekly.remainingPercent == 88)
        #expect(store.snapshot?.planType == "plus")
        #expect(store.displaysFiveHourQuota)
        #expect(store.tokenUsageSnapshot?.totalTokens == 100)
        #expect(store.statusMessage.contains("workspace routing discovery timed out"))
    }

    @Test func workspaceRoutingFallbackKeepsRefreshingWithoutAccountDiscovery() async throws {
        let client = try makeClient(mode: "workspace-timeout")
        let store = QuotaStore(client: client)
        defer { store.stop() }
        store.start()
        try await waitUntil { store.snapshot != nil && !store.isLoading }
        let lastUpdated = store.snapshot?.lastUpdated
        _ = try await request("notify-rate-limits", client: client)
        try await waitUntil { store.snapshot?.lastUpdated != lastUpdated && !store.isLoading }
        let response = try await request("request-counts", client: client)
        let counts = try #require(response["result"] as? [String: Int])
        #expect(counts["account/read"] == 1)
        #expect(counts["account/rateLimits/read"] == 2)
        #expect(store.accountErrorMessage != nil)
    }

    @Test func workspaceRoutingRecoveryRestoresAccountDetails() async throws {
        let client = try makeClient(mode: "workspace-timeout-recovery")
        let store = QuotaStore(client: client)
        defer { store.stop() }
        store.start()
        try await waitUntil { store.snapshot != nil && !store.isLoading }
        #expect(store.accountErrorMessage != nil)
        store.refresh()
        try await waitUntil { store.currentAccount != nil && !store.isLoading }
        #expect(store.accountErrorMessage == nil)
        #expect(store.currentAccount?.email == "test@example.com")
        #expect(store.statusMessage == I18n.current.signedInAs("plus"))
    }

    @Test func workspaceRoutingFallbackKeepsProLayout() async throws {
        let client = try makeClient(mode: "workspace-timeout-pro")
        let store = QuotaStore(client: client)
        defer { store.stop() }
        store.start()
        try await waitUntil { store.snapshot != nil && !store.isLoading }
        #expect(store.snapshot?.planType == "pro")
        #expect(!store.displaysFiveHourQuota)
    }

    @Test func workspaceRoutingFallbackPreservesQuotaEndpointFailure() async throws {
        let client = try makeClient(mode: "workspace-timeout-quota-error")
        let store = QuotaStore(client: client)
        defer { store.stop() }
        store.start()
        try await waitUntil { !store.isLoading }
        #expect(store.snapshot == nil)
        #expect(store.accountErrorMessage == "workspace routing discovery timed out")
        #expect(store.statusMessage == "Quota endpoint unavailable")
    }

    @Test func otherAccountErrorsDoNotAttemptQuotaRead() async throws {
        let client = try makeClient(mode: "account-error")
        let store = QuotaStore(client: client)
        defer { store.stop() }
        store.start()
        try await waitUntil { !store.isLoading }
        #expect(store.snapshot == nil)
        #expect(store.accountErrorMessage == nil)
        #expect(store.statusMessage == "Unauthorized")
        let response = try await request("request-counts", client: client)
        let counts = try #require(response["result"] as? [String: Int])
        #expect(counts["account/rateLimits/read"] == nil)
    }

    @Test func signedOutAccountDoesNotAttemptQuotaRead() async throws {
        let client = try makeClient(mode: "not-signed-in")
        let store = QuotaStore(client: client)
        defer { store.stop() }
        store.start()
        try await waitUntil { !store.isLoading }
        #expect(store.statusMessage == I18n.current.notSignedIn)
        #expect(store.accountErrorMessage == nil)
        let response = try await request("request-counts", client: client)
        let counts = try #require(response["result"] as? [String: Int])
        #expect(counts["account/rateLimits/read"] == nil)
    }

    @Test func logoutAfterWorkspaceRoutingFallbackClearsQuota() async throws {
        let client = try makeClient(mode: "workspace-timeout")
        let store = QuotaStore(client: client)
        defer { store.stop() }
        store.start()
        try await waitUntil { store.snapshot != nil && !store.isLoading }
        _ = try await request("notify-logout", client: client)
        try await waitUntil { store.snapshot == nil && !store.isLoading }
        #expect(store.currentAccount == nil)
        #expect(store.accountErrorMessage == nil)
        #expect(store.tokenUsageSnapshot == nil)
        #expect(store.statusMessage == I18n.current.notSignedIn)
    }

    @Test func versionProbeCannotBlockTheRPCQueueIndefinitely() async throws {
        let client = try makeClient(executableName: "version-hang") { $0.versionTimeout = 0.1 }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<CodexCLIVersion, Error>, Never>) in
            client.checkMinimumResetCreditsVersion { continuation.resume(returning: $0) }
        }
        if case .success = result {
            Issue.record("A hung --version probe must time out")
        }
        try await start(client)
        let childPID = try await pid(client)
        #expect(childPID > 0)
    }

    @Test func pendingRequestLimitRejectsExcessWork() async throws {
        let client = try makeClient {
            $0.maximumPendingRequests = 2
            $0.requestTimeout = 0.2
        }
        try await start(client)
        let errors = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        client.sendRequest(method: "ignore") { result in
                            switch result {
                            case .success: continuation.resume(returning: "unexpected success")
                            case .failure(let error): continuation.resume(returning: error.localizedDescription)
                            }
                        }
                    }
                }
            }
            var messages: [String] = []
            for await message in group { messages.append(message) }
            return messages
        }
        #expect(errors.filter { $0 == I18n.current.tooManyRPCRequests }.count == 18)
        try await start(client)
        let childPID = try await pid(client)
        #expect(childPID > 0)
    }

    @Test func repeatedLargeResponsesHaveBoundedMemoryGrowth() async throws {
        let client = try makeClient()
        try await start(client)
        for _ in 0..<100 {
            _ = try await request("large", client: client)
        }
        let before = try physicalFootprint()
        for _ in 0..<1000 {
            _ = try await request("large", client: client)
        }
        let after = try physicalFootprint()
        print("[Memory regression] physical footprint: \(before) -> \(after) bytes after 1000 x 32 KiB responses")
        #expect(after <= before + 16 * 1024 * 1024)
    }

    @Test func stopCompletionSignalsOnlyAfterCleanup() async throws {
        let client = try makeClient(mode: "stubborn")
        try await start(client)
        let childPID = try await pid(client, method: "linger")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            client.stop { continuation.resume() }
        }
        try await waitUntil { Darwin.kill(childPID, 0) != 0 }
    }

    @Test func closingPopoverReleasesHostingControllerAndReopens() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSButton(frame: NSRect(x: 40, y: 20, width: 80, height: 30))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        let observation = PopoverObservation()
        let observer = NotificationCenter.default.addObserver(forName: NSPopover.didShowNotification, object: nil, queue: .main) { notification in
            let notification = UncheckedSendable(notification)
            MainActor.assumeIsolated {
                observation.popover = notification.value.object as? NSPopover
            }
        }
        let delegate = AppDelegate()
        let toggle = NSSelectorFromString("togglePopover:")
        defer {
            observation.popover?.performClose(nil)
            NotificationCenter.default.removeObserver(observer)
            window.close()
        }

        delegate.perform(toggle, with: anchor)
        try await waitUntil { observation.popover?.isShown == true }
        let firstPopover = try #require(observation.popover)
        weak var firstController = firstPopover.contentViewController
        #expect(firstController != nil)
        delegate.perform(toggle, with: anchor)
        try await waitUntil { !firstPopover.isShown && firstPopover.contentViewController == nil }
        try await waitUntil { firstController == nil }

        observation.popover = nil
        delegate.perform(toggle, with: anchor)
        try await waitUntil { observation.popover?.isShown == true }
        #expect(observation.popover !== firstPopover)
        #expect(observation.popover?.contentViewController != nil)
    }

    @Test func timeoutClearsRequestAndAllowsReconnect() async throws {
        let client = try makeClient { $0.requestTimeout = 0.1 }
        try await start(client)
        do {
            _ = try await request("ignore", client: client)
            Issue.record("A missing RPC response must time out")
        } catch {
            #expect(error.localizedDescription.contains("ignore"))
        }
        try await start(client)
        let childPID = try await pid(client)
        #expect(childPID > 0)
    }

    @Test func oversizedUnframedOutputIsDiscardedAndReconnects() async throws {
        let client = try makeClient { $0.maximumOutputBytes = 1024 }
        try await start(client)
        do {
            _ = try await request("oversized", client: client)
            Issue.record("An oversized line must fail, rather than accumulating indefinitely")
        } catch {
            #expect(error.localizedDescription.contains("MB"))
        }
        try await start(client)
        let childPID = try await pid(client)
        #expect(childPID > 0)
    }

    @Test func repeatedRestartDoesNotAccumulateFileDescriptors() async throws {
        let baseline = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        let client = try makeClient()
        var children = Set<Int32>()
        for _ in 0..<30 {
            try await start(client)
            children.insert(try await pid(client))
            client.stop()
        }
        try await waitUntil { children.allSatisfy { Darwin.kill($0, 0) != 0 } }
        try await Task.sleep(for: .milliseconds(50))
        let final = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        #expect(final <= baseline + 4)
        #expect(children.count == 30)
    }

    @Test func recycleIgnoresOldProcessTermination() async throws {
        let client = try makeClient { $0.maximumProcessLifetime = 0.1 }
        try await start(client)
        let firstPID = try await pid(client)
        try await Task.sleep(for: .milliseconds(120))
        try await start(client)
        let secondPID = try await pid(client)
        #expect(firstPID != secondPID)
        try await Task.sleep(for: .milliseconds(150))
        let survivingPID = try await pid(client)
        #expect(survivingPID == secondPID)
    }

    @Test func childIgnoringTerminationIsReaped() async throws {
        let client = try makeClient(mode: "stubborn")
        try await start(client)
        let childPID = try await pid(client, method: "linger")
        client.stop()
        try await waitUntil { Darwin.kill(childPID, 0) != 0 }
    }

    @Test func notificationFloodDoesNotReachUI() async throws {
        let client = try makeClient()
        var notificationCount = 0
        client.notificationHandler = { _, _ in notificationCount += 1 }
        try await start(client)
        _ = try await request("flood", client: client)
        #expect(notificationCount == 0)
        for _ in 0..<1000 {
            _ = try await request("ping", client: client)
        }
    }

    @Test func sleepAndMemoryPressureResumeOnlyAfterBothClear() async throws {
        let client = try makeClient()
        let store = QuotaStore(client: client)
        store.start()
        try await waitUntil { store.snapshot != nil && !store.isLoading }
        let lastUpdated = try #require(store.snapshot?.lastUpdated)
        store.suspend(for: .systemSleep)
        store.suspend(for: .memoryPressure)
        store.resume(after: .systemSleep)
        store.refresh()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!store.isLoading)
        #expect(store.snapshot?.lastUpdated == lastUpdated)
        store.resume(after: .memoryPressure)
        try await waitUntil { !store.isLoading && store.snapshot?.lastUpdated != lastUpdated }
        store.stop()
    }

    @Test func stopDiscardsLateCallbacksAndCanStartAgain() async throws {
        let client = try makeClient(mode: "slow-start")
        let store = QuotaStore(client: client)
        store.start()
        try await Task.sleep(for: .milliseconds(60))
        store.stop()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!store.isLoading)
        #expect(store.currentAccount == nil)
        #expect(store.snapshot == nil)
        store.start()
        try await waitUntil { store.snapshot != nil && !store.isLoading }
        store.stop()
    }

    @Test func sleepDuringUsageReadDoesNotApplyCancelledResult() async throws {
        let client = try makeClient(mode: "slow-usage")
        let store = QuotaStore(client: client)
        store.start()
        try await waitUntil { store.snapshot != nil && store.isLoading }
        store.suspend(for: .systemSleep)
        try await Task.sleep(for: .milliseconds(250))
        #expect(store.tokenUsageSnapshot == nil)
        #expect(store.tokenUsageErrorMessage == nil)
        #expect(!store.isLoading)
        store.resume(after: .systemSleep)
        try await waitUntil { store.tokenUsageSnapshot != nil && !store.isLoading }
        store.stop()
    }
}
