import SwiftUI

struct MenuBarView: View {
    @Binding var isRecording: Bool
    var onToggleRecording: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    @State private var selectedModel = "whisper-base"

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Byblos")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(isRecording ? Color.red : Color.green)
                    .frame(width: 8, height: 8)
                Text(isRecording ? "Recording" : "Ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Model picker
            HStack {
                Text("Model")
                    .font(.subheadline)
                Spacer()
                Picker("", selection: $selectedModel) {
                    Text("Whisper Tiny").tag("whisper-tiny")
                    Text("Whisper Base").tag("whisper-base")
                    Text("Whisper Small").tag("whisper-small")
                    Text("Whisper Medium").tag("whisper-medium")
                }
                .labelsHidden()
                .frame(width: 160)
            }

            // Record button
            Button(action: onToggleRecording) {
                HStack {
                    Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title2)
                    Text(isRecording ? "Stop" : "Start Recording")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(isRecording ? .red : .accentColor)

            Text("Hold ⌥ (Option) to record")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            // Footer
            HStack {
                Button("Settings...", action: onOpenSettings)
                    .buttonStyle(.plain)
                    .font(.caption)
                Spacer()
                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
