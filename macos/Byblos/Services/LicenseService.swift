import Foundation

/// Manages license validation via LemonSqueezy License API.
///
/// Flow:
/// 1. User buys license on byblos.im → LemonSqueezy emails them a key
/// 2. User enters key in app → app calls LS /activate endpoint
/// 3. LS returns validity, expiry date, instance ID
/// 4. App caches result locally, disables nag
/// 5. Periodic re-validation (once/day on app launch) if online
@MainActor
final class LicenseService: ObservableObject {
    static let shared = LicenseService()

    // MARK: - Configuration

    /// LemonSqueezy API base URL.
    private let apiBase = "https://api.lemonsqueezy.com/v1/licenses"

    /// Your store and product IDs from LemonSqueezy dashboard.
    /// TODO: Replace with real values after setting up LemonSqueezy.
    private let expectedStoreId = 0  // Set after creating LS store
    private let expectedProductId = 0  // Set after creating LS product

    // MARK: - UserDefaults Keys

    private let keyLicenseKey = "licenseKey"
    private let keyInstanceId = "licenseInstanceId"
    private let keyExpiresAt = "licenseExpiresAt"
    private let keyActivatedAt = "licenseActivatedAt"
    private let keyLastValidated = "licenseLastValidated"
    private let keyCustomerEmail = "licenseCustomerEmail"
    private let keyLicenseStatus = "licenseStatus"

    // MARK: - Published State

    @Published var isLicensed = false
    @Published var expiresAt: Date?
    @Published var daysRemaining: Int?
    @Published var customerEmail: String?
    @Published var isActivating = false
    @Published var lastError: String?

    private init() {
        refreshFromCache()
    }

    // MARK: - Public API

    /// Activate a license key via LemonSqueezy.
    func activate(key: String) async -> Bool {
        isActivating = true
        lastError = nil
        defer { isActivating = false }

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Please enter a license key."
            return false
        }

        // Call LemonSqueezy activate endpoint.
        let params = "license_key=\(trimmed)&instance_name=\(instanceName())"
        guard let result = await callAPI(endpoint: "activate", params: params) else {
            return false
        }

        // Verify it belongs to our product.
        if expectedStoreId > 0 {
            if let meta = result["meta"] as? [String: Any],
               let storeId = meta["store_id"] as? Int,
               storeId != expectedStoreId {
                lastError = "This key is not for Byblos."
                return false
            }
        }

        // Extract license data.
        guard let activated = result["activated"] as? Bool, activated else {
            let errorMsg = result["error"] as? String ?? "Activation failed."
            lastError = errorMsg
            return false
        }

        // Save everything locally.
        let licenseKey = (result["license_key"] as? [String: Any])
        let instance = (result["instance"] as? [String: Any])
        let meta = (result["meta"] as? [String: Any])

        UserDefaults.standard.set(trimmed, forKey: keyLicenseKey)
        UserDefaults.standard.set(Date(), forKey: keyActivatedAt)
        UserDefaults.standard.set(Date(), forKey: keyLastValidated)

        if let instanceId = instance?["id"] as? String {
            UserDefaults.standard.set(instanceId, forKey: keyInstanceId)
        }

        if let expiresStr = licenseKey?["expires_at"] as? String {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fmt.date(from: expiresStr) {
                UserDefaults.standard.set(date, forKey: keyExpiresAt)
            }
        }

        if let email = meta?["customer_email"] as? String {
            UserDefaults.standard.set(email, forKey: keyCustomerEmail)
        }

        if let status = licenseKey?["status"] as? String {
            UserDefaults.standard.set(status, forKey: keyLicenseStatus)
        }

