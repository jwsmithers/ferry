import AppKit

enum TransferKind: Sendable {
    case downloadFile(remote: String, size: Int64)
    case downloadDirectory(remote: String)
    case uploadFile(remote: String)
    case uploadDirectory(remote: String)

    var isDownload: Bool {
        switch self {
        case .downloadFile, .downloadDirectory: return true
        case .uploadFile, .uploadDirectory: return false
        }
    }
}

@MainActor @Observable
final class Transfer: Identifiable {
    enum State: Equatable {
        case queued, running, finished, cancelled
        case failed(String)
    }

    let id = UUID()
    let name: String
    let kind: TransferKind
    let localURL: URL
    /// Remote directory the item lands in (uploads) — used to refresh the listing.
    let remoteDirectory: String
    let openWhenDone: Bool

    var state: State = .queued
    var bytes: Int64 = 0
    var total: Int64?
    var bytesPerSecond: Double = 0

    @ObservationIgnored var worker: TransferWorker?
    @ObservationIgnored private var sample: (time: Date, bytes: Int64)?

    init(name: String, kind: TransferKind, localURL: URL, remoteDirectory: String, openWhenDone: Bool) {
        self.name = name
        self.kind = kind
        self.localURL = localURL
        self.remoteDirectory = remoteDirectory
        self.openWhenDone = openWhenDone
    }

    var isActive: Bool { state == .queued || state == .running }

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(Double(bytes) / Double(total), 0.99)
    }

    func update(bytes newBytes: Int64) {
        bytes = newBytes
        let now = Date()
        if let s = sample {
            let dt = now.timeIntervalSince(s.time)
            if dt >= 1 {
                bytesPerSecond = Double(newBytes - s.bytes) / dt
                sample = (now, newBytes)
            }
        } else {
            sample = (now, newBytes)
        }
    }
}

@MainActor @Observable
final class TransferManager {
    var ssh: SSH?
    private(set) var items: [Transfer] = []
    @ObservationIgnored var onUploadFinished: ((String) -> Void)?

    /// sshd allows ~10 sessions per multiplexed connection; leave room for browsing.
    private let maxConcurrent = 3

    var activeCount: Int { items.filter(\.isActive).count }
    var hasFinished: Bool { items.contains { !$0.isActive } }

    // MARK: Enqueue

    func download(_ file: RemoteFile, to dir: URL) {
        let reserved = Set(items.filter(\.isActive).map(\.localURL.path))
        let local = LocalFiles.uniqueURL(in: dir, name: file.name, reserved: reserved)
        let kind: TransferKind = file.isDirectory
            ? .downloadDirectory(remote: file.path)
            : .downloadFile(remote: file.path, size: file.size)
        add(Transfer(name: file.name, kind: kind, localURL: local,
                     remoteDirectory: RemotePath.parent(file.path), openWhenDone: false))
    }

    func openRemoteFile(_ file: RemoteFile, host: String) {
        let local = LocalFiles.cacheURL(host: host, remotePath: file.path)
        add(Transfer(name: file.name, kind: .downloadFile(remote: file.path, size: file.size),
                     localURL: local, remoteDirectory: RemotePath.parent(file.path), openWhenDone: true))
    }

    func upload(_ url: URL, into remoteDir: String) {
        let name = url.lastPathComponent
        let remote = RemotePath.join(remoteDir, name)
        let kind: TransferKind = LocalFiles.isDirectory(url)
            ? .uploadDirectory(remote: remote)
            : .uploadFile(remote: remote)
        add(Transfer(name: name, kind: kind, localURL: url, remoteDirectory: remoteDir, openWhenDone: false))
    }

    private func add(_ t: Transfer) {
        items.append(t)
        startQueued()
    }

    // MARK: Control

    func cancel(_ t: Transfer) {
        switch t.state {
        case .queued: t.state = .cancelled
        case .running: t.worker?.cancel()
        default: break
        }
    }

    func cancelAll() {
        for t in items { cancel(t) }
    }

    func remove(_ t: Transfer) {
        guard !t.isActive else { return }
        items.removeAll { $0.id == t.id }
    }

    func clearFinished() {
        items.removeAll { !$0.isActive }
    }

    // MARK: Running

    private func startQueued() {
        guard let ssh else { return }
        var running = items.filter { $0.state == .running }.count
        for t in items where t.state == .queued && running < maxConcurrent {
            start(t, ssh: ssh)
            running += 1
        }
    }

