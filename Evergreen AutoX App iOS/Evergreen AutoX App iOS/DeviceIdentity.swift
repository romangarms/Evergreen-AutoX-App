import Foundation
import Security

// A random token minted on first launch is how the server recognises this
// device; signing in with Apple links it to an account, and the account then
// owns what it posts. It lives in the Keychain so a reinstall stays signed in.
enum DeviceIdentity {
    private static let service = "com.romangarms.Evergreen-AutoX-App-iOS.device"
    private static let account = "token"
    private static let appleUserAccount = "appleUser"
    private static let appleNameAccount = "appleName"
    private static let defaultsKey = "deviceToken"

    static let token: String = load() ?? create()

    // Apple's identifier for whoever signed in on this device, which is what
    // Apple wants back when asked whether the sign-in still stands. It sits
    // beside the token so both survive a reinstall together.
    static var appleUser: String? {
        get { read(appleUserAccount) }
        set { write(newValue, appleUserAccount) }
    }

    // Apple shares the name only the first time an Apple ID signs in to the
    // app, so it is kept for the sign-ins after that: a retry after a failed
    // request, a reinstall, or a different server.
    static var appleName: String? {
        get { read(appleNameAccount) }
        set { write(newValue, appleNameAccount) }
    }

    private static func read(_ account: String) -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String?, _ account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
        guard let value else { return }
        var attributes = query(account: account)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static var baseQuery: [String: Any] { query(account: account) }

    private static func query(account: String) -> [String: Any] {
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
