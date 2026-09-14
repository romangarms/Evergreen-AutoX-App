import Foundation
import Security

// There are no accounts: a random token minted on first launch is what the
// server uses to tell whose leaderboards and runs are whose. It lives in the
// Keychain so ownership survives a reinstall.
enum DeviceIdentity {
    private static let service = "com.romangarms.Evergreen-AutoX-App-iOS.device"
    private static let account = "token"
    private static let defaultsKey = "deviceToken"

    static let token: String = load() ?? create()

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let token = String(data: data, encoding: .utf8),
           !token.isEmpty {
            return token
        }
        return UserDefaults.standard.string(forKey: defaultsKey)
    }

    private static func create() -> String {
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(attributes as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(token, forKey: defaultsKey)
        }
        return token
    }
}