    private func start(_ t: Transfer, ssh: SSH) {
        t.state = .running
        let worker = TransferWorker(ssh: ssh)
        t.worker = worker
        let kind = t.kind
        let local = t.localURL

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try worker.run(kind, local: local,
                    onTotal: { total in
                        DispatchQueue.main.async { MainActor.assumeIsolated { t.total = total } }
                    },
                    onBytes: { bytes in
                        DispatchQueue.main.async { MainActor.assumeIsolated { t.update(bytes: bytes) } }
                    })
            }
            let cancelled = worker.isCancelled
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(t, result, cancelled: cancelled) }
            }
        }
    }

    private func finish(_ t: Transfer, _ result: Result<Void, Error>, cancelled: Bool) {
        t.worker = nil
        if cancelled {
            t.state = .cancelled
        } else {
            switch result {
            case .success:
                t.state = .finished
                if let total = t.total { t.bytes = max(t.bytes, total) }
                if t.kind.isDownload {
                    if t.openWhenDone {
                        NSWorkspace.shared.open(t.localURL)
                    } else {
                        // Bounces the Downloads stack in the Dock, like a browser download.
                        DistributedNotificationCenter.default().post(
                            name: .init("com.apple.DownloadFileFinished"), object: t.localURL.path)
                    }
                } else {
                    onUploadFinished?(t.remoteDirectory)
                }
            case .failure(let error):
                t.state = .failed(error.localizedDescription)
            }
        }
        startQueued()
    }
}

/// Runs one transfer on a background thread. Bytes flow through this process so we can
/// count them: `ssh cat` / `ssh tar` on the remote side, a file or local `tar` on ours.
final class TransferWorker: @unchecked Sendable {
    let ssh: SSH
    private let lock = NSLock()
    private var processes: [Process] = []
    private var cancelled = false

