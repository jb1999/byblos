import SwiftUI

/// Model management view for downloading, removing, and benchmarking models.
struct ModelManagerView: View {
    @StateObject private var downloader = ModelDownloader()
    @AppStorage("selectedModel") private var selectedModel = "whisper-base"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(downloader.models) { model in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(model.displayName)
                                .font(.headline)
                            if model.id == selectedModel {
                                Text("Active")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.15))
                                    .cornerRadius(4)
                            }
                        }
                        Text(model.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(model.sizeLabel)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if let diskSize = model.diskSizeLabel {
                                Text("(\(diskSize) on disk)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    Spacer()

                    if model.isDownloaded {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Remove") {
                            downloader.removeModel(id: model.id)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.red)
                    } else if let progress = downloader.activeDownloads[model.id] {
                        VStack(spacing: 2) {
                            ProgressView(value: progress.fractionCompleted)
                                .frame(width: 80)
                            Text(progress.statusText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            downloader.cancelDownload(id: model.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    } else {
                        Button("Download") {
                            downloader.downloadModel(id: model.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }

            if let error = downloader.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
    }
}

// MARK: - Download Progress Tracking

struct DownloadProgress {
    var fractionCompleted: Double = 0.0
    var bytesWritten: Int64 = 0
    var totalBytes: Int64 = 0

    var statusText: String {
        if totalBytes > 0 {
            let mb = Double(bytesWritten) / 1_000_000.0
            let totalMb = Double(totalBytes) / 1_000_000.0
            return String(format: "%.0f / %.0f MB", mb, totalMb)
        }
        return String(format: "%.0f%%", fractionCompleted * 100)
    }
}

// MARK: - Model Downloader

@MainActor
final class ModelDownloader: NSObject, ObservableObject {
    @Published var models: [ModelEntry] = ModelEntry.defaults
    @Published var activeDownloads: [String: DownloadProgress] = [:]
    @Published var lastError: String?

    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var downloadSessions: [String: URLSession] = [:]
    private var downloadDelegates: [String: DownloadDelegate] = [:]

    static let modelsDirectory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Byblos/models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    override init() {
        super.init()
        refreshModelStates()
    }

    func refreshModelStates() {
        for i in models.indices {
            let filePath = Self.modelsDirectory.appendingPathComponent(models[i].fileName)
            let exists = FileManager.default.fileExists(atPath: filePath.path)
            models[i].isDownloaded = exists
            if exists {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath.path),
                   let size = attrs[.size] as? Int64
                {
                    models[i].diskSizeLabel = Self.formatFileSize(size)
                }
            } else {
                models[i].diskSizeLabel = nil
            }
        }
    }

    func downloadModel(id: String) {
        guard let model = models.first(where: { $0.id == id }),
              let url = URL(string: model.downloadURL)
        else {
            lastError = "Unknown model: \(id)"
            return
        }

        let destPath = Self.modelsDirectory.appendingPathComponent(model.fileName)
        if FileManager.default.fileExists(atPath: destPath.path) {
            Log.info("Model already exists: \(model.fileName)")
            refreshModelStates()
            return
        }

        lastError = nil
        activeDownloads[id] = DownloadProgress()

        let delegate = DownloadDelegate(modelId: id, downloader: self)
        downloadDelegates[id] = delegate

        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
        downloadSessions[id] = session

        let task = session.downloadTask(with: url)
        downloadTasks[id] = task
        task.resume()

        Log.info("Started downloading model: \(model.displayName) from \(model.downloadURL)")
    }

    func cancelDownload(id: String) {
        downloadTasks[id]?.cancel()
        cleanupDownload(id: id)
        Log.info("Cancelled download for model: \(id)")
    }

    func removeModel(id: String) {
        guard let model = models.first(where: { $0.id == id }) else { return }
        let filePath = Self.modelsDirectory.appendingPathComponent(model.fileName)
        do {
            try FileManager.default.removeItem(at: filePath)
            Log.info("Removed model: \(model.fileName)")
        } catch {
            Log.error("Failed to remove model \(model.fileName): \(error)")
            lastError = "Failed to remove: \(error.localizedDescription)"
        }
        refreshModelStates()
    }

    // Called by the delegate on completion.
    nonisolated func handleDownloadCompleted(modelId: String, location: URL?, error: (any Error)?) {
        Task { @MainActor in
            if let error {
                if (error as NSError).code != NSURLErrorCancelled {
                    self.lastError = "Download failed: \(error.localizedDescription)"
                    Log.error("Download failed for \(modelId): \(error)")
                }
                self.cleanupDownload(id: modelId)
                return
            }

            guard let location,
                  let model = self.models.first(where: { $0.id == modelId })
            else {
                self.lastError = "Download completed but no file received"
                self.cleanupDownload(id: modelId)
                return
            }

            let dest = Self.modelsDirectory.appendingPathComponent(model.fileName)
            do {
                // Remove existing file if any.
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: location, to: dest)
                Log.info("Downloaded model to: \(dest.path)")
            } catch {
                self.lastError = "Failed to save model: \(error.localizedDescription)"
                Log.error("Failed to move downloaded model: \(error)")
            }

            self.cleanupDownload(id: modelId)
            self.refreshModelStates()
        }
    }

    // Called by the delegate for progress updates.
    nonisolated func handleDownloadProgress(
        modelId: String, bytesWritten: Int64, totalBytes: Int64
    ) {
        Task { @MainActor in
            let fraction = totalBytes > 0 ? Double(bytesWritten) / Double(totalBytes) : 0
            self.activeDownloads[modelId] = DownloadProgress(
                fractionCompleted: fraction,
                bytesWritten: bytesWritten,
                totalBytes: totalBytes
            )
        }
    }

    private func cleanupDownload(id: String) {
        activeDownloads.removeValue(forKey: id)
        downloadTasks.removeValue(forKey: id)
        downloadSessions[id]?.invalidateAndCancel()
        downloadSessions.removeValue(forKey: id)
        downloadDelegates.removeValue(forKey: id)
    }

    static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - URLSession Download Delegate

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let modelId: String
    let downloader: ModelDownloader

    init(modelId: String, downloader: ModelDownloader) {
        self.modelId = modelId
        self.downloader = downloader
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        downloader.handleDownloadCompleted(modelId: modelId, location: location, error: nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            downloader.handleDownloadCompleted(modelId: modelId, location: nil, error: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        downloader.handleDownloadProgress(
            modelId: modelId,
            bytesWritten: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite
        )
    }
}

// MARK: - Model Entry

struct ModelEntry: Identifiable {
    let id: String
    let displayName: String
    let description: String
    let sizeLabel: String
    let downloadURL: String
    let fileName: String
    var isDownloaded: Bool
    var diskSizeLabel: String?

    static let defaults: [ModelEntry] = [
        ModelEntry(
            id: "whisper-tiny",
            displayName: "Whisper Tiny",
            description: "Fastest, lower accuracy. Good for quick notes.",
            sizeLabel: "75 MB",
            downloadURL:
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin",
            fileName: "ggml-tiny.en.bin",
            isDownloaded: false
        ),
        ModelEntry(
            id: "whisper-base",
            displayName: "Whisper Base",
            description: "Good balance of speed and accuracy.",
            sizeLabel: "142 MB",
            downloadURL:
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin",
            fileName: "ggml-base.en.bin",
            isDownloaded: false
        ),
        ModelEntry(
            id: "whisper-small",
            displayName: "Whisper Small",
            description: "Higher accuracy, moderate speed.",
            sizeLabel: "466 MB",
            downloadURL:
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin",
            fileName: "ggml-small.en.bin",
            isDownloaded: false
        ),
        ModelEntry(
            id: "whisper-medium",
            displayName: "Whisper Medium",
            description: "High accuracy, slower on older hardware.",
            sizeLabel: "1.5 GB",
            downloadURL:
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin",
            fileName: "ggml-medium.en.bin",
            isDownloaded: false
        ),
        ModelEntry(
            id: "moonshine-tiny",
            displayName: "Moonshine Tiny",
            description: "Ultra-fast, optimized for short utterances.",
            sizeLabel: "60 MB",
            downloadURL: "",
            fileName: "moonshine-tiny.bin",
            isDownloaded: false
        ),
    ]
}
