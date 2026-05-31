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

    private var fileDate: String {
        let parts = fileName.split(separator: "_")
        guard parts.count >= 3 else { return "Unknown date" }
        let dateStr = String(parts[1])
        let timeStr = String(parts[2])
        guard dateStr.count == 8, timeStr.count == 6 else { return "Unknown date" }
        let y = dateStr.prefix(4)
        let mo = dateStr.dropFirst(4).prefix(2)
        let d  = dateStr.dropFirst(6).prefix(2)
        let h  = timeStr.prefix(2)
        let mi = timeStr.dropFirst(2).prefix(2)
        let s  = timeStr.dropFirst(4).prefix(2)
        return "\(y)-\(mo)-\(d) \(h):\(mi):\(s)"
    }

    private var conditionName: String {
        if fileName.hasPrefix("PracticeNL")      { return "Practice – NL" }
        if fileName.hasPrefix("PracticeSpatial")  { return "Practice – Spatial" }
        if fileName.hasPrefix("PracticeIcons")    { return "Practice – Icons" }
        if fileName.hasPrefix("NL")               { return "Natural Language" }
        if fileName.hasPrefix("SpatialAudio")     { return "Spatialized Audio" }
        if fileName.hasPrefix("AuditoryIcons")    { return "Auditory Icons" }
        return "Session"
    }

    private var sessionVersion: String {
        if let idx = fileName.lastIndex(of: "v") { return String(fileName.suffix(from: idx)) }
        return ""
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conditionName).font(.headline)
                    if !sessionVersion.isEmpty {
                        Text(sessionVersion)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
                Text(fileDate).font(.caption).foregroundColor(.secondary)
                Text(fileSize).font(.caption2).foregroundColor(.gray)
            }
            Spacer()
            HStack(spacing: 16) {
                Button { onShare() } label: {
                    Image(systemName: "square.and.arrow.up").foregroundColor(.blue)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Share \(conditionName) log")

                Button { onDelete() } label: {
                    Image(systemName: "trash").foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(conditionName) log")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(conditionName) \(sessionVersion), \(fileDate), \(fileSize)")
        .accessibilityHint("Swipe up or down for share and delete actions")
    }
}
