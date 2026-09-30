import Foundation
import Security

/// The per-install secret the moment derivation is keyed on.
///
/// Why the Keychain and not `UserDefaults`:
/// - `UserDefaults` lives in a plist that is wiped on reinstall. A wiped secret
///   silently reshuffles every future moment, which is exactly the behaviour
///   that would make the schedule feel broken.
/// - The secret is not a credential. It protects nothing but schedule
///   stability, so `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is right:
///   readable after first unlock, never synced, never backed up off-device.
struct InstallSecret: Sendable {

    /// Static, application-scoped label. Survives Keychain cleanup because the
    /// label is a compile-time constant rather than a bundle-derived value.
    private static let service = "com.javohirmx.memoree.moment-secret"
    private static let account = "moment-derivation-v1"

    /// The 32 raw bytes. Never logged, never exported, never leaves the device.
    let value: Data

    init(value: Data) {
        precondition(value.count == 32, "InstallSecret must be 32 bytes")
        self.value = value
    }

    /// Loads the existing secret, or creates one on first launch.
    init() {
        if let existing = Self.read() {
            self.value = existing
        } else {
            let generated = Self.generate()
            // A write failure is not fatal: fall back to an ephemeral secret so
            // the app still works this session. The consequence is that the
            // schedule reshuffles on next launch, which is survivable.
            Self.write(generated)
            self.value = generated
        }
    }

    private static func generate() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        // `SecRandomCopyBytes` cannot meaningfully fail on iOS; the fallback
        // keeps the precondition above satisfied rather than returning short data.
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return Data((0..<32).map { UInt8(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1000) &+ Int64($0)) })
        }
        return Data(bytes)
    }

    // MARK: - Keychain

    private static func read() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return data
    }

    private static func write(_ data: Data) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // Delete-then-add rather than update: simpler and correct, and it
        // repairs a pre-existing item with the wrong accessibility class.
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)

        SecItemAdd(query as CFDictionary, nil)
    }
}
