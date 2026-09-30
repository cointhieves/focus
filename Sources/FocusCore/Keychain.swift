import Foundation
import Security

/// Minimal Keychain wrapper (generic password items): the Jira API token and the Slack
/// tokens, each under its own service name.
public enum Keychain {
    static let jiraService = "io.github.omegaleon.focus.jira"
    static let slackService = "io.github.omegaleon.focus.slack"

    public static func readToken() -> String? {
        read(service: jiraService, account: "api-token").flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func saveToken(_ token: String) throws {
        try save(Data(token.utf8), service: jiraService, account: "api-token", label: "Focus – Jira API token")
    }

    public static func deleteToken() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: jiraService] as CFDictionary)
    }

    public static func readSlackTokens() -> SlackTokens? {
        read(service: slackService, account: "user-token")
            .flatMap { try? JSONDecoder().decode(SlackTokens.self, from: $0) }
    }

    public static func saveSlackTokens(_ tokens: SlackTokens) throws {
        try save(try JSONEncoder().encode(tokens), service: slackService, account: "user-token",
                 label: "Focus – Slack sign-in")
    }

    public static func deleteSlackTokens() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: slackService] as CFDictionary)
    }

    static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func save(_ data: Data, service: String, account: String, label: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)   // replace any existing item
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError(description: "could not save to Keychain (OSStatus \(status))")
        }
    }
}