        refreshFromCache()
        Log.info("License activated successfully")
        return true
    }

    /// Validate the cached license (call periodically, e.g. on app launch).
    func validateCached() async {
        guard let key = UserDefaults.standard.string(forKey: keyLicenseKey),
              !key.isEmpty else { return }

        // Only re-validate once per day.
        if let lastValidated = UserDefaults.standard.object(forKey: keyLastValidated) as? Date {
            let hoursSince = Date().timeIntervalSince(lastValidated) / 3600
            if hoursSince < 24 { return }
        }

        let instanceId = UserDefaults.standard.string(forKey: keyInstanceId) ?? ""
        var params = "license_key=\(key)"
        if !instanceId.isEmpty {
            params += "&instance_id=\(instanceId)"
        }

        guard let result = await callAPI(endpoint: "validate", params: params) else {
            // Network error — trust cached state.
            Log.info("License validation failed (offline?) — using cached state")
            return
        }

        let valid = result["valid"] as? Bool ?? false
        UserDefaults.standard.set(Date(), forKey: keyLastValidated)

        if !valid {
            let licenseKey = result["license_key"] as? [String: Any]
            let status = licenseKey?["status"] as? String ?? "unknown"
            Log.info("License no longer valid: status=\(status)")
            UserDefaults.standard.set(status, forKey: keyLicenseStatus)
        }

        // Update expiry if returned.
        if let licenseKey = result["license_key"] as? [String: Any],
           let expiresStr = licenseKey["expires_at"] as? String {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fmt.date(from: expiresStr) {
                UserDefaults.standard.set(date, forKey: keyExpiresAt)
            }
        }

        refreshFromCache()
    }

    /// Deactivate the license (e.g. when transferring to another machine).
    func deactivate() async -> Bool {
        guard let key = UserDefaults.standard.string(forKey: keyLicenseKey),
              let instanceId = UserDefaults.standard.string(forKey: keyInstanceId)
        else { return false }

        let params = "license_key=\(key)&instance_id=\(instanceId)"
        let _ = await callAPI(endpoint: "deactivate", params: params)

        // Clear local state regardless of API result.
        clearLicense()
        return true
    }

    /// Clear all license data.
    func clearLicense() {
        for key in [keyLicenseKey, keyInstanceId, keyExpiresAt, keyActivatedAt,
                    keyLastValidated, keyCustomerEmail, keyLicenseStatus] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        refreshFromCache()
        Log.info("License cleared")
    }

    // MARK: - Private

    private func refreshFromCache() {
        let key = UserDefaults.standard.string(forKey: keyLicenseKey) ?? ""
        let status = UserDefaults.standard.string(forKey: keyLicenseStatus) ?? ""
        let expires = UserDefaults.standard.object(forKey: keyExpiresAt) as? Date

        // Licensed if: key exists AND (status is active/inactive AND not expired).
        if !key.isEmpty {
            if let expires {
                isLicensed = expires > Date() && (status == "active" || status == "inactive" || status.isEmpty)
                expiresAt = expires
                daysRemaining = Calendar.current.dateComponents([.day], from: Date(), to: expires).day
            } else {
                // No expiry date cached — trust activation date + 365 days.
                if let activated = UserDefaults.standard.object(forKey: keyActivatedAt) as? Date {
                    let expiryDate = Calendar.current.date(byAdding: .year, value: 1, to: activated) ?? activated
                    isLicensed = expiryDate > Date()
                    expiresAt = expiryDate
                    daysRemaining = Calendar.current.dateComponents([.day], from: Date(), to: expiryDate).day
                } else {
                    isLicensed = false
                }
            }
        } else {
            isLicensed = false
            expiresAt = nil
            daysRemaining = nil
        }

        customerEmail = UserDefaults.standard.string(forKey: keyCustomerEmail)
    }

    private func callAPI(endpoint: String, params: String) async -> [String: Any]? {
        guard let url = URL(string: "\(apiBase)/\(endpoint)") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params.data(using: .utf8)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            if http.statusCode >= 400 {
                let errorMsg = json?["error"] as? String ?? "HTTP \(http.statusCode)"
                Log.error("LemonSqueezy API error: \(errorMsg)")
                lastError = errorMsg
                return nil
            }

            return json
        } catch {
            Log.error("LemonSqueezy API call failed: \(error.localizedDescription)")
            // Don't set lastError for network failures — user might be offline.
            return nil
        }
    }

    private func instanceName() -> String {
        Host.current().localizedName ?? "Mac"
    }
}
