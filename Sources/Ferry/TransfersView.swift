import SwiftUI

struct TransfersView: View {
    let manager: TransferManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers")
                    .font(.subheadline.weight(.semibold))
                if manager.activeCount > 0 {
                    Text("\(manager.activeCount) in progress")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear Finished") { manager.clearFinished() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(!manager.hasFinished)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(manager.items.reversed()) { t in
                        TransferRow(transfer: t, manager: manager)
                        Divider()
                    }
                }
            }
            .frame(height: min(CGFloat(manager.items.count) * 52, 182))
        }
        .background(.bar)
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    let manager: TransferManager

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.kind.isDownload ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if transfer.state == .running {
                    if let fraction = transfer.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var actions: some View {
        if transfer.isActive {
            Button { manager.cancel(transfer) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Cancel")
        } else {
            HStack(spacing: 6) {
                if transfer.state == .finished && transfer.kind.isDownload {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([transfer.localURL])
                    } label: { Image(systemName: "magnifyingglass.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                }
                Button { manager.remove(transfer) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove from list")
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = transfer.state { return true }
        return false
    }

    private var iconColor: Color {
        switch transfer.state {
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }

    private var detail: String {
        switch transfer.state {
        case .queued:
            return "Waiting…"
        case .running:
            var s = Format.bytes(transfer.bytes)
            if let total = transfer.total, total > 0 { s += " of \(Format.bytes(total))" }
            if transfer.bytesPerSecond > 0 { s += " · \(Format.bytes(Int64(transfer.bytesPerSecond)))/s" }
            return s
        case .finished:
            let size = Format.bytes(max(transfer.bytes, transfer.total ?? 0))
            if transfer.openWhenDone { return "\(size) · Opened" }
            return transfer.kind.isDownload
                ? "\(size) · Saved to \(transfer.localURL.deletingLastPathComponent().path)"
                : "\(size) · Uploaded to \(transfer.remoteDirectory)"
        case .cancelled:
            return "Cancelled"
        case .failed(let message):
            return message
        }
    }
}
