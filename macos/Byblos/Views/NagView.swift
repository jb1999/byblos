import AppKit
import SwiftUI

// MARK: - Nag Logic

@MainActor
final class NagManager {
    static let shared = NagManager()

    private let totalTranscriptionsKey = "totalTranscriptions"
    private let nagDismissedDateKey = "nagDismissedDate"
    private let nagThreshold = 50
    private let nagCooldownDays = 7

    private var nagPanel: NSPanel?

    private init() {}

    /// Increment the transcription counter and check whether to show the nag.
    func recordTranscription() {
        let count = UserDefaults.standard.integer(forKey: totalTranscriptionsKey) + 1
        UserDefaults.standard.set(count, forKey: totalTranscriptionsKey)

        if shouldShowNag(count: count) {
            showNag(count: count)
        }
    }

    private func shouldShowNag(count: Int) -> Bool {
        // Never nag if licensed.
        if LicenseService.shared.isLicensed { return false }

        // Only nag at multiples of the threshold.
        guard count > 0, count % nagThreshold == 0 else { return false }

        // Don't nag more than once per week.
        if let dismissed = UserDefaults.standard.object(forKey: nagDismissedDateKey) as? Date {
            let daysSince = Calendar.current.dateComponents([.day], from: dismissed, to: Date()).day ?? 0
            if daysSince < nagCooldownDays {
                return false
            }
        }

        return true
    }

    private func showNag(count: Int) {
        guard nagPanel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Byblos"
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.center()
        panel.isReleasedWhenClosed = false

        let nagView = NagView(count: count) { [weak self] in
            self?.dismissNag()
        }

        panel.contentView = NSHostingView(rootView: nagView)
        panel.makeKeyAndOrderFront(nil)
        nagPanel = panel

        Log.info("Nag shown at \(count) transcriptions")
    }

    private func dismissNag() {
        UserDefaults.standard.set(Date(), forKey: nagDismissedDateKey)
        nagPanel?.close()
        nagPanel = nil
    }
}

// MARK: - NagView

struct NagView: View {
    let count: Int
    let onDismiss: @MainActor () -> Void

    @State private var licenseKey = ""
    @State private var isActivating = false
    @State private var showThankYou = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text("You've transcribed \(count) times with Byblos!")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("If you find it useful, consider supporting development with an annual license.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Link("Buy Annual License \u{2192}", destination: URL(string: "https://byblos.im/support")!)
                .font(.callout)

            Divider()

            if showThankYou {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.green)
                    Text("Thank you for supporting Byblos!")
                        .font(.headline)
                        .foregroundStyle(.green)
                    if let days = LicenseService.shared.daysRemaining {
                        Text("License valid for \(days) days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onAppear {
                    // Auto-dismiss after 2 seconds.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        onDismiss()
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Text("Already have a key?")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("Paste your license key", text: $licenseKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 250)

                        Button(isActivating ? "Verifying..." : "Activate") {
                            activateKey()
                        }
                        .disabled(licenseKey.trimmingCharacters(in: .whitespaces).isEmpty || isActivating)
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Button("Maybe Later") {
                onDismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
        }
        .padding(24)
        .frame(width: 420)
    }

    private func activateKey() {
        let key = licenseKey.trimmingCharacters(in: .whitespaces)
        isActivating = true
        errorMessage = nil

        Task {
            let success = await LicenseService.shared.activate(key: key)
            isActivating = false

            if success {
                showThankYou = true
            } else {
                errorMessage = LicenseService.shared.lastError ?? "Activation failed. Check your key and try again."
            }
        }
    }
}
