import Darwin
import Foundation
import Testing
@testable import AgentBar

private final class ShellTestBundle: NSObject {}

@MainActor
@Suite(.serialized)
final class ShellEnvironmentResolverTests {
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

    private func appExecutable() throws -> URL {
        var directory = Bundle(for: ShellTestBundle.self).bundleURL
        for _ in 0..<6 {
            let executable = directory.appendingPathComponent("AgentBar")
            if FileManager.default.isExecutableFile(atPath: executable.path) {
                return executable
            }
            directory.deleteLastPathComponent()
        }
        throw TestError.missingAppExecutable
    }

    private enum TestError: Error { case missingAppExecutable }

    private func inheritedEnvironment(home: URL) -> [String: String] {
        ["HOME": home.path, "ZDOTDIR": home.path, "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"]
    }

    private func resolver(
        home: URL,
        shellPath: String = "/bin/zsh",
        helperExecutableURL: URL? = nil,
        timeout: TimeInterval = 2
    ) throws -> ShellEnvironmentResolver {
        ShellEnvironmentResolver(
            environment: inheritedEnvironment(home: home),
            shellPath: shellPath,
            helperExecutableURL: try helperExecutableURL ?? appExecutable(),
            timeout: timeout
        )
    }

    @Test func loadsLoginAndInteractiveConfigurationWithoutBannerPollution() throws {
        let home = try makeDirectory()
        try write("export AGENTBAR_TEST_LOGIN=loaded\n", to: home.appendingPathComponent(".zprofile"))
        try write("""
        echo 'startup banner {not JSON}'
        export PATH='/custom/package manager/bin:/usr/bin:/bin'
        export AGENTBAR_TEST_VALUE='first line
        second=你好'
        export AGENTBAR_TEST_EMPTY=''
        """, to: home.appendingPathComponent(".zshrc"))
        try write("echo 'logout banner'\n", to: home.appendingPathComponent(".zlogout"))

        let environment = try resolver(home: home).resolve()
        #expect(environment["PATH"] == "/custom/package manager/bin:/usr/bin:/bin")
        #expect(environment["AGENTBAR_TEST_LOGIN"] == "loaded")
        #expect(environment["AGENTBAR_TEST_VALUE"] == "first line\nsecond=你好")
        #expect(environment["AGENTBAR_TEST_EMPTY"] == "")
        #expect(environment["DISABLE_AUTO_UPDATE"] == nil)
        #expect(environment["ZSH_TMUX_AUTOSTARTED"] == nil)
        #expect(environment["ZSH_TMUX_AUTOSTART"] == nil)
    }

