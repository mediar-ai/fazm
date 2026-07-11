import Foundation
import Security

enum CustomAPIEndpointCredentials {
  static let placeholderAPIKey = "sk-fazm-custom-endpoint"

  private static let account = "anthropic-api-key"

  private static var service: String {
    let bundleID = Bundle.main.bundleIdentifier ?? "com.fazm.app"
    return "\(bundleID).custom-api-endpoint"
  }

  static func storedAPIKey() -> String? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else {
      if status != errSecItemNotFound {
        log("CustomAPIEndpointCredentials: failed to read API key from Keychain (status \(status))")
      }
      return nil
    }

    guard let data = result as? Data,
      let raw = String(data: data, encoding: .utf8) else {
      return nil
    }

    let key = normalizedAPIKey(raw)
    return key.isEmpty ? nil : key
  }

  static func resolvedAPIKey() -> String {
    storedAPIKey() ?? placeholderAPIKey
  }

  static func setStoredAPIKey(_ raw: String) {
    let key = normalizedAPIKey(raw)
    guard !key.isEmpty else {
      deleteStoredAPIKey()
      return
    }

    let data = Data(key.utf8)
    let query = baseQuery()
    let update: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]

    let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess { return }

    if updateStatus == errSecItemNotFound {
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = SecItemAdd(add as CFDictionary, nil)
      if addStatus != errSecSuccess {
        log("CustomAPIEndpointCredentials: failed to save API key to Keychain (status \(addStatus))")
      }
      return
    }

    log("CustomAPIEndpointCredentials: failed to update API key in Keychain (status \(updateStatus))")
  }

  static func deleteStoredAPIKey() {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    if status != errSecSuccess && status != errSecItemNotFound {
      log("CustomAPIEndpointCredentials: failed to delete API key from Keychain (status \(status))")
    }
  }

  private static func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  private static func normalizedAPIKey(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("bearer ") {
      return String(trimmed.dropFirst("Bearer ".count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
  }
}
