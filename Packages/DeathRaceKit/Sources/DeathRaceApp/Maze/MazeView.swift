import Foundation
import LegendsUI
import SFTPKit
import SwiftUI

extension URL {
    /// Whether this file URL names a folder, asked of the filesystem rather than guessed
    /// from a trailing slash: Maze moves files, so a dropped folder is set aside.
    fileprivate var isDirectoryOnDisk: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

/// Maze: this Mac's folder beside the host's, with the transfers between them along the bottom.
struct MazeView: View {
    let model: MazeModel

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            Rectangle().fill(model.palette.line).frame(height: 1)
            HStack(spacing: 0) {
                MazePane(model: model, side: .local)
                Rectangle().fill(model.palette.line).frame(width: 1)
                MazePane(model: model, side: .remote)
            }
            Rectangle().fill(model.palette.line).frame(height: 1)
            MazeTransferStrip(model: model)
        }
        .background(model.palette.ground)
        .environment(\.legends, model.palette)
        .preferredColorScheme(model.palette.isLight ? .light : .dark)
        .frame(minWidth: 900, minHeight: 560)
        .task { await model.start() }
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            Text("MAZE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(model.palette.inkMuted)
            Text("·").foregroundStyle(model.palette.inkFaint)
            Text(model.hostName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.palette.ink)
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if let problem = model.problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(model.palette.danger)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .frame(height: 46)
    }
}

/// One side of Maze: a path bar, the rows, and the button that moves a file the other way.
private struct MazePane: View {
    let model: MazeModel
    let side: MazeModel.Side

    private var isLocal: Bool { side == .local }
    private var title: String { isLocal ? "THIS MAC" : model.hostName.uppercased() }
    private var path: String { isLocal ? model.localPath : model.remotePath }
    private var rows: [FileEntry] { isLocal ? model.localRows : model.remoteRows }
    private var selected: String? { isLocal ? model.localSelected : model.remoteSelected }

    var body: some View {
        takingDrops(pane)
    }

    private var pane: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(model.palette.line).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        dragging(MazeRow(model: model, row: row, isSelected: row.name == selected), row)
                            .onTapGesture(count: 2) { Task { await model.open(row, on: side) } }
                            .onTapGesture { select(row.name) }
                    }
                }
            }
            .background(model.palette.groundDeep)
            Rectangle().fill(model.palette.line).frame(height: 1)
            footer
        }
        .frame(maxWidth: .infinity)
    }

    /// A file row can be dragged to the other pane: this Mac's as its file URL (so an in-app
    /// drag and a Finder drop are the same thing on the far side), the host's as its path.
    /// A folder isn't draggable — Maze moves files.
    @ViewBuilder
    private func dragging(_ view: some View, _ row: FileEntry) -> some View {
        if row.isDirectory {
            view
        } else if isLocal {
            view.draggable(URL(fileURLWithPath: Listing.join(model.localPath, row.name)))
        } else {
            view.draggable(Listing.join(model.remotePath, row.name))
        }
    }

    /// What this whole pane takes: files on the host's side, the host's own paths on this
    /// Mac's. On the pane rather than its rows, so the empty space below them takes a drop too.
    @ViewBuilder
    private func takingDrops(_ view: some View) -> some View {
        if isLocal {
            view.dropDestination(for: String.self) { paths, _ in
                Task { await model.download(dropped: paths) }
                return true
            }
        } else {
            view.dropDestination(for: URL.self) { urls, _ in
                // `isFileURL` first: a dragged web link is a URL too, and its *path* reads as
                // an absolute local path ("https://x/Users/me/.ssh/id_ed25519" → that file),
                // so without this a page could offer a link that uploads a private key.
                let files = urls.filter { $0.isFileURL && !$0.isDirectoryOnDisk }
                    .map { $0.path(percentEncoded: false) }
                Task {
                    await model.upload(dropped: files)
                    if files.count != urls.count { model.problem = "Maze moves files, not folders." }
                }
                return !files.isEmpty
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(model.palette.inkMuted)
            Spacer()
            Button("Up") { Task { await model.goUp(on: side) } }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(model.palette.accent)
                .disabled(path == "/")
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .overlay(alignment: .bottom) {
            Text(path)
                .font(.system(size: 10))
                .foregroundStyle(model.palette.inkFaint)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, 12)
                .offset(y: 14)
        }
        .padding(.bottom, 16)
    }

    private var footer: some View {
        HStack {
            if isLocal {
                Button("Upload →") { Task { await model.upload() } }
                    .disabled(selected == nil)
            } else {
                Button("← Download") { Task { await model.download() } }
                    .disabled(selected == nil)
            }
            Spacer()
            Text("\(rows.count) items")
                .font(.system(size: 10))
                .foregroundStyle(model.palette.inkFaint)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func select(_ name: String) {
        if isLocal {
            model.localSelected = name
        } else {
            model.remoteSelected = name
        }
    }
}

/// One file or folder.
private struct MazeRow: View {
    let model: MazeModel
    let row: FileEntry
    let isSelected: Bool

    private var symbol: String {
        switch row.kind {
        case .directory: return "folder"
        case .symlink: return "link"
        case .file: return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(row.isDirectory ? model.palette.accent : model.palette.inkFaint)
                .frame(width: 14)
            Text(row.name)
                .font(.system(size: 12))
                .foregroundStyle(model.palette.ink)
                .lineLimit(1)
            Spacer()
            if !row.isDirectory {
                Text(Listing.sizeText(row.size))
                    .font(.system(size: 10))
                    .foregroundStyle(model.palette.inkFaint)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(isSelected ? model.palette.surfaceHover : .clear)
        .contentShape(Rectangle())
    }
}

/// The transfers, newest last, each with its gradient bar.
private struct MazeTransferStrip: View {
    let model: MazeModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TRANSFERS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(model.palette.inkMuted)
                Spacer()
                if model.transfers.transfers.contains(where: { !$0.isActive }) {
                    Button("Clear") { model.clearCompletedTransfers() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(model.palette.accent)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 26)
            if model.transfers.transfers.isEmpty {
                Text("Pick a file and press Upload or Download.")
                    .font(.system(size: 11))
                    .foregroundStyle(model.palette.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.transfers.transfers) { transfer in
                            MazeTransferRow(model: model, transfer: transfer)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 108)
            }
        }
        .background(model.palette.groundDeep)
    }
}

private struct MazeTransferRow: View {
    let model: MazeModel
    let transfer: Transfer

    private var arrow: String { transfer.direction == .upload ? "↑" : "↓" }

    private var state: String {
        switch transfer.state {
        case .queued: return "waiting"
        case .transferring(let done, let total):
            return "\(Listing.sizeText(done)) of \(Listing.sizeText(total))"
        case .finished: return "done"
        case .failed(let why): return why
        case .cancelled: return "cancelled"
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text(arrow).foregroundStyle(model.palette.accent)
                Text(transfer.name)
                    .foregroundStyle(model.palette.ink)
                    .lineLimit(1)
                Spacer()
                Text(state)
                    .foregroundStyle(stateColor)
                    .lineLimit(1)
                if transfer.isActive {
                    Button("Stop") { model.cancel(transfer.id) }
                        .buttonStyle(.plain)
                        .foregroundStyle(model.palette.inkMuted)
                }
            }
            .font(.system(size: 11))
            TransferBar(fraction: transfer.fraction)
        }
    }

    private var stateColor: Color {
        switch transfer.state {
        case .failed: return model.palette.danger
        case .finished: return model.palette.accent
        default: return model.palette.inkFaint
        }
    }
}