    @Test func usesConfiguredShellAndQuotesExecutablePaths() throws {
        let home = try makeDirectory()
        let helper = home.appendingPathComponent("Agent Bar's $name `text` 中文")
        try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: appExecutable())
        try write("export AGENTBAR_TEST_VALUE='bash login'\n", to: home.appendingPathComponent(".bash_profile"))
        var inherited = inheritedEnvironment(home: home)
        inherited["SHELL"] = "/bin/bash"
        inherited["DISABLE_AUTO_UPDATE"] = "original"
        let resolver = ShellEnvironmentResolver(environment: inherited, helperExecutableURL: helper, timeout: 2)
        let environment = resolver.resolve()
        #expect(environment["AGENTBAR_TEST_VALUE"] == "bash login")
        #expect(environment["DISABLE_AUTO_UPDATE"] == "original")
    }

    @Test func cachesEnvironmentUntilResolverIsRecreated() throws {
        let home = try makeDirectory()
        let configuration = home.appendingPathComponent(".zshrc")
        try write("export AGENTBAR_TEST_VALUE=first\n", to: configuration)
        let resolver = try resolver(home: home)
        #expect(resolver.resolve()["AGENTBAR_TEST_VALUE"] == "first")
        try write("export AGENTBAR_TEST_VALUE=second\n", to: configuration)
        #expect(resolver.resolve()["AGENTBAR_TEST_VALUE"] == "first")
        #expect(try self.resolver(home: home).resolve()["AGENTBAR_TEST_VALUE"] == "second")
    }

    @Test func failedShellFallsBackAndCachesFailure() throws {
        let home = try makeDirectory()
        let configuration = home.appendingPathComponent(".zshrc")
        try write("exit 9\n", to: configuration)
        let resolver = try resolver(home: home)
        #expect(resolver.resolve() == inheritedEnvironment(home: home))
        try write("export AGENTBAR_TEST_VALUE=shouldNotLoad\n", to: configuration)
        #expect(resolver.resolve() == inheritedEnvironment(home: home))
    }

    @Test func missingShellOrInvalidHelperOutputFallsBack() throws {
        let home = try makeDirectory()
        #expect(try resolver(home: home, shellPath: home.appendingPathComponent("missing").path).resolve() == inheritedEnvironment(home: home))
        #expect(try resolver(home: home, helperExecutableURL: URL(fileURLWithPath: "/usr/bin/true")).resolve() == inheritedEnvironment(home: home))
    }

    @Test func hangingShellHasBoundedLifetime() throws {
        let home = try makeDirectory()
        try write("while true; do :; done\n", to: home.appendingPathComponent(".zshrc"))
        let resolver = try resolver(home: home, timeout: 0.1)
        let start = ProcessInfo.processInfo.systemUptime
        #expect(resolver.resolve() == inheritedEnvironment(home: home))
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    }

    @Test func excessiveShellOutputFallsBackWithoutBlocking() throws {
        let home = try makeDirectory()
        try write("/usr/bin/yes 'noisy shell configuration'\n", to: home.appendingPathComponent(".zshrc"))
        let resolver = try resolver(home: home, timeout: 2)
        let start = ProcessInfo.processInfo.systemUptime
        #expect(resolver.resolve() == inheritedEnvironment(home: home))
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    }

    @Test func pathSelectionPrecedesBundledCLIAndSkipsNonExecutables() throws {
        let home = try makeDirectory()
        let first = home.appendingPathComponent("first")
        let second = home.appendingPathComponent("arbitrary pnpm home")
        let app = home.appendingPathComponent("Codex.app")
        let bundled = app.appendingPathComponent("Contents/Resources/codex")
        for directory in [first, second, bundled.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write("#!/bin/sh\n", to: first.appendingPathComponent("codex"))
        try write("#!/bin/sh\n", to: second.appendingPathComponent("codex"), executable: true)
        try write("#!/bin/sh\n", to: bundled, executable: true)
        #expect(CodexCLIResolver.resolve(
            environmentPath: "\(first.path):\(second.path)",
            registeredApplicationURL: app,
            applicationDirectories: []
        ) == second.appendingPathComponent("codex").path)
        #expect(CodexCLIResolver.resolve(
            environmentPath: first.path,
            registeredApplicationURL: app,
            applicationDirectories: []
        ) == bundled.path)
        #expect(CodexCLIResolver.resolve(
            environmentPath: first.path,
            registeredApplicationURL: nil,
            applicationDirectories: []
        ) == nil)
    }

    @Test func versionAndAppServerUseTheDiscoveredShellEnvironment() async throws {
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
        try write(
            "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n",
            to: runtimeBin.appendingPathComponent("agentbar-test-runtime"),
            executable: true
        )
        try write("""
        export PATH='\(bin.path):\(runtimeBin.path):/usr/bin:/bin'
        export AGENTBAR_TEST_VALUE='shell environment'
        """, to: home.appendingPathComponent(".zshrc"))
        let resolver = try resolver(home: home)
        let environment = resolver.resolve()
        #expect(CodexCLIResolver.resolveForLaunch(environment: environment)?.path == bin.appendingPathComponent("codex").path)

        let client = CodexAppServerClient(resolveCLI: {
            CodexCLIResolver.resolveForLaunch(environment: resolver.resolve())
        })
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
        let result = try #require(response.value["result"] as? [String: String])
        #expect(result["value"] == "shell environment")
        #expect(result["path"] == environment["PATH"])
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            client.stop { continuation.resume() }
        }
    }
}
