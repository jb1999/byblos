import AppKit
import SwiftUI

/// A small floating pill overlay that appears near the cursor during recording.
class OverlayWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
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

        contentView = NSHostingView(rootView: OverlayContent())
    }

    func show() {
        // Position near the mouse cursor.
        let mouseLocation = NSEvent.mouseLocation
        let origin = NSPoint(
            x: mouseLocation.x - frame.width / 2,
            y: mouseLocation.y + 20
        )
        setFrameOrigin(origin)
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}

struct OverlayContent: View {
    @State private var animationPhase: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            // Animated recording indicator
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(0.5 + 0.5 * Foundation.sin(Double(animationPhase)))

            // Waveform visualization placeholder
            HStack(spacing: 2) {
                ForEach(0..<12, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.8))
                        .frame(
                            width: 3,
                            height: 4 + CGFloat.random(in: 0...16)
                        )
                }
            }

            Text("Listening...")
                .font(.caption)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 22)
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
