import Darwin
import Foundation
import OSLog

final class CodexAppServerClient {
    typealias JSONDictionary = [String: Any]
    typealias Completion = @Sendable (Result<JSONDictionary, Error>) -> Void

    struct Configuration: Sendable {
        var initializationTimeout: TimeInterval = 10
        var versionTimeout: TimeInterval = 10
        var requestTimeout: TimeInterval = 30
        var maximumOutputBytes = 4 * 1_024 * 1_024
        var maximumPendingRequests = 8
        var maximumProcessLifetime: TimeInterval = 60 * 60
        var terminationGracePeriod: TimeInterval = 2
        var arguments = ["app-server"]
    }

    private struct PendingRequest {
        let completion: Completion
        let timeoutWorkItem: DispatchWorkItem?
    }

    static let minimumResetCreditsVersion = CodexCLIVersion(major: 0, minor: 142, patch: 3)

    private static let maximumStderrBytes = 8_192
    private static let readChunkBytes = 64 * 1_024

    var notificationHandler: ((String, JSONDictionary?) -> Void)?

    private let queue = DispatchQueue(label: "AgentBar.rpc", autoreleaseFrequency: .workItem)
    private let logger = Logger(subsystem: "com.lonewolfyx.AgentBar", category: "RPC")
    private let configuration: Configuration
    private let resolveCLI: @Sendable () -> CodexCLIResolver.ResolvedCLI?
    private let notificationLock = NSLock()
    private var queuedNotifications: [String: JSONDictionary] = [:]
    private var notificationDeliveryScheduled = false
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var connectionID: UUID?
    private var outputBuffer = Data()
    private var stderrBuffer = Data()
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var initialized = false
    private var processStartedAt: Date?
    private var selectedCodexCLI: CodexCLIResolver.ResolvedCLI?
    private var selectedCodexVersion: CodexCLIVersion?
    private var initializationTimeoutWorkItem: DispatchWorkItem?

    init(
        configuration: Configuration = Configuration(),
        resolveCLI: @escaping @Sendable () -> CodexCLIResolver.ResolvedCLI? = { CodexCLIResolver.resolveForLaunch() }
    ) {
        self.configuration = configuration
        self.resolveCLI = resolveCLI
    }

    deinit {
        stopLocked()
    }

