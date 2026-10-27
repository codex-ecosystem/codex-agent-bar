import Darwin
import Foundation
import Testing
@testable import AgentBar

@Suite(.serialized)
final class CodexCLIResolverTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func makeFile(_ relativePath: String, contents: String = "#!/bin/sh\nexit 0\n", executable: Bool = true) throws -> URL {
        let url = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    private func resolve(
        shell: URL? = nil,
        environmentPath: String? = nil,
        timeout: TimeInterval = 3
    ) -> String? {
        CodexCLIResolver.resolve(
            environmentPath: environmentPath,
            homeDirectory: directory,
            registeredApplicationURL: nil,
            applicationDirectories: [directory.appendingPathComponent("Applications")],
            shellExecutableURL: shell ?? directory.appendingPathComponent("missing-shell"),
            shellLookupTimeout: timeout
        )?.executablePath
    }

    @Test func discoversCLIFromLoginAndInteractiveShellProfiles() throws {
        let codex = try makeFile("custom node/bin/codex")
        try makeFile("profiles/.zprofile", contents: "export CODEX_TEST_BIN='\(codex.deletingLastPathComponent().path)'\n")
        try makeFile("profiles/.zshrc", contents: "export PATH=\"$CODEX_TEST_BIN:$PATH\"\n")
        let shell = try makeFile("shell", contents: """
        #!/bin/sh
        export ZDOTDIR='\(directory.appendingPathComponent("profiles").path)'
        exec /bin/zsh "$@"
        """)

        #expect(resolve(shell: shell, environmentPath: "/usr/bin:/bin") == codex.path)
    }

    @Test func shellCLIHasPriorityOverBundledAndInheritedPathCLIs() throws {
        let codex = try makeFile("custom/bin/codex")
        let inheritedCodex = try makeFile("inherited/bin/codex")
        try makeFile("Applications/Codex.app/Contents/Resources/codex")
        let shell = try makeFile("shell", contents: "#!/bin/sh\nprintf '%s\\n' 'startup message'\nprintf '%s\\n\\000%s\\000' '\(codex.path)' '/usr/bin:/bin'\n")

        #expect(resolve(shell: shell, environmentPath: inheritedCodex.deletingLastPathComponent().path) == codex.path)
    }

    @Test func retainsShellPathDespiteProfileOutput() throws {
        let codex = try makeFile("Library/pnpm/codex")
        let shellPath = "/custom node/bin:/directory\nwith newline:/usr/bin:/bin"
        let shell = try makeFile("shell", contents: """
        #!/bin/sh
        printf '%s\\n' 'startup message'
        printf '%s\\n\\000%s\\000' '\(codex.path)' '\(shellPath)'
        printf '%s\\n' 'logout message'
        """)
        let cli = try #require(CodexCLIResolver.resolve(
            environmentPath: "/usr/bin:/bin",
            registeredApplicationURL: nil,
            applicationDirectories: [],
            shellExecutableURL: shell
        ))

        #expect(cli.executablePath == codex.path)
        #expect(cli.environmentPath == shellPath)
    }

    @Test(arguments: ["missing", "relative", "non-executable", "directory", "nonzero-exit"])
    func invalidShellResultsFallBackToBundledCLI(_ result: String) throws {
        let fallback = try makeFile("Applications/Codex.app/Contents/Resources/codex")
        let candidate: String
        switch result {
        case "relative":
            candidate = "relative/codex"
        case "non-executable":
            candidate = try makeFile("invalid/codex", executable: false).path
        case "directory":
            candidate = directory.path
        case "nonzero-exit":
            candidate = try makeFile("invalid/codex").path
        default:
            candidate = directory.appendingPathComponent("missing/codex").path
        }
        let exitCode = result == "nonzero-exit" ? 1 : 0
        let shell = try makeFile("shell", contents: "#!/bin/sh\nprintf '%s\\n\\000%s\\000' '\(candidate)' '/usr/bin:/bin'\nexit \(exitCode)\n")

        #expect(resolve(shell: shell) == fallback.path)
    }

    @Test func stalledShellTimesOutAndIsReaped() throws {
        let fallback = try makeFile("Applications/Codex.app/Contents/Resources/codex")
        let pidFile = directory.appendingPathComponent("shell.pid")
        let shell = try makeFile("shell", contents: "#!/bin/sh\nprintf '%s' \"$$\" > '\(pidFile.path)'\nwhile :; do :; done\n")
        let startedAt = ProcessInfo.processInfo.systemUptime

        #expect(resolve(shell: shell, timeout: 0.5) == fallback.path)
        #expect(ProcessInfo.processInfo.systemUptime - startedAt < 2)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(Int32(pidText))
        #expect(kill(pid, 0) == -1)
    }

    @Test func noisyShellCannotBlockOnAFullPipe() throws {
        let fallback = try makeFile("Applications/Codex.app/Contents/Resources/codex")
        let shell = try makeFile("shell", contents: "#!/bin/sh\nwhile :; do printf '%01024d\\n' 0; done\n")

        #expect(resolve(shell: shell) == fallback.path)
    }

    @Test(arguments: ["codex", "codex-cli/CodexCLI.app/Contents/MacOS/codex"])
    func unavailableShellFallsBackToBundledCLI(_ cliPath: String) throws {
        let codex = try makeFile("Applications/Codex.app/Contents/Resources/\(cliPath)")

        #expect(resolve() == codex.path)
    }

    @Test func unavailableShellDoesNotScanStandaloneInstallations() throws {
        let codex = try makeFile("inherited/bin/codex")
        try makeFile(".nvm/versions/node/v22.0.0/bin/codex")
        try makeFile("opt/homebrew/bin/codex")
        try makeFile("usr/local/bin/codex")

        #expect(resolve(environmentPath: codex.deletingLastPathComponent().path) == nil)
    }

    @Test func missingCLIStillReturnsNil() {
        #expect(resolve() == nil)
    }
}
