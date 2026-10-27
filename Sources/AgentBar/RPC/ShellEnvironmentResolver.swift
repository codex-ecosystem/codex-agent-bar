import Darwin
import Foundation

/// Resolves once, on the RPC queue, so GUI launches use the user's CLI environment.
final class ShellEnvironmentResolver: @unchecked Sendable {
    static let shared = ShellEnvironmentResolver()
    static let helperArgument = "--agentbar-shell-environment"

    private let inheritedEnvironment: [String: String]
    private let shellPath: String
    private let helperExecutableURL: URL?
    private let timeout: TimeInterval
    private let lock = NSLock()
    // Both successful results and fallbacks are cached under the lock.
    private var cachedEnvironment: [String: String]?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellPath: String? = nil,
        helperExecutableURL: URL? = Bundle.main.executableURL,
        timeout: TimeInterval = 10
    ) {
        inheritedEnvironment = environment
        self.shellPath = shellPath ?? environment["SHELL"] ?? Self.loginShellPath() ?? "/bin/zsh"
        self.helperExecutableURL = helperExecutableURL
        self.timeout = timeout
    }

    func resolve() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedEnvironment {
            return cachedEnvironment
        }

        let environment = readShellEnvironment() ?? inheritedEnvironment
        cachedEnvironment = environment
        return environment
    }

    /// Re-enter the executable without initializing AppKit or starting another app.
    /// JSON preserves newlines and '=' in values without depending on Node or Python.
    static func printEnvironmentIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, arguments[1] == helperArgument else {
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ProcessInfo.processInfo.environment) else {
            exit(EXIT_FAILURE)
        }
        let marker = Data(arguments[2].utf8)
        FileHandle.standardOutput.write(marker)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(marker)
        exit(EXIT_SUCCESS)
    }

    private func readShellEnvironment() -> [String: String]? {
        guard let helperExecutableURL, shellPath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: shellPath) else {
            return nil
        }

        let marker = "__AGENTBAR_ENV_\(UUID().uuidString)__"
        let process = Process()
        let pipe = Pipe()
        let handle = pipe.fileHandleForReading
        defer {
            try? handle.close()
            try? pipe.fileHandleForWriting.close()
        }
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            return nil
        }

        // Shell configuration may print banners or wait for terminal input.
        // Keep stdin closed, discard stderr, and bound both time and stdout size.
        let shellOverrides = [
            "DISABLE_AUTO_UPDATE": "true",
            "ZSH_TMUX_AUTOSTARTED": "true",
            "ZSH_TMUX_AUTOSTART": "false",
        ]
        process.environment = inheritedEnvironment.merging(shellOverrides) { _, override in override }
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = shellArguments(helperPath: helperExecutableURL.path, marker: marker)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        try? pipe.fileHandleForWriting.close()
        defer {
            if process.isRunning {
                let pid = process.processIdentifier
                // Only signal a group if the child owns it; never signal our own group.
                Darwin.kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
            }
            process.waitUntilExit()
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let maximumOutputBytes = 1_024 * 1_024
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                guard output.count + count <= maximumOutputBytes else {
                    return nil
                }
                output.append(contentsOf: bytes.prefix(count))
            } else {
                if !process.isRunning {
                    process.waitUntilExit()
                    guard process.terminationStatus == 0,
                          var environment = Self.parseEnvironment(output, marker: marker),
                          environment["PATH"]?.isEmpty == false else {
                        return nil
                    }
                    for key in shellOverrides.keys {
                        environment[key] = inheritedEnvironment[key]
                    }
                    return environment
                }
                if count < 0, errno != EAGAIN, errno != EINTR {
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        return nil
    }

    private func shellArguments(helperPath: String, marker: String) -> [String] {
        let name = URL(fileURLWithPath: shellPath).lastPathComponent
        let arguments = [helperPath, Self.helperArgument, marker]
        switch name {
        case "pwsh", "powershell", "pwsh-preview", "powershell-preview":
            let command = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: " ")
            return ["-Login", "-Command", "& " + command]
        case "nu":
            // Nushell raw strings can contain quotes, spaces and shell metacharacters.
            let command = arguments.map { argument in
                var delimiter = "#"
                while argument.contains("'" + delimiter) { delimiter += "#" }
                return "r\(delimiter)'\(argument)'\(delimiter)"
            }.joined(separator: " ")
            return ["-i", "-l", "-c", "^" + command]
        default:
            let command = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            // csh/tcsh do not accept login mode together with a command.
            let flags = (name == "csh" || name == "tcsh") ? ["-i", "-c"] : ["-i", "-l", "-c"]
            return flags + [command]
        }
    }

    private static func parseEnvironment(_ data: Data, marker: String) -> [String: String]? {
        let delimiter = Data(marker.utf8)
        guard let start = data.range(of: delimiter),
              let end = data.range(of: delimiter, in: start.upperBound..<data.endIndex),
              let environment = try? JSONSerialization.jsonObject(with: data[start.upperBound..<end.lowerBound]) as? [String: String] else {
            return nil
        }
        return environment
    }

    private static func loginShellPath() -> String? {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        return buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(getuid(), &entry, bytes.baseAddress, bytes.count, &result) == 0,
                  result != nil, let shell = entry.pw_shell, shell.pointee != 0 else {
                return nil
            }
            return String(cString: shell)
        }
    }
}
