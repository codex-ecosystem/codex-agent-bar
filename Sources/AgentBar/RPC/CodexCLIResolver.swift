import AppKit
import Darwin
import Foundation

struct CodexCLIResolver {
    struct ResolvedCLI: Sendable {
        let executablePath: String
        // Bundled installations use the app's environment; shell lookups retain their exact PATH.
        let environmentPath: String?
    }

    private static let codexBundleIdentifier = "com.openai.codex"
    private static let bundledAppNames = ["ChatGPT.app", "Codex.app"]
    private static let bundledCLIComponents = [
        ["Contents", "Resources", "codex"],
        ["Contents", "Resources", "codex-cli", "CodexCLI.app", "Contents", "MacOS", "codex"],
    ]

    static func resolve(
        fileManager: FileManager = .default,
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
        homeDirectory: URL? = nil,
        registeredApplicationURL: URL? = registeredCodexApplicationURL(),
        applicationDirectories: [URL]? = nil,
        shellExecutableURL: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"),
        shellLookupTimeout: TimeInterval = 3
    ) -> ResolvedCLI? {
        var isDirectory: ObjCBool = false
        if let cli = resolveShellCLI(
            shellExecutableURL: shellExecutableURL,
            environmentPath: environmentPath,
            timeout: shellLookupTimeout
        ), fileManager.fileExists(atPath: cli.executablePath, isDirectory: &isDirectory),
           !isDirectory.boolValue, fileManager.isExecutableFile(atPath: cli.executablePath) {
            return cli
        }

        let homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]

        let registeredApplicationCandidates: [URL] = registeredApplicationURL.map {
            bundledCLIURLs(in: $0)
        } ?? []
        let standardApplicationCandidates: [URL] = bundledAppNames.flatMap { appName in
            applicationDirectories.flatMap { directory in
                bundledCLIURLs(in: directory.appendingPathComponent(appName, isDirectory: true))
            }
        }
        let bundledCandidates = registeredApplicationCandidates + standardApplicationCandidates

        var visitedPaths = Set<String>()
        for candidate in bundledCandidates {
            let path = candidate.standardizedFileURL.path
            guard visitedPaths.insert(path).inserted else {
                continue
            }

            if fileManager.isExecutableFile(atPath: path) {
                return ResolvedCLI(executablePath: path, environmentPath: nil)
            }
        }

        return nil
    }

    private static func resolveShellCLI(
        shellExecutableURL: URL,
        environmentPath: String?,
        timeout: TimeInterval
    ) -> ResolvedCLI? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = shellExecutableURL
        // Finder launches do not inherit the PATH set by login and interactive shell profiles.
        // Keep the PATH that found the CLI: package-manager shims may need node from another directory.
        process.arguments = ["-ilc", "/usr/bin/which codex && /usr/bin/printf '\\0%s\\0' \"$PATH\""]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = environmentPath
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let handle = outputPipe.fileHandleForReading
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            return nil
        }
        defer {
            try? handle.close()
            try? outputPipe.fileHandleForWriting.close()
        }

        do {
            try process.run()
        } catch {
            return nil
        }
        defer {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let maximumOutputBytes = 64 * 1_024
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                guard output.count + count <= maximumOutputBytes else { return nil }
                output.append(contentsOf: bytes.prefix(count))
            } else if !process.isRunning {
                break
            } else if count < 0, errno != EAGAIN && errno != EINTR {
                return nil
            }

            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            if count <= 0 {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        // NUL framing preserves spaces and newlines in PATH and separates shell startup/logout output.
        let fields = output.split(separator: 0, omittingEmptySubsequences: false)
        guard process.terminationStatus == 0, fields.count >= 3,
              let path = String(bytes: fields[0], encoding: .utf8)?
                .split(whereSeparator: \.isNewline).last.map(String.init),
              path.hasPrefix("/"),
              let environmentPath = String(bytes: fields[1], encoding: .utf8) else {
            return nil
        }
        return ResolvedCLI(executablePath: path, environmentPath: environmentPath)
    }

    private static func registeredCodexApplicationURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: codexBundleIdentifier)
    }

    private static func bundledCLIURLs(in applicationURL: URL) -> [URL] {
        bundledCLIComponents.map { components in
            components.reduce(applicationURL) { url, component in
                url.appendingPathComponent(component)
            }
        }
    }
}
