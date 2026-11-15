//
// AppGroupBridge.swift
// Exposes the App Group container path + keychain access group to Dart so
// IosAppGroup can write `active_xmtp.json` and mirror the XMTP DB key into the
// shared Keychain. Registered from AppDelegate.
//

import Flutter
import Foundation
import Security

class AppGroupBridge {
    static let channelName = "com.publicos/app_group"
    static let appGroupId = "group.YOUR.BUNDLE.ID.shared"
    static let keychainAccessGroupSuffix = "YOUR.BUNDLE.ID.shared"
    static let flutterSecureStorageService = "flutter_secure_storage_service"

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "getContainerPath":
                result(containerPath())
            case "getKeychainAccessGroup":
                result(fullAccessGroup())
            case "writeSharedKeychainKey":
                guard let args = call.arguments as? [String: Any],
                      let key = args["key"] as? String,
                      let value = args["value"] as? String else {
                    result(FlutterError(code: "BAD_ARGS", message: "key/value required", details: nil))
                    return
                }
                let status = writeSharedKeychainKey(name: key, value: value)
                result(status == errSecSuccess)
            case "deleteSharedKeychainKey":
                guard let args = call.arguments as? [String: Any],
                      let key = args["key"] as? String else {
                    result(FlutterError(code: "BAD_ARGS", message: "key required", details: nil))
                    return
                }
                _ = deleteSharedKeychainKey(name: key)
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func containerPath() -> String? {
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
            .path
    }

    private static func fullAccessGroup() -> String {
        return "\(appIdentifierPrefix())\(keychainAccessGroupSuffix)"
    }

    /// Mirror-writes a value to the shared-access-group Keychain. Uses the same
    /// service string flutter_secure_storage uses on iOS so the NSE's plain
    /// `kSecClassGenericPassword` query (matching service + account) returns
    /// the value as if it had been written by flutter_secure_storage itself.
    private static func writeSharedKeychainKey(name: String, value: String) -> OSStatus {
        let accessGroup = fullAccessGroup()
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: flutterSecureStorageService,
            kSecAttrAccount as String: name,
            kSecAttrAccessGroup as String: accessGroup
        ]
        // Delete-then-add gives us idempotent upsert with consistent attrs.
        SecItemDelete(baseQuery as CFDictionary)
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(addQuery as CFDictionary, nil)
    }

    @discardableResult
    private static func deleteSharedKeychainKey(name: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: flutterSecureStorageService,
            kSecAttrAccount as String: name,
            kSecAttrAccessGroup as String: fullAccessGroup()
        ]
        return SecItemDelete(query as CFDictionary)
    }

    private static func appIdentifierPrefix() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "bundleSeedID",
            kSecAttrService as String: "",
            kSecReturnAttributes as String: true
        ]
        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            status = SecItemAdd(query as CFDictionary, &result)
        }
        if let attrs = result as? [String: Any],
           let accessGroup = attrs[kSecAttrAccessGroup as String] as? String,
           let prefix = accessGroup.components(separatedBy: ".").first {
            return "\(prefix)."
        }
        return ""
    }
}
