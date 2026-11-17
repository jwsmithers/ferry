import Foundation

/// The user's login-shell environment. Apps launched from Finder get a minimal PATH,
/// so without this `gcloud` (used by IAP ProxyCommands) or a Homebrew `ssh` wouldn't be found.
enum LoginEnvironment {
    static let shared: [String: String] = load()

    private static func load() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let captured = captureLoginShell() {
            env.merge(captured) { _, new in new }
        }
        let home = NSHomeDirectory()
        var path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/google-cloud-sdk/bin",
                      "/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !path.contains(extra) {
            path.append(extra)
        }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    private static func captureLoginShell() -> [String: String]? {
        var shell = "/bin/zsh"
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty { shell = s }
        }
        let marker = "__FERRY_ENV_START__"
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-env-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outURL) }
        guard let out = try? FileHandle(forWritingTo: outURL) else { return nil }
        defer { try? out.close() }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf '\(marker)'; /usr/bin/env -0"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
        if done.wait(timeout: .now() + 10) == .timedOut {
            p.terminate()
            return nil
        }

        guard let data = try? Data(contentsOf: outURL),
              let markerRange = data.range(of: Data(marker.utf8)) else { return nil }
        var env: [String: String] = [:]
        for entry in data[markerRange.upperBound...].split(separator: 0) {
            let s = String(decoding: entry, as: UTF8.self)
            guard let eq = s.firstIndex(of: "="), eq != s.startIndex else { continue }
            env[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        // Don't inherit shell-session-specific values.
        for key in ["SHLVL", "PWD", "OLDPWD", "_"] { env.removeValue(forKey: key) }
        return env.isEmpty ? nil : env
    }
}

/// Captures a child's stderr in a temp file rather than a pipe. With an IAP ProxyCommand,
/// the `gcloud` helper inherits ssh's stderr and outlives it (ControlPersist), so a pipe
/// would never reach EOF.
final class StderrCapture {
    let url: URL
    let handle: FileHandle

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func read() -> String {
        let data = (try? Data(contentsOf: url)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}

struct CommandResult {
    var status: Int32
    var stdout: Data
    var stderr: String
}

enum Runner {
    static func runSync(_ executable: String, _ args: [String]) throws -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = LoginEnvironment.shared
        let out = Pipe()
        let err = try StderrCapture()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = err.handle
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return CommandResult(status: p.terminationStatus, stdout: data, stderr: err.read())
    }

    static func run(_ executable: String, _ args: [String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try runSync(executable, args)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}
