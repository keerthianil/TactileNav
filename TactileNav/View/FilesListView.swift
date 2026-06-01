import SwiftUI
import UIKit
import TactileMapLogging

// MARK: - Files List View

struct FilesListView: View {
    @State private var files: [URL] = []
    @State private var showingDeleteAlert = false
    @State private var fileToDelete: URL?

    private let logger = CSVTouchLogger()

    var body: some View {
        List {
            if files.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("No log files yet")
                            .font(.headline)
                            .foregroundColor(.gray)
                        Text("Complete a map exploration session to generate data logs.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            } else {
                Section(header: Text("Saved Log Files")) {
                    ForEach(files, id: \.absoluteString) { file in
                        FileRowView(
                            file: file,
                            fileSize: logger.getFileSize(at: file),
                            onShare: { shareFile(file) },
                            onDelete: { confirmDelete(file) }
                        )
                    }
                }
                Section {
                    Button(role: .destructive) {
                        confirmDeleteAll()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Delete All Files")
                        }
                    }
                }
            }
        }
        .navigationTitle("Data Files")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshFiles() }
        .refreshable { refreshFiles() }
        .alert("Delete File?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let file = fileToDelete { deleteFile(file) }
            }
            Button("Cancel", role: .cancel) { fileToDelete = nil }
        } message: {
            if let file = fileToDelete {
                Text("Are you sure you want to delete \(file.lastPathComponent)?")
            }
        }
    }

    private func refreshFiles() {
        files = logger.getAllLogFiles()
    }

    private func shareFile(_ file: URL) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        logger.shareFile(at: file, from: root)
    }

    private func confirmDelete(_ file: URL) {
        fileToDelete = file
        showingDeleteAlert = true
    }

    private func confirmDeleteAll() {
        for file in files { _ = logger.deleteFile(at: file) }
        refreshFiles()
    }

    private func deleteFile(_ file: URL) {
        _ = logger.deleteFile(at: file)
        refreshFiles()
        fileToDelete = nil
    }
}

// MARK: - File Row View

struct FileRowView: View {
    let file: URL
    let fileSize: String
    let onShare: () -> Void
    let onDelete: () -> Void

    private var fileName: String { file.deletingPathExtension().lastPathComponent }

    /// Underscore tokens. The last two are date (yyyyMMdd) and time (HHmmss);
    /// everything before them is the human-readable map name.
    private var tokens: [Substring] { fileName.split(separator: "_") }

    private var mapName: String {
        guard tokens.count >= 3 else { return fileName }
        return tokens.dropLast(2).joined(separator: " ")
    }

    private var fileDate: String {
        guard tokens.count >= 2 else { return "Unknown date" }
        let dateStr = String(tokens[tokens.count - 2])
        let timeStr = String(tokens[tokens.count - 1])
        guard dateStr.count == 8, timeStr.count == 6 else { return "Unknown date" }
        let y = dateStr.prefix(4)
        let mo = dateStr.dropFirst(4).prefix(2)
        let d  = dateStr.dropFirst(6).prefix(2)
        let h  = timeStr.prefix(2)
        let mi = timeStr.dropFirst(2).prefix(2)
        let s  = timeStr.dropFirst(4).prefix(2)
        return "\(y)-\(mo)-\(d) \(h):\(mi):\(s)"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(mapName).font(.headline)
                Text(fileDate).font(.caption).foregroundColor(.secondary)
                Text(fileSize).font(.caption2).foregroundColor(.gray)
            }
            Spacer()
            HStack(spacing: 16) {
                Button { onShare() } label: {
                    Image(systemName: "square.and.arrow.up").foregroundColor(.blue)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Share \(mapName) log")

                Button { onDelete() } label: {
                    Image(systemName: "trash").foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(mapName) log")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mapName) log, \(fileDate), \(fileSize)")
        .accessibilityHint("Swipe up or down for share and delete actions")
    }
}