    func start(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            if self.initialized {
                if self.shouldRecycleProcessLocked {
                    self.log("Recycling long-running codex app-server")
                    self.stopLocked()
                } else {
                    completion(.success(()))
                    return
                }
            }

            guard self.process == nil else {
                completion(.failure(QuotaError.initializationFailed(I18n.current.appServerAlreadyStarting)))
                return
            }

            do {
                try self.launchProcess()
                self.sendRequestLocked(
                    method: "initialize",
                    id: 0,
                    params: [
                        "clientInfo": [
                            "name": "codex_agent_bar",
                            "title": "Codex Agent Bar",
                            "version": AppVersion.shortVersion,
                        ],
                    ]
                ) { result in
                    switch result {
                    case .success:
                        guard self.sendNotificationLocked(method: "initialized", params: [:]) else {
                            completion(.failure(QuotaError.initializationFailed(I18n.current.processStopped)))
                            return
                        }
                        self.initialized = true
                        self.log("RPC initialized")
                        completion(.success(()))
                    case .failure(let error):
                        self.stop()
                        completion(.failure(QuotaError.initializationFailed(error.localizedDescription)))
                    }
                }
                self.scheduleInitializationTimeoutLocked()
            } catch {
                self.stopLocked()
                completion(.failure(error))
            }
        }
    }

    func sendRequest(method: String, params: JSONDictionary? = nil, completion: @escaping Completion) {
        let sendableParams = UncheckedSendable(params)

        queue.async {
            guard self.initialized, self.process?.isRunning == true else {
                completion(.failure(QuotaError.rpcError(I18n.current.processStopped)))
                return
            }

            guard self.pending.count < self.configuration.maximumPendingRequests else {
                completion(.failure(QuotaError.rpcError(I18n.current.tooManyRPCRequests)))
                return
            }

            let id = self.nextRequestID
            self.nextRequestID += 1
            self.sendRequestLocked(
                method: method,
                id: id,
                params: sendableParams.value,
                timeoutSeconds: self.configuration.requestTimeout,
                completion: completion
            )
        }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            let oldProcess = self.process
            self.stopLocked()
            if let completion {
                if let oldProcess, oldProcess.isRunning {
                    self.queue.asyncAfter(deadline: .now() + self.configuration.terminationGracePeriod) {
                        if oldProcess.isRunning {
                            Darwin.kill(oldProcess.processIdentifier, SIGKILL)
                        }
                        completion()
                    }
                } else {
                    completion()
                }
            }
        }
    }

    func checkMinimumResetCreditsVersion(completion: @escaping @Sendable (Result<CodexCLIVersion, Error>) -> Void) {
        queue.async {
            self.selectedCodexCLI = nil
            self.selectedCodexVersion = nil
            guard let cli = self.resolveCLI() else {
                completion(.failure(QuotaError.codexCLINotFound))
                return
            }

            do {
                let version = try Self.readCodexCLIVersion(cli: cli, timeout: self.configuration.versionTimeout)
                guard version >= Self.minimumResetCreditsVersion else {
                    completion(.failure(QuotaError.unsupportedCodexCLIVersion(
                        current: version.displayText,
                        required: Self.minimumResetCreditsVersion.displayText
                    )))
                    return
                }

                self.selectedCodexCLI = cli
                self.selectedCodexVersion = version
                self.log("Selected Codex CLI \(cli.path) (\(version.displayText))")
                completion(.success(version))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func launchProcess() throws {
        guard let cli = selectedCodexCLI ?? resolveCLI() else {
            throw QuotaError.codexCLINotFound
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: cli.path)
        process.arguments = configuration.arguments
        process.environment = Self.makeProcessEnvironment(cli: cli)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        clearStderrBuffer()

        let connectionID = UUID()
        process.terminationHandler = { [weak self] process in
            self?.queue.async { [weak self] in
                guard let self, self.connectionID == connectionID else {
                    return
                }

                self.log("app-server exited with status \(process.terminationStatus)")
                let message = self.appServerDiagnosticMessageLocked(
                    summary: I18n.current.appServerExited(status: process.terminationStatus)
                )
                self.stopLocked(error: QuotaError.appServerStartFailed(message))
            }
        }

        try process.run()

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.connectionID = connectionID
        outputSource = try makeReadSource(handle: outputPipe.fileHandleForReading, connectionID: connectionID, isStderr: false)
        errorSource = try makeReadSource(handle: errorPipe.fileHandleForReading, connectionID: connectionID, isStderr: true)
        processStartedAt = Date()
        let version = selectedCodexVersion.map { " (\($0.displayText))" } ?? ""
        log("Started codex app-server at \(cli.path)\(version)")
    }

    private func makeReadSource(handle: FileHandle, connectionID: UUID, isStderr: Bool) throws -> DispatchSourceRead {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw QuotaError.appServerStartFailed(String(cString: strerror(errno)))
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, self.connectionID == connectionID else {
                return
            }

            // Read on the parser queue: a noisy child cannot enqueue an unbounded backlog of Data.
            autoreleasepool {
                var bytes = [UInt8](repeating: 0, count: Self.readChunkBytes)
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 {
                    let data = Data(bytes.prefix(count))
                    if isStderr {
                        self.appendStderr(data)
                    } else {
                        self.consumeOutput(data)
                    }
                } else if count == 0 {
                    if isStderr {
                        self.errorSource?.cancel()
                    } else {
                        self.outputSource?.cancel()
                    }
                } else if errno != EAGAIN && errno != EINTR {
                    self.stopLocked(error: QuotaError.rpcError(String(cString: strerror(errno))))
                }
            }
        }
        // A descriptor must remain open until its dispatch source has stopped accessing it.
        source.setCancelHandler {
            try? handle.close()
        }
        source.resume()
        return source
    }

    private func scheduleInitializationTimeoutLocked() {
        cancelInitializationTimeoutLocked()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.initialized, self.pending[0] != nil else {
                return
            }

            self.initializationTimeoutWorkItem = nil
            let message = self.appServerDiagnosticMessageLocked(
                summary: I18n.current.appServerInitializationTimedOut(
                    seconds: Int(self.configuration.initializationTimeout.rounded(.up))
                )
            )
            self.stopLocked(error: QuotaError.appServerStartFailed(message))
        }

        initializationTimeoutWorkItem = workItem
        queue.asyncAfter(
            deadline: .now() + configuration.initializationTimeout,
            execute: workItem
        )
    }

    private func cancelInitializationTimeoutLocked() {
        initializationTimeoutWorkItem?.cancel()
        initializationTimeoutWorkItem = nil
    }

    private func appendStderr(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        let remainingCapacity = Self.maximumStderrBytes - stderrBuffer.count
        guard remainingCapacity > 0 else {
            return
        }

        stderrBuffer.append(data.prefix(remainingCapacity))
    }

    private func clearStderrBuffer() {
        stderrBuffer = Data()
    }

    private func capturedStderr() -> String {
        let data = stderrBuffer

        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appServerDiagnosticMessageLocked(summary: String) -> String {
        var lines = [summary]

        if let selectedCodexCLI {
            let version = selectedCodexVersion.map { " (\($0.displayText))" } ?? ""
            lines.append("Codex CLI: \(selectedCodexCLI.path)\(version)")
        }

        let stderr = capturedStderr()
        if !stderr.isEmpty {
            lines.append(stderr)
        }

        return lines.joined(separator: "\n")
    }

    private static func makeProcessEnvironment(cli: CodexCLIResolver.ResolvedCLI) -> [String: String] {
        var environment = cli.environment
        let codexBinDirectory = URL(fileURLWithPath: cli.path).deletingLastPathComponent().path
        let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
        let currentPath = environment["PATH"] ?? defaultPath
        let pathParts = ([codexBinDirectory] + currentPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { result, path in
                guard !result.contains(path) else {
                    return
                }

                result.append(path)
            }

        environment["PATH"] = pathParts.joined(separator: ":")
        return environment
    }

    private func sendRequestLocked(
        method: String,
        id: Int,
        params: JSONDictionary?,
        timeoutSeconds: TimeInterval? = nil,
        completion: @escaping Completion
    ) {
        var message: JSONDictionary = [
            "method": method,
            "id": id,
        ]

        if let params {
            message["params"] = params
        }

        let timeoutWorkItem = timeoutSeconds.map { seconds in
            DispatchWorkItem { [weak self] in
                self?.handleRequestTimeoutLocked(id: id, method: method, seconds: seconds)
            }
        }
        pending[id] = PendingRequest(completion: completion, timeoutWorkItem: timeoutWorkItem)
        guard writeMessageLocked(message) else {
            return
        }
        log("RPC request \(id) \(method)")

        if let timeoutWorkItem, let timeoutSeconds {
            queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWorkItem)
        }
    }

    private func handleRequestTimeoutLocked(id: Int, method: String, seconds: TimeInterval) {
        guard pending[id] != nil else {
            return
        }

        let error = QuotaError.rpcError(I18n.current.rpcRequestTimedOut(method: method, seconds: Int(seconds.rounded(.up))))
        log("RPC request \(id) \(method) timed out")
        stopLocked(error: error)
    }

    private func sendNotificationLocked(method: String, params: JSONDictionary?) -> Bool {
        var message: JSONDictionary = [
            "method": method,
        ]

        if let params {
            message["params"] = params
        }

        guard writeMessageLocked(message) else {
            return false
        }
        log("RPC notification sent \(method)")
        return true
    }

    private func writeMessageLocked(_ message: JSONDictionary) -> Bool {
        do {
            guard let handle = inputPipe?.fileHandleForWriting else {
                stopLocked()
                return false
            }
            let data = try JSONSerialization.data(withJSONObject: message, options: [])
            var line = data
            line.append(0x0A)
            try handle.write(contentsOf: line)
            return true
        } catch {
            log("Failed to encode RPC message: \(error.localizedDescription)")
            stopLocked(error: error)
            return false
        }
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)

        while let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
            guard outputBuffer.distance(from: outputBuffer.startIndex, to: newlineIndex) <= configuration.maximumOutputBytes else {
                failOversizedOutputLocked()
                return
            }

            let lineData = outputBuffer[..<newlineIndex]
            outputBuffer.removeSubrange(...newlineIndex)

            guard !lineData.isEmpty else {
                continue
            }

            autoreleasepool {
                handleLine(Data(lineData))
            }
        }

        if outputBuffer.count > configuration.maximumOutputBytes {
            failOversizedOutputLocked()
        }
    }

    private func failOversizedOutputLocked() {
        let megabytes = max(1, configuration.maximumOutputBytes / 1_024 / 1_024)
        let error = QuotaError.rpcError(I18n.current.rpcResponseExceededLimit(megabytes: megabytes))
        log("Discarding oversized app-server output buffer")
        stopLocked(error: error)
    }

    private func handleLine(_ lineData: Data) {
        do {
            let object = try JSONSerialization.jsonObject(with: lineData, options: [])
            guard let message = object as? JSONDictionary else {
                log("RPC non-object message ignored")
                return
            }

            if let id = message["id"] as? Int {
                guard let request = pending.removeValue(forKey: id) else {
                    log("RPC response \(id) has no pending request")
                    return
                }

                request.timeoutWorkItem?.cancel()

                if id == 0 {
                    cancelInitializationTimeoutLocked()
                }

                if let errorObject = message["error"] as? JSONDictionary {
                    request.completion(.failure(QuotaError.rpcError(rpcErrorMessage(errorObject))))
                } else {
                    request.completion(.success(message))
                }
                return
            }

            if let method = message["method"] as? String {
                guard method == "account/updated" || method == "account/rateLimits/updated" else {
                    return
                }
                enqueueNotification(method: method, params: message["params"] as? JSONDictionary)
            }
        } catch {
            log("Failed to parse RPC line: \(error.localizedDescription)")
        }
    }

    private func enqueueNotification(method: String, params: JSONDictionary?) {
        notificationLock.lock()
        queuedNotifications[method] = params ?? [:]
        let shouldSchedule = !notificationDeliveryScheduled
        notificationDeliveryScheduled = true
        notificationLock.unlock()

        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.notificationLock.lock()
                let notifications = self.queuedNotifications
                self.queuedNotifications.removeAll()
                self.notificationDeliveryScheduled = false
                self.notificationLock.unlock()
                // Account invalidation takes precedence over a quota-only refresh.
                for method in ["account/updated", "account/rateLimits/updated"] {
                    if let params = notifications[method] {
                        self.notificationHandler?(method, params)
                    }
                }
            }
        }
    }

    private func rpcErrorMessage(_ errorObject: JSONDictionary) -> String {
        if let message = errorObject["message"] as? String {
            return message
        }

        return prettyPrintedSanitizedJSON(errorObject)
    }

    private func failAllPendingLocked(_ error: Error) {
        let requests = Array(pending.values)
        pending.removeAll()
        requests.forEach { $0.timeoutWorkItem?.cancel() }
        requests.forEach { $0.completion(.failure(error)) }
    }

    private func stopLocked(error: Error = QuotaError.appServerStartFailed(I18n.current.processStopped)) {
        initialized = false
        connectionID = nil
        notificationLock.lock()
        queuedNotifications.removeAll()
        notificationLock.unlock()
        cancelInitializationTimeoutLocked()
        outputSource?.cancel()
        errorSource?.cancel()
        outputSource = nil
        errorSource = nil
        try? inputPipe?.fileHandleForWriting.close()
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        let oldProcess = process
        process = nil
        processStartedAt = nil
        outputBuffer = Data()
        clearStderrBuffer()
        failAllPendingLocked(error)

        if let oldProcess, oldProcess.isRunning {
            oldProcess.terminate()
            queue.asyncAfter(deadline: .now() + configuration.terminationGracePeriod) {
                if oldProcess.isRunning {
                    // Escalate only for the child owned by this client, never another Codex process.
                    Darwin.kill(oldProcess.processIdentifier, SIGKILL)
                }
            }
        }
    }

    private var shouldRecycleProcessLocked: Bool {
        guard pending.isEmpty, let processStartedAt else {
            return false
        }

        return Date().timeIntervalSince(processStartedAt) >= configuration.maximumProcessLifetime
    }

    private static func readCodexCLIVersion(cli: CodexCLIResolver.ResolvedCLI, timeout: TimeInterval) throws -> CodexCLIVersion {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: cli.path)
        process.arguments = ["--version"]
        process.environment = makeProcessEnvironment(cli: cli)
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let handle = outputPipe.fileHandleForReading
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw QuotaError.appServerStartFailed(String(cString: strerror(errno)))
        }
        defer { try? handle.close() }

        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        // Drain while the child runs; waitUntilExit followed by a pipe read can deadlock.
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                output.append(contentsOf: bytes.prefix(min(count, max(0, maximumStderrBytes - output.count))))
            } else if count == 0 && !process.isRunning {
                break
            }

            if ProcessInfo.processInfo.systemUptime >= deadline {
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
                throw QuotaError.rpcError(I18n.current.rpcRequestTimedOut(method: "codex --version", seconds: Int(timeout.rounded(.up))))
            }
            if count <= 0 {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        process.waitUntilExit()
        let versionText = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0, let version = CodexCLIVersion.parse(versionText) else {
            throw QuotaError.appServerStartFailed(versionText)
        }

        return version
    }

    private func prettyPrintedSanitizedJSON(_ object: Any) -> String {
        let sanitized = sanitizeJSONObject(object)
        guard
            JSONSerialization.isValidJSONObject(sanitized),
            let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "\(sanitized)"
        }

        return text
    }

    private func sanitizeJSONObject(_ object: Any) -> Any {
        if let dictionary = object as? JSONDictionary {
            return dictionary.reduce(into: JSONDictionary()) { result, item in
                let key = item.key
                let lowercasedKey = key.lowercased()

                if lowercasedKey.contains("token")
                    || lowercasedKey.contains("secret")
                    || lowercasedKey.contains("authorization")
                    || lowercasedKey.contains("api_key")
                    || lowercasedKey.contains("apikey") {
                    result[key] = "<redacted>"
                } else if lowercasedKey == "email", let email = item.value as? String {
                    result[key] = maskEmail(email)
                } else {
                    result[key] = sanitizeJSONObject(item.value)
                }
            }
        }

        if let array = object as? [Any] {
            return array.map { sanitizeJSONObject($0) }
        }

        return object
    }

    private func maskEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, let first = parts[0].first else {
            return "<redacted-email>"
        }

        return "\(first)***@\(parts[1])"
    }

    private func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}

extension CodexAppServerClient: @unchecked Sendable {}
