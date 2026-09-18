import Foundation
import AuthenticationServices
import Observation

@MainActor
@Observable
final class TravisCloudAuthService {

    static let shared = TravisCloudAuthService()

    enum State: Equatable {
        case signedOut
        case restoring
        case refreshing
        case signedIn
        case failed(String)
    }

    private struct AuthResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: TimeInterval
    }

    private struct PasswordBody: Encodable {
        let email: String
        let password: String
    }

    private struct RefreshBody: Encodable {
        let refresh_token: String
    }

    private struct SupabaseErrorResponse: Decodable {
        let msg: String?
        let message: String?
        let error_description: String?
        let error: String?
    }

    private let baseURL =
        URL(string: "https://ggppmrcsdjhbasubhzit.supabase.co")!

    // Supabase publishable keys are public client configuration.
    // User access/refresh tokens remain Keychain-only.
    private let publishableKey =
        "sb_publishable_M7xNRugheKl_cIRzULxrrw_v0qoxyEc"

    private(set) var state: State = .signedOut
    private(set) var session: TravisCloudCredentialStore.Session?

    private var webAuthenticationSession: ASWebAuthenticationSession?

    private init() {}

    var isSignedIn: Bool {
        session != nil
    }

    /// Restores a renewable session from Keychain.
    /// If the access token is close to expiry, refresh it before returning.
    @discardableResult
    func restoreSession() async -> TravisCloudCredentialStore.Session? {
        state = .restoring

        guard let stored = TravisCloudCredentialStore.loadSession() else {
            session = nil
            state = .signedOut
            return nil
        }

        if stored.needsRefresh {
            do {
                return try await refresh(stored)
            } catch {
                // Do not erase the refresh token merely because of a transient
                // network failure. The user can retry restoration later.
                session = stored
                state = .failed(error.localizedDescription)
                return nil
            }
        }

        session = stored
        state = .signedIn
        return stored
    }

    /// Authenticates through Supabase GitHub OAuth using the system
    /// authentication session. GitHub credentials are handled only by the
    /// browser/GitHub/Supabase flow and are never visible to TRAVIS.
    @discardableResult
    func signInWithGitHub() async throws
        -> TravisCloudCredentialStore.Session {

        guard webAuthenticationSession == nil else {
            throw AuthError.authenticationInProgress
        }

        state = .restoring

        var components = URLComponents(
            url: baseURL.appendingPathComponent("/auth/v1/authorize"),
            resolvingAgainstBaseURL: false
        )

        components?.queryItems = [
            URLQueryItem(name: "provider", value: "github"),
            URLQueryItem(
                name: "redirect_to",
                value: "travis://auth/callback"
            )
        ]

        guard let authorizationURL = components?.url else {
            state = .failed(
                AuthError.invalidResponse.localizedDescription
            )
            throw AuthError.invalidResponse
        }

        do {
            let callbackURL = try await runOAuthSession(
                authorizationURL: authorizationURL
            )

            let response = try parseOAuthCallback(callbackURL)

            let newSession = try persist(response)
            session = newSession
            state = .signedIn

            return newSession
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private func runOAuthSession(
        authorizationURL: URL
    ) async throws -> URL {

        try await withCheckedThrowingContinuation { continuation in
            var resumed = false

            let authSession = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: "travis"
            ) { [weak self] callbackURL, error in
                guard !resumed else { return }
                resumed = true

                self?.webAuthenticationSession = nil

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let callbackURL else {
                    continuation.resume(
                        throwing: AuthError.invalidCallback
                    )
                    return
                }

                continuation.resume(returning: callbackURL)
            }

            authSession.prefersEphemeralWebBrowserSession = false

            self.webAuthenticationSession = authSession

            guard authSession.start() else {
                self.webAuthenticationSession = nil

                guard !resumed else { return }
                resumed = true

                continuation.resume(
                    throwing: AuthError.browserSessionFailed
                )
                return
            }
        }
    }

    private func parseOAuthCallback(
        _ url: URL
    ) throws -> AuthResponse {

        guard url.scheme?.lowercased() == "travis",
              url.host?.lowercased() == "auth",
              url.path == "/callback" else {
            throw AuthError.invalidCallback
        }

        // Supabase OAuth implicit callback values are returned in the URL
        // fragment. Query parsing is also supported defensively.
        let fragmentItems = URLComponents(
            string: "travis://auth/callback?"
                + (url.fragment ?? "")
        )?.queryItems ?? []

        let queryItems =
            URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? []

        let items = fragmentItems + queryItems

        func value(_ name: String) -> String? {
            items.first {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }?.value
        }

        if let errorDescription =
            value("error_description") ?? value("error") {
            throw AuthError.oauth(errorDescription)
        }

        guard let accessToken = value("access_token"),
              let refreshToken = value("refresh_token"),
              !accessToken.isEmpty,
              !refreshToken.isEmpty else {
            throw AuthError.invalidCallback
        }

        let expiresIn: TimeInterval

        if let raw = value("expires_in"),
           let seconds = TimeInterval(raw),
           seconds > 0 {
            expiresIn = seconds
        } else if let rawExpiresAt = value("expires_at"),
                  let epoch = TimeInterval(rawExpiresAt) {
            expiresIn = max(0, epoch - Date().timeIntervalSince1970)
        } else {
            throw AuthError.invalidCallback
        }

        guard expiresIn > 0 else {
            throw AuthError.invalidCallback
        }

        return AuthResponse(
            access_token: accessToken,
            refresh_token: refreshToken,
            expires_in: expiresIn
        )
    }

    /// Authenticates with Supabase. Password is used only to build this
    /// request and is never persisted by TRAVIS.
    @discardableResult
    func signIn(
        email: String,
        password: String
    ) async throws -> TravisCloudCredentialStore.Session {

        let normalizedEmail = email
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedEmail.isEmpty, !password.isEmpty else {
            throw AuthError.invalidCredentials
        }

        let response: AuthResponse = try await authRequest(
            path: "/auth/v1/token?grant_type=password",
            body: PasswordBody(
                email: normalizedEmail,
                password: password
            )
        )

        let newSession = try persist(response)
        session = newSession
        state = .signedIn
        return newSession
    }

    /// Returns a currently usable access token, refreshing the session
    /// first when required.
    func validAccessToken() async throws -> String {
        let current: TravisCloudCredentialStore.Session

        if let session {
            current = session
        } else if let stored = TravisCloudCredentialStore.loadSession() {
            current = stored
            session = stored
        } else {
            state = .signedOut
            throw AuthError.noSession
        }

        if current.needsRefresh {
            return try await refresh(current).accessToken
        }

        state = .signedIn
        return current.accessToken
    }

    @discardableResult
    func refreshSession() async throws
        -> TravisCloudCredentialStore.Session {

        guard let current =
            session ?? TravisCloudCredentialStore.loadSession() else {
            state = .signedOut
            throw AuthError.noSession
        }

        return try await refresh(current)
    }

    func signOut() {
        TravisCloudCredentialStore.clear()
        session = nil
        state = .signedOut
    }

    private func refresh(
        _ current: TravisCloudCredentialStore.Session
    ) async throws -> TravisCloudCredentialStore.Session {

        state = .refreshing

        do {
            let response: AuthResponse = try await authRequest(
                path: "/auth/v1/token?grant_type=refresh_token",
                body: RefreshBody(
                    refresh_token: current.refreshToken
                )
            )

            let newSession = try persist(response)
            session = newSession
            state = .signedIn
            return newSession
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private func persist(
        _ response: AuthResponse
    ) throws -> TravisCloudCredentialStore.Session {

        let access = response.access_token
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let refresh = response.refresh_token
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !access.isEmpty,
              !refresh.isEmpty,
              response.expires_in > 0 else {
            throw AuthError.invalidResponse
        }

        let newSession = TravisCloudCredentialStore.Session(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(response.expires_in)
        )

        try TravisCloudCredentialStore.save(session: newSession)
        return newSession
    }

    private func authRequest<Response: Decodable, Body: Encodable>(
        path: String,
        body: Body
    ) async throws -> Response {

        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw AuthError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            publishableKey,
            forHTTPHeaderField: "apikey"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard let http = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let server = try? JSONDecoder().decode(
                SupabaseErrorResponse.self,
                from: data
            )

            let message =
                server?.msg ??
                server?.message ??
                server?.error_description ??
                server?.error ??
                "Authentication request failed"

            throw AuthError.server(
                status: http.statusCode,
                message: message
            )
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AuthError.invalidResponse
        }
    }

    enum AuthError: LocalizedError {
        case invalidCredentials
        case noSession
        case invalidResponse
        case invalidCallback
        case browserSessionFailed
        case authenticationInProgress
        case oauth(String)
        case server(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidCredentials:
                return "Email and password are required."

            case .noSession:
                return "No TRAVIS cloud session is available."

            case .invalidResponse:
                return "Supabase returned an invalid authentication response."

            case .invalidCallback:
                return "Supabase returned an invalid OAuth callback."

            case .browserSessionFailed:
                return "The GitHub authentication session could not be started."

            case .authenticationInProgress:
                return "A cloud authentication session is already in progress."

            case .oauth(let message):
                return "GitHub authentication failed: \(message)"

            case .server(let status, let message):
                return "Supabase authentication failed (\(status)): \(message)"
            }
        }
    }
}
