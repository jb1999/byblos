import AppKit
import SwiftUI

/// Observable model for streaming transcription text.
@MainActor
class OverlayState: ObservableObject {
    static let shared = OverlayState()
    @Published var partialText: String = ""
    @Published var isProcessing: Bool = false
    @Published var recordingStartDate: Date = Date()

    var wordCount: Int {
        guard !partialText.isEmpty else { return 0 }
        return partialText.split(separator: " ").count
    }
}

/// A floating pill overlay that shows recording state and streaming text.
/// Positioned at the bottom center of the screen (like macOS dictation).
class OverlayWindow: NSPanel {
    private let state = OverlayState.shared
    private let overlayWidth: CGFloat = 500
    private let overlayMinHeight: CGFloat = 50
    private let overlayMaxHeight: CGFloat = 140

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 50),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true

        let hostView = NSHostingView(rootView: OverlayContent().environmentObject(state))
        hostView.translatesAutoresizingMaskIntoConstraints = false
        contentView = hostView
    }

    func show() {
        state.partialText = ""
        state.isProcessing = false
        state.recordingStartDate = Date()
        positionAtBottomCenter()
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    func updatePartialText(_ text: String) {
        state.partialText = text
        // Reposition to keep bottom-center as content grows.
        positionAtBottomCenter()
    }

    func setProcessing(_ processing: Bool) {
        state.isProcessing = processing
    }

    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowSize = frame.size
        let x = screenFrame.origin.x + (screenFrame.width - windowSize.width) / 2
        // 60pt above the bottom of the visible area (above the Dock).
        let y = screenFrame.origin.y + 60
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct OverlayContent: View {
    @EnvironmentObject var state: OverlayState
    @State private var animationPhase: CGFloat = 0
    @State private var spinnerRotation: Double = 0
    @State private var elapsedSeconds: Int = 0
    @State private var elapsedTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top bar: recording indicator + stats
            HStack(spacing: 8) {
                if state.isProcessing {
                    // Spinner for transcribing state
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .rotationEffect(.degrees(spinnerRotation))
                        .onAppear {
                            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                                spinnerRotation = 360
                            }
                        }

                    Text("Transcribing...")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .opacity(0.5 + 0.5 * Foundation.sin(Double(animationPhase)))

                    if state.partialText.isEmpty {
                        // Waveform bars when no text yet
                        HStack(spacing: 2) {
                            ForEach(0..<12, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color.white.opacity(0.7))
                                    .frame(width: 3, height: 4 + CGFloat.random(in: 0...14))
                            }
                        }
                        Text("Listening...")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        Text("Listening...")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                Spacer()

                // Word count + duration indicator
                if state.wordCount > 0 || elapsedSeconds > 0 {
                    Text(statsText)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                        .monospacedDigit()
                }
            }

            // Streaming partial text with scroll
            if !state.partialText.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(state.partialText)
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("transcriptionText")
                    }
                    .frame(maxHeight: 90)
                    .onChange(of: state.partialText) { _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("transcriptionText", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .onAppear {
            elapsedSeconds = 0
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: true)) {
                animationPhase = .pi
            }
            startElapsedTimer()
        }
        .onDisappear {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
        }
    }

    private var statsText: String {
        var parts: [String] = []
        if state.wordCount > 0 {
            parts.append("\(state.wordCount) word\(state.wordCount == 1 ? "" : "s")")
        }
        if elapsedSeconds > 0 {
            parts.append("\(elapsedSeconds)s")
        }
        return parts.joined(separator: " · ")
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                elapsedSeconds = Int(Date().timeIntervalSince(state.recordingStartDate))
            }
        }
    }
}
