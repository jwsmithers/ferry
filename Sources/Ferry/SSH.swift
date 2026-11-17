import Foundation

/// Single-quote a string for a POSIX shell.
func shq(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct SSHError: LocalizedError {
    let message: String
    let status: Int32
    var errorDescription: String? { message }

    init(stderr: String, status: Int32) {
        self.status = status
        let cleaned = SSH.cleanStderr(stderr)
        if !cleaned.isEmpty {
            message = cleaned
        } else if status == 255 {
            message = "SSH connection failed."
        } else {
            message = "Command failed (exit \(status))."
        }
    }

    init(_ message: String) {
        self.message = message
        self.status = 1
    }

    var isConnectionError: Bool { status == 255 }
}

struct SSH: Sendable {
    let host: String

    /// One multiplexed connection per host: the first command opens it (slow through an
    /// IAP tunnel), every later command reuses it and is near-instant.
    static let options: [String] = [
        "-x", "-T",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=30",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=/tmp/ferry-%C",
        "-o", "ControlPersist=600",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=4",
        "-o", "LogLevel=ERROR",
    ]

    private static let usedHostsLock = NSLock()
    nonisolated(unsafe) private static var usedHosts = Set<String>()

    init(host: String) {
        self.host = host
        Self.usedHostsLock.withLock { _ = Self.usedHosts.insert(host) }
    }

    /// A configured (not yet launched) ssh process running `command` on the server.
    func makeProcess(_ command: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["ssh"] + Self.options + ["--", host, command]
        p.environment = LoginEnvironment.shared
        return p
    }

    func runSync(_ command: String) throws -> CommandResult {
        try Runner.runSync("/usr/bin/env", ["ssh"] + Self.options + ["--", host, command])
    }

    func run(_ command: String) async throws -> CommandResult {
        try await Runner.run("/usr/bin/env", ["ssh"] + Self.options + ["--", host, command])
    }

    /// Runs a command and throws if it exits non-zero.
    @discardableResult
    func check(_ command: String) async throws -> CommandResult {
        let r = try await run(command)
        if r.status != 0 { throw SSHError(stderr: r.stderr, status: r.status) }
        return r
    }

    /// Lists a directory. An empty path means the home directory; `~/x` is home-relative.
    func list(_ path: String) async throws -> (cwd: String, files: [RemoteFile]) {
        let cmd = "cd\(Self.cdTarget(path)) || exit 2; printf '%s\\0' \"$PWD\"; "
            + "find -L . -mindepth 1 -maxdepth 1 -printf '%y\\t%s\\t%T@\\t%f\\0' 2>/dev/null; exit 0"
        let r = try await run(cmd)
        guard r.status == 0 else { throw SSHError(stderr: r.stderr, status: r.status) }

        var records = r.stdout.split(separator: 0, omittingEmptySubsequences: true)
        guard !records.isEmpty else { throw SSHError("Unexpected response from server.") }
        let cwd = String(decoding: records.removeFirst(), as: UTF8.self)

        var files: [RemoteFile] = []
        files.reserveCapacity(records.count)
        for rec in records {
            let fields = String(decoding: rec, as: UTF8.self)
                .split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4 else { continue }
            let name = String(fields[3])
            files.append(RemoteFile(
                name: name,
                path: RemotePath.join(cwd, name),
                isDirectory: fields[0] == "d",
                isBrokenLink: fields[0] == "l",
                size: Int64(fields[1]) ?? 0,
                modified: Date(timeIntervalSince1970: Double(fields[2]) ?? 0)
            ))
        }
        return (cwd, files)
    }

    private static func cdTarget(_ path: String) -> String {
        let p = path.trimmingCharacters(in: .whitespaces)
        if p.isEmpty || p == "~" { return "" }
        if p.hasPrefix("~/") { return " ~/" + shq(String(p.dropFirst(2))) }
        return " -- " + shq(p)
    }

    /// Closes the shared connection (and its IAP tunnel).
    func closeMaster() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["ssh"] + Self.options + ["-O", "exit", "--", host]
        p.environment = LoginEnvironment.shared
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
        if done.wait(timeout: .now() + 2) == .timedOut { p.terminate() }
    }

    static func closeAllMasters() {
        let hosts = usedHostsLock.withLock { usedHosts }
        for h in hosts { SSH(host: h).closeMaster() }
    }

    /// Strips gcloud/IAP chatter so real errors are readable.
    static func cleanStderr(_ s: String) -> String {
        let noise = ["NumPy", "performance of the tunnel", "using-tcp-forwarding",
                     "X11 forwarding", "Warning: Permanently added"]
        return s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && line != "WARNING:" && !noise.contains { line.contains($0) }
            }
            .joined(separator: "\n")
    }
}

enum SSHConfig {
    /// Concrete host aliases from ~/.ssh/config (wildcard patterns skipped).
    static func hosts() -> [String] {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var hosts: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count >= 2, parts[0].lowercased() == "host" else { continue }
            for name in parts.dropFirst().map(String.init)
            where !name.contains(where: { "*?!".contains($0) }) && !hosts.contains(name) {
                hosts.append(name)
            }
        }
        return hosts
    }
}
