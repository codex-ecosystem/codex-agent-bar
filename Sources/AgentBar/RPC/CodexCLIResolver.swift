import AppKit
import Darwin
import Foundation

struct CodexCLIResolver {
    struct ResolvedCLI: Sendable {
        let path: String
        let environment: [String: String]
    }

    private static let codexBundleIdentifier = "com.openai.codex"
    private static let bundledAppNames = ["ChatGPT.app", "Codex.app"]
    private static let bundledCLIComponents = ["Contents", "Resources", "codex"]

    static func resolveForLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 10
    ) -> ResolvedCLI? {
        if let cli = resolveUsingShell(environment: environment, timeout: timeout) {
            return cli
        }
        guard let path = resolve(environmentPath: environment["PATH"]) else {
            return nil
        }
        return ResolvedCLI(path: path, environment: environment)
    }

    static func resolveUsingShell(environment: [String: String], timeout: TimeInterval) -> ResolvedCLI? {
        let process = Process()
        let pipe = Pipe()
        let marker = UUID().uuidString
        process.executableURL = URL(fileURLWithPath: environment["SHELL"] ?? "/bin/zsh")
        // NUL separators keep shell banners out of the result. Use the external
        // which so an alias or function named codex cannot become our executable.
        process.arguments = ["-ilc", """
        /usr/bin/printf '\\0%s\\0' '\(marker)'; /usr/bin/which codex; /usr/bin/printf '\\0'; /usr/bin/printenv PATH; /usr/bin/printf '\\0'
        """]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let handle = pipe.fileHandleForReading
        defer {
            try? handle.close()
            try? pipe.fileHandleForWriting.close()
        }
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else { return nil }
        do { try process.run() } catch { return nil }
        try? pipe.fileHandleForWriting.close()
        defer {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                guard output.count + count <= 65_536 else { return nil }
                output.append(contentsOf: bytes.prefix(count))
            } else if !process.isRunning {
                process.waitUntilExit()
                let fields = String(decoding: output, as: UTF8.self).components(separatedBy: "\0")
                guard process.terminationStatus == 0, let start = fields.firstIndex(of: marker), fields.count > start + 2 else { return nil }
                let path = fields[start + 1].trimmingCharacters(in: .newlines)
                let shellPath = fields[start + 2].trimmingCharacters(in: .newlines)
                guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path), !shellPath.isEmpty else { return nil }
                var environment = environment
                environment["PATH"] = shellPath
                return ResolvedCLI(path: path, environment: environment)
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        return nil
    }

    static func resolve(
        fileManager: FileManager = .default,
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
        homeDirectory: URL? = nil,
        registeredApplicationURL: URL? = registeredCodexApplicationURL(),
        applicationDirectories: [URL]? = nil
    ) -> String? {
        let homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]

        let registeredApplicationCandidates: [URL] = registeredApplicationURL.map {
            [bundledCLIURL(in: $0)]
        } ?? []
        let standardApplicationCandidates: [URL] = bundledAppNames.flatMap { appName in
            applicationDirectories.map { directory in
                bundledCLIURL(in: directory.appendingPathComponent(appName, isDirectory: true))
            }
        }
        let bundledCandidates = registeredApplicationCandidates + standardApplicationCandidates

        let pathCandidates = (environmentPath ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("codex") }

        var visitedPaths = Set<String>()
        for candidate in pathCandidates + bundledCandidates {
            let path = candidate.standardizedFileURL.path
            guard visitedPaths.insert(path).inserted else {
                continue
            }

            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    private static func registeredCodexApplicationURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: codexBundleIdentifier)
    }

    private static func bundledCLIURL(in applicationURL: URL) -> URL {
        bundledCLIComponents.reduce(applicationURL) { url, component in
            url.appendingPathComponent(component)
        }
    }
}
