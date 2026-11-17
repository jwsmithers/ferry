import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @Bindable var model: BrowserModel

    @State private var selection = Set<RemoteFile.ID>()
    @State private var sortOrder = [KeyPathComparator(\RemoteFile.name)]
    @State private var dropTargeted = false

    @State private var namePrompt: NamePrompt?
    @State private var nameText = ""
    @State private var pendingDelete: [RemoteFile] = []
    @State private var pendingUpload: [URL] = []

    enum NamePrompt {
        case newFolder
        case rename(RemoteFile)
    }

    // MARK: Derived

    private var sortedFiles: [RemoteFile] {
        let files = model.visibleFiles
        let sorted: [RemoteFile]
        if let c = sortOrder.first, c.keyPath == \RemoteFile.name as PartialKeyPath<RemoteFile> {
            // Finder-style name order: case-insensitive, "file2" before "file10".
            sorted = files.sorted {
                let r = $0.name.localizedStandardCompare($1.name)
                return c.order == .forward ? r == .orderedAscending : r == .orderedDescending
            }
        } else {
            sorted = files.sorted(using: sortOrder)
        }
        return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
    }

    private var selectedFiles: [RemoteFile] {
        model.files.filter { selection.contains($0.id) }
    }

    private func files(for ids: Set<RemoteFile.ID>) -> [RemoteFile] {
        model.files.filter { ids.contains($0.id) }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            if let error = model.errorMessage { errorBanner(error) }
            fileTable
            if !model.transfers.items.isEmpty {
                Divider()
                TransfersView(manager: model.transfers)
            }
            Divider()
            statusBar
        }
        .navigationTitle(model.host ?? "Ferry")
        .toolbar { toolbar }
        .onChange(of: model.cwd) { selection.removeAll() }
        .alert(promptTitle, isPresented: promptShown) {
            TextField("Name", text: $nameText)
            Button(promptButton) { submitPrompt() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: deleteShown, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let items = pendingDelete
                Task { await model.delete(items) }
            }
        } message: {
            Text("This permanently deletes them from the server. It can't be undone.")
        }
        .confirmationDialog(replaceTitle, isPresented: uploadShown, titleVisibility: .visible) {
            Button("Replace") { model.upload(pendingUpload) }
            Button("Skip Existing") {
                let existing = Set(model.files.map(\.name))
                model.upload(pendingUpload.filter { !existing.contains($0.lastPathComponent) })
            }
        } message: {
            Text("Uploaded files overwrite the ones on the server; uploaded folders merge into existing ones.")
        }
    }

    // MARK: Pieces

    private var pathBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            TextField("Path", text: $model.pathText)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .onSubmit { Task { await model.navigate(to: model.pathText) } }
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
    }

    private var fileTable: some View {
        Table(sortedFiles, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { file in
                HStack(spacing: 6) {
                    Image(nsImage: FileIcons.icon(for: file))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .strikethrough(file.isBrokenLink)
                }
                .opacity(file.isHidden ? 0.6 : 1)
                .help(file.isBrokenLink ? "Broken symbolic link" : file.path)
            }
            TableColumn("Size", value: \.size) { file in
                Text(file.isDirectory ? "—" : Format.bytes(file.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 90, max: 140)
            TableColumn("Modified", value: \.modified) { file in
                Text(file.modified.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170, max: 240)
        }
        .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
            contextMenu(for: files(for: ids))
        } primaryAction: { ids in
            let items = files(for: ids)
            Task { await model.open(items) }
        }
        .onDeleteCommand { requestDelete(selectedFiles) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadFileURLs(providers) { requestUpload($0) }
            return true
        }
        .overlay {
            if dropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                    Label("Upload to \(model.cwd)", systemImage: "arrow.up.doc")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                .padding(6)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for items: [RemoteFile]) -> some View {
        if items.isEmpty {
            Button("New Folder…") { promptNewFolder() }
            Button("Upload…") { chooseUpload() }
            Divider()
            Button("Refresh") { Task { await model.refresh() } }
        } else {
            Button(items.count == 1 && items[0].isDirectory ? "Open Folder" : "Open") {
                Task { await model.open(items) }
            }
            Divider()
            Button("Download to Downloads") { model.download(items) }
            Button("Download To…") { chooseDownload(items) }
            Divider()
            if items.count == 1 {
                Button("Rename…") { promptRename(items[0]) }
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Delete…", role: .destructive) { requestDelete(items) }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 4) {
            Text("\(model.visibleFiles.count) items")
            if !selection.isEmpty { Text("· \(selection.count) selected") }
            if model.hiddenCount > 0 && !model.showHidden { Text("· \(model.hiddenCount) hidden") }
            Spacer()
            Text("Drop files here to upload")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { Task { await model.goBack() } } label: { Label("Back", systemImage: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBack)
                .help("Back (⌘[)")
            Button { Task { await model.goForward() } } label: { Label("Forward", systemImage: "chevron.right") }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canGoForward)
                .help("Forward (⌘])")
            Button { Task { await model.goUp() } } label: { Label("Enclosing Folder", systemImage: "arrow.up") }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.cwd == "/")
                .help("Enclosing folder (⌘↑)")
            Button { Task { await model.goHome() } } label: { Label("Home", systemImage: "house") }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .help("Home folder (⇧⌘H)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh (⌘R)")
            Toggle(isOn: $model.showHidden) { Label("Hidden Files", systemImage: model.showHidden ? "eye" : "eye.slash") }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .help("Show hidden files (⇧⌘.)")
            Button { promptNewFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("New folder (⇧⌘N)")
            Button { chooseUpload() } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                .keyboardShortcut("u", modifiers: .command)
                .help("Upload files or folders here (⌘U)")
            Button { model.download(selectedFiles) } label: { Label("Download", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(selection.isEmpty)
                .help("Download selection to Downloads (⌘D)")
            Button { model.disconnect() } label: { Label("Disconnect", systemImage: "eject") }
                .help("Disconnect")
        }
    }

    // MARK: Actions

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Upload to \(model.cwd)"
        if panel.runModal() == .OK { requestUpload(panel.urls) }
    }

    private func chooseDownload(_ items: [RemoteFile]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        if let last = UserDefaults.standard.url(forKey: "lastDownloadDir") { panel.directoryURL = last }
        if panel.runModal() == .OK, let dir = panel.url {
            UserDefaults.standard.set(dir, forKey: "lastDownloadDir")
            model.download(items, to: dir)
        }
    }

    private func requestUpload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let existing = Set(model.files.map(\.name))
        if urls.contains(where: { existing.contains($0.lastPathComponent) }) {
            pendingUpload = urls
        } else {
            model.upload(urls)
        }
    }

    private func requestDelete(_ items: [RemoteFile]) {
        guard !items.isEmpty else { return }
        pendingDelete = items
    }

    private func promptNewFolder() {
        nameText = "untitled folder"
        namePrompt = .newFolder
    }

    private func promptRename(_ file: RemoteFile) {
        nameText = file.name
        namePrompt = .rename(file)
    }

    private func submitPrompt() {
        let name = nameText.trimmingCharacters(in: .whitespaces)
        switch namePrompt {
        case .newFolder: Task { await model.makeFolder(named: name) }
        case .rename(let file): Task { await model.rename(file, to: name) }
        case nil: break
        }
        namePrompt = nil
    }

    private func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.withLock { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    // MARK: Dialog plumbing

    private var promptShown: Binding<Bool> {
        Binding(get: { namePrompt != nil }, set: { if !$0 { namePrompt = nil } })
    }

    private var promptTitle: String {
        if case .rename(let f) = namePrompt { return "Rename “\(f.name)”" }
        return "New Folder"
    }

    private var promptButton: String {
        if case .rename = namePrompt { return "Rename" }
        return "Create"
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete “\(pendingDelete[0].name)”?" : "Delete \(pendingDelete.count) items?"
    }

    private var uploadShown: Binding<Bool> {
        Binding(get: { !pendingUpload.isEmpty }, set: { if !$0 { pendingUpload = [] } })
    }

    private var replaceTitle: String {
        let existing = Set(model.files.map(\.name))
        let clashes = pendingUpload.filter { existing.contains($0.lastPathComponent) }
        return clashes.count == 1
            ? "“\(clashes[0].lastPathComponent)” already exists here. Replace it?"
            : "\(clashes.count) items already exist here. Replace them?"
    }
}
