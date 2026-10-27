import AppKit
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
        environment: [String: String] = ShellEnvironmentResolver.shared.resolve()
    ) -> ResolvedCLI? {
        guard let path = resolve(environmentPath: environment["PATH"]) else {
            return nil
        }
        return ResolvedCLI(path: path, environment: environment)
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
