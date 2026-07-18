import SwiftUI

// MARK: - File Manager View

/// A SwiftUI view that lists all CSV session log files and provides actions
/// to share, delete, or bulk-delete them.
public struct FileManagerView: View {

    @State private var files: [URL] = []
    @State private var showDeleteAll = false

    private let logger: CSVTouchLogger

    public init(logger: CSVTouchLogger) {
        self.logger = logger
    }

    public var body: some View {
        Group {
            if files.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .navigationTitle("Session Logs")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !files.isEmpty {
                    Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
        }
        .onAppear { refreshFiles() }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No session logs yet")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        List {
            ForEach(files, id: \.self) { url in
                FileRowView(
                    url: url,
                    fileSize: logger.getFileSize(at: url),
                    onShare: { shareFile(at: url) },
                    onDelete: { deleteFile(at: url) }
                )
            }

            Section {
                Button(role: .destructive) {
                    showDeleteAll = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Delete All")
                    }
                    .frame(maxWidth: .infinity)
                }
                .confirmationDialog(
                    "Delete all session logs?",
                    isPresented: $showDeleteAll,
                    titleVisibility: .visible
                ) {
                    Button("Delete All", role: .destructive) {
                        deleteAllFiles()
                    }
                }
            }
        }
        .refreshable { refreshFiles() }
    }

    // MARK: - Actions

    private func refreshFiles() {
        files = logger.getAllLogFiles()
    }

    private func deleteFile(at url: URL) {
        logger.deleteFile(at: url)
        refreshFiles()
    }

    private func deleteAllFiles() {
        for url in files {
            logger.deleteFile(at: url)
        }
        refreshFiles()
    }

    private func shareFile(at url: URL) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let rootVC = windowScene.windows.first?.rootViewController else {
            return
        }
        // Walk to the topmost presented controller.
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        logger.shareFile(at: url, from: topVC)
    }
}

// MARK: - File Row View

/// A single row showing the file name, size, and action buttons.
private struct FileRowView: View {

    let url: URL
    let fileSize: String
    let onShare: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirm = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                Text(fileSize)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                onShare()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .confirmationDialog(
                "Delete this log?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    onDelete()
                }
            }
        }
        .padding(.vertical, 4)
    }
}