    init(ssh: SSH) { self.ssh = ssh }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let procs: [Process] = lock.withLock {
            cancelled = true
            return processes
        }
        for p in procs where p.isRunning { p.terminate() }
    }

    private func terminateAll() {
        let procs = lock.withLock { processes }
        for p in procs where p.isRunning { p.terminate() }
    }

    private func launch(_ p: Process) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try p.run()
            processes.append(p)
        }
    }

    private func checkCancelled() throws {
        if isCancelled { throw CancellationError() }
    }

    func run(_ kind: TransferKind, local: URL,
             onTotal: @escaping (Int64) -> Void,
             onBytes: @escaping (Int64) -> Void) throws {
        switch kind {
        case .downloadFile(let remote, let size):
            onTotal(size)
            try downloadFile(remote, to: local, onBytes)
        case .downloadDirectory(let remote):
            try downloadDirectory(remote, to: local, onTotal: onTotal, onBytes)
        case .uploadFile(let remote):
            onTotal(LocalFiles.size(of: local))
            try uploadFile(local, to: remote, onBytes)
        case .uploadDirectory(let remote):
            onTotal(LocalFiles.size(of: local))
            try uploadDirectory(local, to: remote, onBytes)
        }
    }

    // MARK: Download

    private func downloadFile(_ remote: String, to local: URL, _ onBytes: @escaping (Int64) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: local)
        guard fm.createFile(atPath: local.path, contents: nil) else {
            throw SSHError("Couldn't create \(local.path)")
        }
        var success = false
        let dst = try FileHandle(forWritingTo: local)
        defer {
            try? dst.close()
            if !success { try? fm.removeItem(at: local) }
        }

        let p = ssh.makeProcess("cat -- \(shq(remote))")
        let out = Pipe()
        let err = try StderrCapture()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = err.handle
        try launch(p)

        let pumped = Result { try Self.pump(out.fileHandleForReading, to: dst, onBytes) }
        if case .failure = pumped { terminateAll() }
        p.waitUntilExit()
        try checkCancelled()
        if p.terminationStatus != 0 { throw SSHError(stderr: err.read(), status: p.terminationStatus) }
        try pumped.get()
        success = true
    }

    private func downloadDirectory(_ remote: String, to local: URL,
                                   onTotal: (Int64) -> Void, _ onBytes: @escaping (Int64) -> Void) throws {
        if let r = try? ssh.runSync("du -sbD -- \(shq(remote)) 2>/dev/null | cut -f1"),
           let total = Int64(String(decoding: r.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)) {
            onTotal(total)
        }
        try checkCancelled()

        let fm = FileManager.default
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? fm.removeItem(at: local) } }

        let remoteTar = ssh.makeProcess("tar -C \(shq(remote)) -cf - .")
        let fromRemote = Pipe()
        let remoteErr = try StderrCapture()
        remoteTar.standardInput = FileHandle.nullDevice
        remoteTar.standardOutput = fromRemote
        remoteTar.standardError = remoteErr.handle

        let localTar = Process()
        localTar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        localTar.arguments = ["-xf", "-", "-C", local.path]
        let toLocal = Pipe()
        let localErr = try StderrCapture()
        localTar.standardInput = toLocal
        localTar.standardOutput = FileHandle.nullDevice
        localTar.standardError = localErr.handle

        try launch(localTar)
        try launch(remoteTar)
        let pumped = Result { try Self.pump(fromRemote.fileHandleForReading, to: toLocal.fileHandleForWriting, onBytes) }
        try? toLocal.fileHandleForWriting.close()
        if case .failure = pumped { terminateAll() }
        remoteTar.waitUntilExit()
        localTar.waitUntilExit()
        try checkCancelled()
        // GNU tar exits 1 for "file changed as we read it" — data still arrived.
        if remoteTar.terminationStatus > 1 {
            throw SSHError(stderr: remoteErr.read(), status: remoteTar.terminationStatus)
        }
        if localTar.terminationStatus != 0 {
            throw SSHError(stderr: localErr.read(), status: localTar.terminationStatus)
        }
        try pumped.get()
        success = true
    }

    // MARK: Upload

    private func uploadFile(_ local: URL, to remote: String, _ onBytes: @escaping (Int64) -> Void) throws {
        let src = try FileHandle(forReadingFrom: local)
        defer { try? src.close() }

        let p = ssh.makeProcess("cat > \(shq(remote))")
        let toRemote = Pipe()
        let err = try StderrCapture()
        p.standardInput = toRemote
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err.handle
        try launch(p)

        let pumped = Result { try Self.pump(src, to: toRemote.fileHandleForWriting, onBytes) }
        try? toRemote.fileHandleForWriting.close()
        if case .failure = pumped { terminateAll() }
        p.waitUntilExit()
        try checkCancelled()
        if p.terminationStatus != 0 { throw SSHError(stderr: err.read(), status: p.terminationStatus) }
        try pumped.get()
    }

    private func uploadDirectory(_ local: URL, to remote: String, _ onBytes: @escaping (Int64) -> Void) throws {
        let localTar = Process()
        localTar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        localTar.arguments = ["-cf", "-", "--no-xattrs", "--no-mac-metadata", "--no-acls", "--no-fflags",
                              "-C", local.path, "."]
        var env = LoginEnvironment.shared
        env["COPYFILE_DISABLE"] = "1"  // no ._AppleDouble files
        localTar.environment = env
        let fromLocal = Pipe()
        let localErr = try StderrCapture()
        localTar.standardInput = FileHandle.nullDevice
        localTar.standardOutput = fromLocal
        localTar.standardError = localErr.handle

        let q = shq(remote)
        let remoteTar = ssh.makeProcess("mkdir -p -- \(q) && tar --warning=no-unknown-keyword -xf - -C \(q)")
        let toRemote = Pipe()
        let remoteErr = try StderrCapture()
        remoteTar.standardInput = toRemote
        remoteTar.standardOutput = FileHandle.nullDevice
        remoteTar.standardError = remoteErr.handle

        try launch(remoteTar)
        try launch(localTar)
        let pumped = Result { try Self.pump(fromLocal.fileHandleForReading, to: toRemote.fileHandleForWriting, onBytes) }
        try? toRemote.fileHandleForWriting.close()
        if case .failure = pumped { terminateAll() }
        localTar.waitUntilExit()
        remoteTar.waitUntilExit()
        try checkCancelled()
        if remoteTar.terminationStatus != 0 {
            throw SSHError(stderr: remoteErr.read(), status: remoteTar.terminationStatus)
        }
        if localTar.terminationStatus != 0 {
            throw SSHError(stderr: localErr.read(), status: localTar.terminationStatus)
        }
        try pumped.get()
    }

    // MARK: Plumbing

    private static func pump(_ src: FileHandle, to dst: FileHandle, _ onBytes: (Int64) -> Void) throws {
        var count: Int64 = 0
        var lastReport: UInt64 = 0
        while true {
            guard let chunk = try src.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            try dst.write(contentsOf: chunk)
            count += Int64(chunk.count)
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastReport > 100_000_000 {
                onBytes(count)
                lastReport = now
            }
        }
        onBytes(count)
    }
}
