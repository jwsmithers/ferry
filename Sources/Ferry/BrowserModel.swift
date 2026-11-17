import AppKit

@MainActor @Observable
final class BrowserModel {
    private(set) var ssh: SSH?
    var connecting = false
    var connectingTo = ""
    var connectError: String?

    private(set) var cwd = ""
    var pathText = ""
    private(set) var files: [RemoteFile] = []
    private(set) var isLoading = false
    var errorMessage: String?

    var showHidden = UserDefaults.standard.bool(forKey: "showHidden") {
        didSet { UserDefaults.standard.set(showHidden, forKey: "showHidden") }
    }

    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var navigationID = 0

    let transfers = TransferManager()

    init() {
        transfers.onUploadFinished = { [weak self] dir in
            guard let self, dir == self.cwd else { return }
            Task { await self.refresh() }
        }
    }

    var host: String? { ssh?.host }
    var isConnected: Bool { ssh != nil }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var visibleFiles: [RemoteFile] { showHidden ? files : files.filter { !$0.isHidden } }
    var hiddenCount: Int { files.count - visibleFiles.count }

    // MARK: Connection

    func connect(to rawHost: String) async {
        let host = rawHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !connecting else { return }
        connecting = true
        connectingTo = host
        connectError = nil
        defer { connecting = false }

        let ssh = SSH(host: host)
        do {
            var listing: (cwd: String, files: [RemoteFile])
            if let last = UserDefaults.standard.string(forKey: "lastPath.\(host)") {
                do {
                    listing = try await ssh.list(last)
                } catch let e as SSHError where !e.isConnectionError {
                    listing = try await ssh.list("")  // last folder is gone; start at home
                }
            } else {
                listing = try await ssh.list("")
            }
            UserDefaults.standard.set(host, forKey: "lastHost")
            self.ssh = ssh
            transfers.ssh = ssh
            backStack = []
            forwardStack = []
            errorMessage = nil
            apply(listing)
        } catch {
            connectError = error.localizedDescription
        }
    }

    func disconnect() {
        transfers.cancelAll()
        let old = ssh
        ssh = nil
        transfers.ssh = nil
        files = []
        cwd = ""
        pathText = ""
        errorMessage = nil
        if let old { DispatchQueue.global().async { old.closeMaster() } }
    }

    // MARK: Navigation

    func navigate(to path: String, recordHistory: Bool = true) async {
        guard let ssh else { return }
        navigationID += 1
        let id = navigationID
        isLoading = true
        do {
            let listing = try await ssh.list(path)
            guard id == navigationID else { return }
            if recordHistory && listing.cwd != cwd {
                backStack.append(cwd)
                forwardStack.removeAll()
            }
            errorMessage = nil
            apply(listing)
        } catch {
            guard id == navigationID else { return }
            errorMessage = error.localizedDescription
            pathText = cwd
        }
        isLoading = false
    }

    func refresh() async { await navigate(to: cwd, recordHistory: false) }
    func goUp() async { await navigate(to: RemotePath.parent(cwd)) }
    func goHome() async { await navigate(to: "") }

    func goBack() async {
        guard let target = backStack.popLast() else { return }
        forwardStack.append(cwd)
        await navigate(to: target, recordHistory: false)
    }

    func goForward() async {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(cwd)
        await navigate(to: target, recordHistory: false)
    }

    private func apply(_ listing: (cwd: String, files: [RemoteFile])) {
        cwd = listing.cwd
        pathText = listing.cwd
        files = listing.files
        if let host { UserDefaults.standard.set(cwd, forKey: "lastPath.\(host)") }
    }

    // MARK: File operations

    func open(_ items: [RemoteFile]) async {
        if items.count == 1, let only = items.first, only.isDirectory {
            await navigate(to: only.path)
            return
        }
        guard let host else { return }
        for f in items where !f.isDirectory && !f.isBrokenLink {
            transfers.openRemoteFile(f, host: host)
        }
    }

    func download(_ items: [RemoteFile], to dir: URL = LocalFiles.downloadsFolder) {
        for f in items where !f.isBrokenLink { transfers.download(f, to: dir) }
    }

    func upload(_ urls: [URL]) {
        for url in urls { transfers.upload(url, into: cwd) }
    }

    func makeFolder(named name: String) async {
        guard validName(name) else { return }
        await runAndRefresh("mkdir -- \(shq(RemotePath.join(cwd, name)))")
    }

    func rename(_ file: RemoteFile, to name: String) async {
        guard validName(name), name != file.name else { return }
        if files.contains(where: { $0.name == name }) {
            errorMessage = "“\(name)” already exists."
            return
        }
        let target = RemotePath.join(RemotePath.parent(file.path), name)
        await runAndRefresh("mv -- \(shq(file.path)) \(shq(target))")
    }

    func delete(_ items: [RemoteFile]) async {
        let paths = items.map(\.path).filter { $0 != "/" && !$0.isEmpty }
        guard !paths.isEmpty else { return }
        await runAndRefresh("rm -rf -- " + paths.map(shq).joined(separator: " "))
    }

    private func validName(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") {
            errorMessage = "“\(name)” isn't a valid name."
            return false
        }
        return true
    }

    private func runAndRefresh(_ command: String) async {
        guard let ssh else { return }
        var failure: String?
        do { try await ssh.check(command) } catch { failure = error.localizedDescription }
        await refresh()
        if let failure { errorMessage = failure }
    }
}
