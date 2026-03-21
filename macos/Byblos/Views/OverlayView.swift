import AppKit
import SwiftUI

/// Observable model for streaming transcription text.
@MainActor
class OverlayState: ObservableObject {
    static let shared = OverlayState()
    @Published var partialText: String = ""
    @Published var isProcessing: Bool = false
}

/// A floating pill overlay that shows recording state and streaming text.
class OverlayWindow: NSPanel {
    private let state = OverlayState.shared

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
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

        contentView = NSHostingView(rootView: OverlayContent().environmentObject(state))
    }

    func show() {
        let mouseLocation = NSEvent.mouseLocation
        let origin = NSPoint(
            x: mouseLocation.x - frame.width / 2,
            y: mouseLocation.y + 30
        )
        setFrameOrigin(origin)
        state.partialText = ""
        state.isProcessing = false
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    func updatePartialText(_ text: String) {
        state.partialText = text
    }

    func setProcessing(_ processing: Bool) {
        state.isProcessing = processing
    }
}

struct OverlayContent: View {
    @EnvironmentObject var state: OverlayState
    @State private var animationPhase: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top bar: recording indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(state.isProcessing ? Color.orange : Color.red)
                    .frame(width: 10, height: 10)
                    .opacity(state.isProcessing ? 1.0 : 0.5 + 0.5 * Foundation.sin(Double(animationPhase)))

                if state.isProcessing {
                    Text("Transcribing...")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                } else if state.partialText.isEmpty {
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

                Spacer()
            }

            // Streaming partial text
            if !state.partialText.isEmpty {
                Text(state.partialText)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: 200, maxWidth: 400)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: true)) {
                animationPhase = .pi
            }
        }
    }
}
