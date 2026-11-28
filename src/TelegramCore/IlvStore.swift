// ilvtg — private storage for ilvtg's own data (settings, per-chat ghost choices, locked chats,
// kept-deleted marks, location emulation, edit history). Copied into
// submodules/TelegramCore/Sources/Ilv/ by ci/prepare.py.
//
// UserDefaults is backed up to iCloud and to computers; Telegram's own database is not. This
// store keeps ilvtg's data next to it in the same way: a property list in Application
// Support/ilvtg, excluded from backups and protected by iOS data protection. The first launch
// moves everything ilvtg had put in UserDefaults here.

import Foundation
import Security
import CommonCrypto

public final class IlvStore {
    public static let shared = IlvStore()

    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var loaded = false
    private let saveQueue = DispatchQueue(label: "org.ilvtg.store")

    /// Keys other modules (which cannot link TelegramCore) still read from UserDefaults. They hold
    /// no personal data: bubble opacity, whether tab titles are shown and whether screenshots are
    /// allowed (read by UIKitRuntimeUtils, edit "screenshots-allowed").
    private static let mirroredToUserDefaults: Set<String> = ["ilvtg.bubbleAlpha", "ilvtg.tabs.hideTitles", "ilvtg.privacy.hideScreenshots"]

    /// Application Support/ilvtg, created on demand and excluded from backups.
    public static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        var url = base.appendingPathComponent("ilvtg", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? url.setResourceValues(resourceValues)
        return url
    }

    /// Read directly by DeviceLocationManager (edit "location-helper").
    public static var fileURL: URL? {
        return directory?.appendingPathComponent("store.plist")
    }

    private func loadIfNeeded() {
        if self.loaded {
            return
        }
        self.loaded = true
        if let url = IlvStore.fileURL, let data = try? Data(contentsOf: url), let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            self.values = object
            // Modules without TelegramCore read these from UserDefaults: keep them in step.
            for key in IlvStore.mirroredToUserDefaults {
                if let value = object[key] {
                    UserDefaults.standard.set(value, forKey: key)
                }
            }
            return
        }
        // First launch with the store: take over what earlier versions kept in UserDefaults.
        let defaults = UserDefaults.standard
        var migrated = false
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("ilvtg.") {
            if key == "ilvtg.duress.hash" {
                // The old fake-passcode hash was weak; the fake passcode now lives in the Keychain
                // and has to be set again.
                defaults.removeObject(forKey: key)
                continue
            }
            self.values[key] = value
            migrated = true
            if !IlvStore.mirroredToUserDefaults.contains(key) {
                defaults.removeObject(forKey: key)
            }
        }
        if migrated {
            self.saveLocked()
        }
    }

    private func saveLocked() {
        let snapshot = self.values
        self.saveQueue.async {
            guard let url = IlvStore.fileURL, let data = try? PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0) else {
                return
            }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    public func object(forKey key: String) -> Any? {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.loadIfNeeded()
        return self.values[key]
    }

    public func set(_ value: Any?, forKey key: String) {
        self.lock.lock()
        self.loadIfNeeded()
        if let value = value {
            self.values[key] = value
        } else {
            self.values.removeValue(forKey: key)
        }
        self.saveLocked()
        self.lock.unlock()
        if IlvStore.mirroredToUserDefaults.contains(key) {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    public func removeObject(forKey key: String) {
        self.set(nil, forKey: key)
    }

    public func bool(forKey key: String) -> Bool {
        return (self.object(forKey: key) as? NSNumber)?.boolValue ?? false
    }

    public func integer(forKey key: String) -> Int {
        return (self.object(forKey: key) as? NSNumber)?.intValue ?? 0
    }

    public func double(forKey key: String) -> Double {
        return (self.object(forKey: key) as? NSNumber)?.doubleValue ?? 0.0
    }

    public func string(forKey key: String) -> String? {
        return self.object(forKey: key) as? String
    }

    public func array(forKey key: String) -> [Any]? {
        return self.object(forKey: key) as? [Any]
    }

    public func stringArray(forKey key: String) -> [String]? {
        return self.object(forKey: key) as? [String]
    }

    public func dictionary(forKey key: String) -> [String: Any]? {
        return self.object(forKey: key) as? [String: Any]
    }
}

/// Secrets that must not leave this device: the Keychain, only while the device is unlocked,
/// never synced or restored from a backup to another device.
enum IlvKeychain {
    private static let service = "org.ilvtg.secure"

    static func data(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    @discardableResult
    static func set(_ data: Data?, _ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard let data = data else {
            return true
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    /// PBKDF2-HMAC-SHA256, so a short code cannot be tested quickly even if the hash leaks.
    static func derive(_ code: String, salt: Data) -> Data {
        let password = Array(code.utf8)
        if password.isEmpty {
            return Data()
        }
        var derived = Data(count: 32)
        let saltBytes = [UInt8](salt)
        let derivedCount = derived.count
        let status = derived.withUnsafeMutableBytes { buffer -> Int32 in
            guard let output = buffer.bindMemory(to: UInt8.self).baseAddress else {
                return -1
            }
            return password.withUnsafeBufferPointer { passwordBuffer -> Int32 in
                return passwordBuffer.baseAddress!.withMemoryRebound(to: Int8.self, capacity: password.count) { passwordPointer -> Int32 in
                    return CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordPointer, password.count, saltBytes, saltBytes.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000, output, derivedCount)
                }
            }
        }
        if status != 0 {
            return Data()
        }
        return derived
    }

    static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}
