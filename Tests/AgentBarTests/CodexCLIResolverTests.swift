import Foundation
import Testing
@testable import AgentBar

@MainActor
@Suite(.serialized)
final class CodexCLIResolverTests {
    private var directories: [URL] = []

    deinit {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func write(_ contents: String, to url: URL, executable: Bool = false) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private func inheritedEnvironment(home: URL) -> [String: String] {
        ["HOME": home.path, "ZDOTDIR": home.path, "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"]
    }

    @Test func whichLoadsShellConfigurationAndIgnoresBannersAndAliases() throws {
        let home = try makeDirectory()
        let bin = home.appendingPathComponent("custom global bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("codex")
        try write("#!/bin/sh\n", to: executable, executable: true)
        try write("export PATH='\(bin.path):/usr/bin:/bin'\n", to: home.appendingPathComponent(".zprofile"))
        try write("echo 'startup banner'\nalias codex='echo alias'\n", to: home.appendingPathComponent(".zshrc"))
        try write("echo 'logout banner'\n", to: home.appendingPathComponent(".zlogout"))
        let cli = try #require(CodexCLIResolver.resolveUsingShell(environment: inheritedEnvironment(home: home), timeout: 2))
        #expect(cli.path == executable.path)
        #expect(cli.environment["PATH"] == "\(bin.path):/usr/bin:/bin")
    }

    @Test func missingCLIFailedShellAndTimeoutDoNotBlockFallback() throws {
        let home = try makeDirectory()
        let environment = inheritedEnvironment(home: home)
        try write("export PATH=/usr/bin:/bin\n", to: home.appendingPathComponent(".zshrc"))
        #expect(CodexCLIResolver.resolveUsingShell(environment: environment, timeout: 2) == nil)
        try write("exit 9\n", to: home.appendingPathComponent(".zshrc"))
        #expect(CodexCLIResolver.resolveUsingShell(environment: environment, timeout: 2) == nil)
        try write("while true; do :; done\n", to: home.appendingPathComponent(".zshrc"))
        let start = ProcessInfo.processInfo.systemUptime
        let cli = CodexCLIResolver.resolveForLaunch(environment: environment, timeout: 0.1)
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
        #expect(cli?.path == CodexCLIResolver.resolve(environmentPath: environment["PATH"]))
    }

    @Test func inheritedPathAndBundledCLIRemainFallbacks() throws {
        let home = try makeDirectory()
        let bin = home.appendingPathComponent("bin")
        let app = home.appendingPathComponent("Codex.app")
        let bundled = app.appendingPathComponent("Contents/Resources/codex")
        for directory in [bin, bundled.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let executable = bin.appendingPathComponent("codex")
        try write("#!/bin/sh\n", to: executable, executable: true)
        try write("#!/bin/sh\n", to: bundled, executable: true)
        #expect(CodexCLIResolver.resolve(environmentPath: bin.path, registeredApplicationURL: app, applicationDirectories: []) == executable.path)
        #expect(CodexCLIResolver.resolve(environmentPath: "", registeredApplicationURL: app, applicationDirectories: []) == bundled.path)
    }

    @Test func versionAndAppServerUseThePathReturnedAlongsideWhich() async throws {
        let home = try makeDirectory()
        let bin = home.appendingPathComponent("custom global bin")
        let runtimeBin = home.appendingPathComponent("custom runtime bin")
        for directory in [bin, runtimeBin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let fixture = try #require(Bundle.module.url(forResource: "mock-codex", withExtension: "py", subdirectory: "Fixtures"))
        let contents = try String(contentsOf: fixture, encoding: .utf8)
            .replacingOccurrences(of: "#!/usr/bin/python3", with: "#!/usr/bin/env agentbar-test-runtime")
        try write(contents, to: bin.appendingPathComponent("codex"), executable: true)
        try write("#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n", to: runtimeBin.appendingPathComponent("agentbar-test-runtime"), executable: true)
        try write("export PATH='\(bin.path):\(runtimeBin.path):/usr/bin:/bin'\n", to: home.appendingPathComponent(".zshrc"))
        let environment = inheritedEnvironment(home: home)
        let cli = try #require(CodexCLIResolver.resolveForLaunch(environment: environment))
        #expect(cli.path == bin.appendingPathComponent("codex").path)
        let client = CodexAppServerClient(resolveCLI: { cli })
        defer { client.stop() }
        let version = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CodexCLIVersion, Error>) in
            client.checkMinimumResetCreditsVersion { continuation.resume(with: $0) }
        }
        #expect(version == CodexAppServerClient.minimumResetCreditsVersion)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.start { continuation.resume(with: $0) }
        }
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UncheckedSendable<CodexAppServerClient.JSONDictionary>, Error>) in
            client.sendRequest(method: "environment") { continuation.resume(with: $0.map(UncheckedSendable.init)) }
        }
        let result = try #require(response.value["result"] as? [String: Any])
        #expect(result["path"] as? String == cli.environment["PATH"])
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            client.stop { continuation.resume() }
        }
    }
}
