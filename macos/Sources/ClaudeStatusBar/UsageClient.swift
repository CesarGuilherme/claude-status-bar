import CryptoKit
import Foundation

enum UsageError: Error, Equatable {
    case unauthorized
    case http(Int)
    case decode
    case transport
    case oauth(String)
}

enum UsageClient {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    static func fetch(_ credentials: OAuthCredentials, session: URLSession = .shared) async throws -> UsageResponse {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.transport }
        if http.statusCode == 401 { throw UsageError.unauthorized }
        guard http.statusCode == 200 else { throw UsageError.http(http.statusCode) }
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw UsageError.decode
        }
    }

    static func message(_ error: Error, source: OAuthCredentials.Source) -> String {
        switch error {
        case UsageError.unauthorized where source == .claudeCode:
            return L10n.tr("Claude Code's token is no longer valid. Open Claude Code or sign in here.")
        case UsageError.unauthorized:
            return L10n.tr("Login refused. Sign in again.")
        case UsageError.http(let code):
            return L10n.tr("The quota didn't respond (HTTP %d).", code)
        case UsageError.decode:
            return L10n.tr("The quota response came in a new format.")
        case UsageError.transport:
            return L10n.tr("No network for the quota.")
        default:
            return L10n.tr("Couldn't read the quota.")
        }
    }
}

enum OAuthFlow {
    static let authorize = URL(string: "https://claude.ai/oauth/authorize")!
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    static let scopes = ["user:profile", "user:inference"]

    struct Pending: Sendable {
        var verifier: String
        var state: String
        var url: URL
    }

    static func begin() -> Pending {
        let verifier = randomVerifier()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = randomVerifier()
        var parts = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: UsageClient.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return Pending(verifier: verifier, state: state, url: parts.url!)
    }

    static func exchange(rawCode: String, pending: Pending, session: URLSession = .shared) async throws -> OAuthCredentials {
        let parts = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1)
        guard let code = parts.first.map(String.init), !code.isEmpty else {
            throw UsageError.oauth("código vazio")
        }
        guard parts.count == 2, String(parts[1]) == pending.state else {
            throw UsageError.oauth("state")
        }
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": pending.state,
            "client_id": UsageClient.clientID,
            "redirect_uri": redirectURI,
            "code_verifier": pending.verifier,
        ]
        return try await tokenRequest(body, session: session, fallbackRefresh: nil, scopes: scopes)
    }

    /// Refreshes only a token this app stored. Never rotates the Claude Code keychain item.
    static func refresh(_ credentials: OAuthCredentials, session: URLSession = .shared) async throws -> OAuthCredentials {
        guard credentials.source == .app, let refresh = credentials.refreshToken, !refresh.isEmpty else {
            throw UsageError.unauthorized
        }
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": UsageClient.clientID,
            "scope": credentials.scopes.joined(separator: " "),
        ]
        return try await tokenRequest(body, session: session, fallbackRefresh: refresh, scopes: credentials.scopes)
    }

    private static func tokenRequest(
        _ body: [String: String],
        session: URLSession,
        fallbackRefresh: String?,
        scopes: [String]
    ) async throws -> OAuthCredentials {
        var request = URLRequest(url: UsageClient.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.transport }
        guard http.statusCode == 200 else { throw UsageError.http(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              !access.isEmpty
        else { throw UsageError.decode }
        let granted = (json["scope"] as? String)?
            .split(whereSeparator: \.isWhitespace)
            .map(String.init) ?? scopes
        return OAuthCredentials(
            accessToken: access,
            refreshToken: (json["refresh_token"] as? String) ?? fallbackRefresh,
            expiresAt: expiry(json["expires_in"]) ?? Date().addingTimeInterval(3600),
            scopes: granted,
            source: .app
        )
    }

    private static func expiry(_ value: Any?) -> Date? {
        let seconds: TimeInterval?
        switch value {
        case let number as NSNumber: seconds = number.doubleValue
        case let number as Double: seconds = number
        case let number as Int: seconds = TimeInterval(number)
        case let string as String: seconds = TimeInterval(string)
        default: seconds = nil
        }
        guard let seconds else { return nil }
        return Date().addingTimeInterval(seconds)
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
