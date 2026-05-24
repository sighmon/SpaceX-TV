import Foundation
import Security

struct KeychainTokenStore {
    var service = Bundle.main.bundleIdentifier ?? "SpaceXTV"
    var account = "xAPIBearerToken"

    func token() -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return ""
        }

        return token
    }

    func save(_ token: String) {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            delete()
            return
        }

        let data = Data(trimmedToken.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else {
            return
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
