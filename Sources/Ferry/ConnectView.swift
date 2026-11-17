import SwiftUI

struct ConnectView: View {
    @Bindable var model: BrowserModel
    @State private var hosts = SSHConfig.hosts()
    @State private var selected: String?
    @State private var typed = ""

    private var target: String {
        let t = typed.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? (selected ?? "") : t
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "ferry.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.tint)
                Text("Connect to a server")
                    .font(.title2.weight(.semibold))
                Text("Uses your SSH config, keys and agent — whatever works in Terminal works here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if hosts.isEmpty {
                Text("No hosts found in ~/.ssh/config")
                    .foregroundStyle(.secondary)
                    .frame(width: 380, height: 60)
            } else {
                List(hosts, id: \.self, selection: $selected) { host in
                    Label(host, systemImage: "server.rack")
                        .padding(.vertical, 2)
                }
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                    if let h = ids.first { connect(h) }
                }
                .frame(width: 380, height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .onChange(of: selected) { if selected != nil { typed = "" } }
            }

            HStack {
                TextField("Or type a host (user@host)", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { connect(target) }
                Button("Connect") { connect(target) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(target.isEmpty || model.connecting)
            }
            .frame(width: 380)

            Group {
                if model.connecting {
                    VStack(spacing: 4) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Connecting to \(model.connectingTo)…")
                        }
                        Text("The first connection can take a few seconds (e.g. through a cloud tunnel).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let err = model.connectError {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 480)
                }
            }
            .frame(minHeight: 40, alignment: .top)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            let last = UserDefaults.standard.string(forKey: "lastHost")
            if let last, hosts.contains(last) {
                selected = last
            } else if let last {
                typed = last
            } else {
                selected = hosts.first
            }
        }
    }

    private func connect(_ host: String) {
        guard !host.isEmpty, !model.connecting else { return }
        Task { await model.connect(to: host) }
    }
}
