import AppKit
import SwiftUI

// MARK: - Nag Logic

@MainActor
final class NagManager {
    static let shared = NagManager()

    private let totalTranscriptionsKey = "totalTranscriptions"
    private let licenseKeyKey = "licenseKey"
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
        // Never nag if licensed (and not expired).
        if isLicensed { return false }

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

    /// Validate license key format: BYBL-XXXX-XXXX-XXXX (4 groups of 4 alphanumeric chars).
    func validateKeyFormat(_ key: String) -> Bool {
        let pattern = "^BYBL-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}$"
        return key.range(of: pattern, options: .regularExpression) != nil
    }

    private let licenseActivationDateKey = "licenseActivationDate"
    private let licenseDurationDays = 365

    func storeLicenseKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: licenseKeyKey)
        UserDefaults.standard.set(Date(), forKey: licenseActivationDateKey)
        Log.info("License key stored (valid for 1 year)")
    }

    var isLicensed: Bool {
        guard let key = UserDefaults.standard.string(forKey: licenseKeyKey),
              validateKeyFormat(key) else { return false }
        // Check if license has expired (1 year).
        if let activationDate = UserDefaults.standard.object(forKey: licenseActivationDateKey) as? Date {
            let daysSince = Calendar.current.dateComponents([.day], from: activationDate, to: Date()).day ?? 0
            if daysSince > licenseDurationDays {
                Log.info("License expired after \(daysSince) days")
                return false
            }
        }
        return true
    }

    var licenseDaysRemaining: Int? {
        guard isLicensed,
              let activationDate = UserDefaults.standard.object(forKey: licenseActivationDateKey) as? Date
        else { return nil }
        let daysSince = Calendar.current.dateComponents([.day], from: activationDate, to: Date()).day ?? 0
        return max(0, licenseDurationDays - daysSince)
    }

    private func showNag(count: Int) {
        guard nagPanel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 280),
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
        } onLicenseValidated: { [weak self] key in
            self?.storeLicenseKey(key)
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
    let onLicenseValidated: @MainActor (String) -> Void

    @State private var licenseKey = ""
    @State private var showThankYou = false
    @State private var showInvalidKey = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text("You've transcribed \(count) times with Byblos!")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("If you find it useful, consider supporting development.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Link("Support Byblos \u{2192}", destination: URL(string: "https://byblos.im/support")!)
                .font(.callout)

            Divider()

            if showThankYou {
                Text("Thank you for supporting Byblos!")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else {
                HStack {
                    TextField("BYBL-XXXX-XXXX-XXXX", text: $licenseKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)

                    Button("Verify") {
                        if NagManager.shared.validateKeyFormat(licenseKey.trimmingCharacters(in: .whitespaces)) {
                            showInvalidKey = false
                            showThankYou = true
                            onLicenseValidated(licenseKey.trimmingCharacters(in: .whitespaces))
                        } else {
                            showInvalidKey = true
                        }
                    }
                    .disabled(licenseKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if showInvalidKey {
                    Text("Invalid key format. Expected: BYBL-XXXX-XXXX-XXXX")
                        .font(.caption)
                        .foregroundStyle(.red)
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
        .frame(width: 400)
    }
}
