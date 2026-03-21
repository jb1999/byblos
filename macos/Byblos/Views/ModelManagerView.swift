import SwiftUI

/// Model management view for downloading, removing, and benchmarking models.
struct ModelManagerView: View {
    @State private var models: [ModelEntry] = ModelEntry.defaults
    @State private var downloadingModel: String?

    var body: some View {
        List(models) { model in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.headline)
                    Text(model.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.sizeLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if model.isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Remove") {
                        // TODO: delete model
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.red)
                } else if downloadingModel == model.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Download") {
                        downloadingModel = model.id
                        // TODO: trigger download via core
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct ModelEntry: Identifiable {
    let id: String
    let displayName: String
    let description: String
    let sizeLabel: String
    var isDownloaded: Bool

    static let defaults: [ModelEntry] = [
        ModelEntry(
            id: "whisper-tiny",
            displayName: "Whisper Tiny",
            description: "Fastest, lower accuracy. Good for quick notes.",
            sizeLabel: "75 MB",
            isDownloaded: false
        ),
        ModelEntry(
            id: "whisper-base",
            displayName: "Whisper Base",
            description: "Good balance of speed and accuracy.",
            sizeLabel: "142 MB",
            isDownloaded: false
        ),
        ModelEntry(
            id: "whisper-small",
            displayName: "Whisper Small",
            description: "Higher accuracy, moderate speed.",
            sizeLabel: "466 MB",
            isDownloaded: false
        ),
        ModelEntry(
            id: "whisper-medium",
            displayName: "Whisper Medium",
            description: "High accuracy, slower on older hardware.",
            sizeLabel: "1.5 GB",
            isDownloaded: false
        ),
        ModelEntry(
            id: "moonshine-tiny",
            displayName: "Moonshine Tiny",
            description: "Ultra-fast, optimized for short utterances.",
            sizeLabel: "60 MB",
            isDownloaded: false
        ),
    ]
}
