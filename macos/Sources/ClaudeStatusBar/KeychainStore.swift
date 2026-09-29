import Foundation
import Security

struct OAuthCredentials: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var scopes: [String]
    var source: Source

    enum Source: String, Equatable, Sendable {
        case claudeCode
        case app
    }

    func isExpired(now: Date = Date(), skew: TimeInterval = 120) -> Bool {
        expiresAt.timeIntervalSince(now) <= skew
    }
}

enum CredentialStore {
    static let claudeService = "Claude Code-credentials"

    static func loadClaudeCode(now: Date = Date()) -> OAuthCredentials? {
        guard let data = keychainData(service: claudeService) else { return nil }
        return parseClaudeCode(data, now: now)
    }

    static func parseClaudeCode(_ data: Data, now: Date = Date()) -> OAuthCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String,
              !access.isEmpty
        else { return nil }
        let scopes = oauth["scopes"] as? [String] ?? []
        return OAuthCredentials(
            accessToken: access,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expiryDate(oauth["expiresAt"]) ?? now.addingTimeInterval(-1),
            scopes: scopes,
            source: .claudeCode
        )
    }

    static func loadApp(now: Date = Date()) -> OAuthCredentials? {
        guard let data = try? Data(contentsOf: appTokenURL) else { return nil }
        return parseApp(data, now: now)
    }

    static func parseApp(_ data: Data, now: Date = Date()) -> OAuthCredentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String,
              !access.isEmpty
        else { return nil }
        let scopes = object["scopes"] as? [String] ?? []
        return OAuthCredentials(
            accessToken: access,
            refreshToken: object["refresh_token"] as? String,
            expiresAt: expiryDate(object["expires_at"]) ?? now.addingTimeInterval(-1),
            scopes: scopes,
            source: .app
        )
    }

    static func saveApp(_ credentials: OAuthCredentials) throws {
        let directory = appTokenURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let object: [String: Any] = [
            "access_token": credentials.accessToken,
            "refresh_token": credentials.refreshToken ?? "",
            "expires_at": credentials.expiresAt.timeIntervalSince1970,
            "scopes": credentials.scopes,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: appTokenURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: appTokenURL.path)
    }

    static func deleteApp() {
        try? FileManager.default.removeItem(at: appTokenURL)
    }

    static var appTokenURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-status-bar/token")
    }

    private static func keychainData(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func expiryDate(_ value: Any?) -> Date? {
        let seconds: TimeInterval?
        switch value {
        case let number as NSNumber:
            seconds = number.doubleValue
        case let number as Double:
            seconds = number
        case let number as Int:
            seconds = TimeInterval(number)
        default:
            seconds = nil
        }
        guard let seconds else { return nil }
        let unix = seconds > 1_000_000_000_000 ? seconds / 1000 : seconds
        return Date(timeIntervalSince1970: unix)
    }
}
