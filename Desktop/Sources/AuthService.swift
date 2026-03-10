import Foundation
import AppKit
import AuthenticationServices
import CryptoKit
@preconcurrency import FirebaseAuth
import FirebaseCore
import Sentry

// MARK: - AuthError

/// Authentication errors (replaces the stub in DeletedTypeStubs)
enum AuthError: Error, LocalizedError {
    case notSignedIn
    case unauthorized
    case tokenRefreshFailed(String)
    case invalidResponse
    case serverError(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in"
        case .unauthorized: return "Unauthorized"
        case .tokenRefreshFailed(let msg): return "Token refresh failed: \(msg)"
        case .invalidResponse: return "Invalid response from server"
        case .serverError(let msg): return "Server error: \(msg)"
        case .cancelled: return "Sign in was cancelled"
        }
    }
}

// MARK: - AuthService

@MainActor
class AuthService: NSObject {
    static let shared = AuthService()

    // MARK: - Firebase Configuration (loaded from .env at runtime)

    private static var firebaseAPIKey: String {
        if let key = getenv("FIREBASE_API_KEY").flatMap({ String(cString: $0) }), !key.isEmpty {
            return key
        }
        logError("FIREBASE_API_KEY not set in environment — auth will fail")
        return ""
    }

    // MARK: - Google OAuth Configuration (Desktop type, loaded from .env)

    private static var googleClientId: String {
        if let id = getenv("GOOGLE_CLIENT_ID").flatMap({ String(cString: $0) }), !id.isEmpty {
            return id
        }
        logError("GOOGLE_CLIENT_ID not set in environment — Google sign-in will fail")
        return ""
    }

    private static var googleClientSecret: String {
        if let secret = getenv("GOOGLE_CLIENT_SECRET").flatMap({ String(cString: $0) }), !secret.isEmpty {
            return secret
        }
        logError("GOOGLE_CLIENT_SECRET not set in environment — Google sign-in will fail")
        return ""
    }

    // MARK: - UserDefaults Keys

    private static let kIdToken = "auth_idToken"
    private static let kRefreshToken = "auth_refreshToken"
    private static let kTokenExpiry = "auth_tokenExpiry"
    private static let kTokenUserId = "auth_tokenUserId"
    private static let kUserEmail = "auth_userEmail"
    private static let kGivenName = "user_givenName"
    private static let kFamilyName = "user_familyName"
    private static let kDisplayName = "user_displayName"

    // MARK: - Published Properties

    private(set) var idToken: String?
    private(set) var refreshToken: String?
    private(set) var tokenExpiry: Date?
    private(set) var userId: String?
    private(set) var userEmail: String?

    var displayName: String {
        UserDefaults.standard.string(forKey: Self.kDisplayName) ?? ""
    }

    var givenName: String {
        UserDefaults.standard.string(forKey: Self.kGivenName) ?? ""
    }

    var familyName: String {
        UserDefaults.standard.string(forKey: Self.kFamilyName) ?? ""
    }

    var isSignedIn: Bool {
        return idToken != nil && userId != nil
    }

    // MARK: - Private State

    private var tokenRefreshTimer: Timer?
    private var appleSignInDelegate: AuthServiceAppleSignInDelegate?
    private var firebaseAuthStateListener: AuthStateDidChangeListenerHandle?

    // MARK: - Init

    private override init() {
        super.init()
    }

    // MARK: - Configure

    /// Call this from AppDelegate.applicationDidFinishLaunching to set up Firebase and restore auth state.
    func configure() {
        // Configure Firebase with the correct GoogleService-Info.plist
        if FirebaseApp.app() == nil {
            // SPM puts resources in Bundle.module, not Bundle.main.
            // Select dev or prod plist based on bundle ID.
            let isDev = Bundle.main.bundleIdentifier == "com.fazm.desktop-dev"
            let plistName = isDev ? "GoogleService-Info-Dev" : "GoogleService-Info"
            if let plistPath = Bundle.resourceBundle.path(forResource: plistName, ofType: "plist"),
               let options = FirebaseOptions(contentsOfFile: plistPath) {
                FirebaseApp.configure(options: options)
                log("AuthService: Firebase configured with \(plistName).plist")
            } else {
                // Fallback: try default configure (looks in Bundle.main)
                FirebaseApp.configure()
                log("AuthService: Firebase configured with default plist lookup")
            }
        }

        // Restore saved auth state
        restoreAuthState()

        // Listen for Firebase auth state changes.
        // Note: This listener fires immediately upon registration with the current auth state.
        // We use DispatchQueue.main.async inside the Task to ensure SwiftUI's view graph
        // has finished its initial layout before we mutate @Published state.
        firebaseAuthStateListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                guard let self = self else { return }
                if let user = user {
                    log("AuthService: Firebase auth state changed - user signed in: \(user.uid)")
                    // If we don't have a token yet, get one from Firebase
                    if self.idToken == nil {
                        do {
                            let token = try await user.getIDToken()
                            self.idToken = token
                            self.userId = user.uid
                            self.userEmail = user.email
                            self.saveAuthState()
                            DispatchQueue.main.async {
                                self.updateAuthState()
                            }
                        } catch {
                            logError("AuthService: Failed to get Firebase ID token", error: error)
                        }
                    }
                } else {
                    log("AuthService: Firebase auth state changed - no user")
                }
            }
        }

        // Start token refresh timer (every 30 seconds, checks if refresh is needed)
        startTokenRefreshTimer()

        log("AuthService: Configured, isSignedIn=\(isSignedIn), userId=\(userId ?? "nil")")
    }

    // MARK: - Google Sign-In (Desktop OAuth + Firebase)

    /// Start Google Sign-In using Desktop OAuth flow with localhost redirect.
    func signInWithGoogle() async throws {
        AnalyticsManager.shared.signInStarted(provider: "google")
        log("AuthService: Starting Google Sign-In (Desktop OAuth)")

        // 1. Generate PKCE code verifier + challenge
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        // 2. Start temporary localhost HTTP server
        let (socketFD, port) = try createLocalhostListener()
        log("AuthService: Localhost server listening on port \(port)")

        // 3. Open Google OAuth URL in the browser
        let redirectURI = "http://localhost:\(port)"
        var urlComponents = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        urlComponents.queryItems = [
            URLQueryItem(name: "client_id", value: Self.googleClientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
        ]

        guard let authURL = urlComponents.url else {
            Darwin.close(socketFD)
            throw AuthError.invalidResponse
        }

        log("AuthService: Opening Google OAuth URL in browser")
        NSWorkspace.shared.open(authURL)

        // 4. Wait for the callback on localhost (capture the auth code)
        let authCode: String
        do {
            authCode = try await waitForOAuthCallback(socketFD: socketFD)
        } catch {
            AnalyticsManager.shared.signInFailed(provider: "google", error: error.localizedDescription)
            throw error
        }

        log("AuthService: Received auth code from Google OAuth callback")

        // 5. Exchange the code with Google's token endpoint for an id_token
        let googleIdToken = try await exchangeGoogleCode(authCode, codeVerifier: codeVerifier, redirectURI: redirectURI)

        // 6. Exchange Google id_token with Firebase signInWithIdp
        try await signInWithGoogleIdToken(googleIdToken)

        AnalyticsManager.shared.signInCompleted(provider: "google")
        log("AuthService: Google Sign-In completed successfully")
    }

    /// Exchange Google auth code for tokens.
    private func exchangeGoogleCode(_ code: String, codeVerifier: String, redirectURI: String) async throws -> String {
        let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "code": code,
            "client_id": Self.googleClientId,
            "client_secret": Self.googleClientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier,
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            logError("AuthService: Google token exchange failed (status \(statusCode)): \(responseBody)")
            throw AuthError.serverError("Google token exchange failed (status \(statusCode))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = json["id_token"] as? String else {
            throw AuthError.invalidResponse
        }

        log("AuthService: Google token exchange successful")
        return idToken
    }

    /// Exchange Google id_token with Firebase signInWithIdp REST API.
    private func signInWithGoogleIdToken(_ googleIdToken: String) async throws {
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(Self.firebaseAPIKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "postBody": "id_token=\(googleIdToken)&providerId=google.com",
            "requestUri": "http://localhost",
            "returnSecureToken": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            logError("AuthService: Firebase signInWithIdp failed (status \(statusCode)): \(responseBody)")
            throw AuthError.serverError("Firebase signInWithIdp failed (status \(statusCode))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse
        }

        try processFirebaseAuthResponse(json, provider: "google")

        // Also sign in via Firebase SDK for auth state listener
        if let credential = GoogleAuthProvider.credential(withIDToken: googleIdToken, accessToken: "") as AuthCredential? {
            do {
                let result = try await Auth.auth().signIn(with: credential)
                log("AuthService: Firebase SDK sign-in successful (uid: \(result.user.uid))")
            } catch {
                // Non-fatal — the REST API token is sufficient
                log("AuthService: Firebase SDK sign-in failed (non-fatal): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Apple Sign-In

    /// Start Apple Sign-In using native ASAuthorizationController.
    func signInWithApple() async throws {
        AnalyticsManager.shared.signInStarted(provider: "apple")
        log("AuthService: Starting Apple Sign-In")

        let nonce = generateNonce()
        let hashedNonce = sha256(nonce)

        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self = self else {
                continuation.resume(throwing: AuthError.cancelled)
                return
            }

            let delegate = AuthServiceAppleSignInDelegate(nonce: nonce) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let (identityToken, fullName)):
                        do {
                            // Store name from Apple (only available on first sign-in)
                            if let givenName = fullName?.givenName, !givenName.isEmpty {
                                UserDefaults.standard.set(givenName, forKey: Self.kGivenName)
                            }
                            if let familyName = fullName?.familyName, !familyName.isEmpty {
                                UserDefaults.standard.set(familyName, forKey: Self.kFamilyName)
                            }
                            if let givenName = fullName?.givenName, !givenName.isEmpty {
                                let display = [fullName?.givenName, fullName?.familyName]
                                    .compactMap { $0 }
                                    .joined(separator: " ")
                                UserDefaults.standard.set(display, forKey: Self.kDisplayName)
                            }

                            try await self.signInWithAppleIdentityToken(identityToken, nonce: nonce)
                            AnalyticsManager.shared.signInCompleted(provider: "apple")
                            log("AuthService: Apple Sign-In completed successfully")
                            continuation.resume()
                        } catch {
                            AnalyticsManager.shared.signInFailed(provider: "apple", error: error.localizedDescription)
                            continuation.resume(throwing: error)
                        }
                    case .failure(let error):
                        AnalyticsManager.shared.signInFailed(provider: "apple", error: error.localizedDescription)
                        continuation.resume(throwing: error)
                    }
                }
            }

            self.appleSignInDelegate = delegate

            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.email, .fullName]
            request.nonce = hashedNonce

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = delegate
            controller.performRequests()
        }
    }

    /// Exchange Apple identity token with Firebase signInWithIdp REST API.
    private func signInWithAppleIdentityToken(_ identityToken: String, nonce: String) async throws {
        // Try Firebase REST API first
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(Self.firebaseAPIKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "postBody": "id_token=\(identityToken)&providerId=apple.com&nonce=\(nonce)",
            "requestUri": "http://localhost",
            "returnSecureToken": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            try processFirebaseAuthResponse(json, provider: "apple")
        } else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            log("AuthService: Firebase REST API signInWithIdp failed (status \(statusCode)), trying Firebase SDK fallback")
        }

        // Also sign in via Firebase SDK as fallback / for auth state listener
        let credential = OAuthProvider.appleCredential(
            withIDToken: identityToken,
            rawNonce: nonce,
            fullName: nil
        )
        do {
            let result = try await Auth.auth().signIn(with: credential)
            log("AuthService: Firebase SDK Apple sign-in successful (uid: \(result.user.uid))")

            // If REST API failed, use the SDK result
            if self.idToken == nil {
                let token = try await result.user.getIDToken()
                self.idToken = token
                self.userId = result.user.uid
                self.userEmail = result.user.email
                self.tokenExpiry = Date().addingTimeInterval(3600) // 1 hour
                self.saveAuthState()
                self.updateAuthState()
            }
        } catch {
            // If REST API also failed, this is a real error
            if self.idToken == nil {
                logError("AuthService: Firebase SDK Apple sign-in also failed", error: error)
                throw AuthError.serverError("Apple sign-in failed: \(error.localizedDescription)")
            }
            // REST API succeeded, SDK failure is non-fatal
            log("AuthService: Firebase SDK Apple sign-in failed (non-fatal): \(error.localizedDescription)")
        }
    }

    // MARK: - Firebase Auth Response Processing

    /// Process the response from Firebase signInWithIdp REST API.
    private func processFirebaseAuthResponse(_ json: [String: Any], provider: String) throws {
        guard let idToken = json["idToken"] as? String,
              let refreshToken = json["refreshToken"] as? String,
              let localId = json["localId"] as? String else {
            logError("AuthService: Missing required fields in Firebase auth response")
            throw AuthError.invalidResponse
        }

        self.idToken = idToken
        self.refreshToken = refreshToken
        self.userId = localId

        // Parse expiry
        if let expiresIn = json["expiresIn"] as? String, let seconds = Double(expiresIn) {
            self.tokenExpiry = Date().addingTimeInterval(seconds)
        } else {
            self.tokenExpiry = Date().addingTimeInterval(3600) // Default 1 hour
        }

        // Extract email
        if let email = json["email"] as? String {
            self.userEmail = email
        }

        // Extract name from JWT if not already set
        if displayName.isEmpty {
            if let claims = decodeJWT(idToken) {
                if let name = claims["name"] as? String, !name.isEmpty {
                    UserDefaults.standard.set(name, forKey: Self.kDisplayName)
                }
                if let givenName = claims["given_name"] as? String, !givenName.isEmpty,
                   self.givenName.isEmpty {
                    UserDefaults.standard.set(givenName, forKey: Self.kGivenName)
                }
                if let familyName = claims["family_name"] as? String, !familyName.isEmpty,
                   self.familyName.isEmpty {
                    UserDefaults.standard.set(familyName, forKey: Self.kFamilyName)
                }
            }
        }

        saveAuthState()
        updateAuthState()
        setSentryUserContext()
        setPostHogUserContext()

        // Re-check session recording flag now that distinct_id is the Firebase UID
        SessionRecordingManager.shared.recheckAfterSignIn()

        log("AuthService: Firebase auth successful (provider: \(provider), userId: \(localId), email: \(userEmail ?? "nil"))")
    }

    // MARK: - Token Management

    /// Get a valid ID token, refreshing if necessary.
    func getIdToken(forceRefresh: Bool = false) async throws -> String {
        guard let currentToken = idToken, let _ = refreshToken else {
            throw AuthError.notSignedIn
        }

        let needsRefresh = forceRefresh ||
            (tokenExpiry != nil && tokenExpiry!.timeIntervalSinceNow < 300) // Refresh 5 min before expiry

        if needsRefresh {
            try await refreshIdToken()
        }

        guard let token = idToken else {
            throw AuthError.notSignedIn
        }

        return token
    }

    /// Get an Authorization header value with the current ID token.
    func getAuthHeader() async throws -> String {
        let token = try await getIdToken()
        return "Bearer \(token)"
    }

    /// Refresh the Firebase ID token using the refresh token.
    private func refreshIdToken() async throws {
        guard let currentRefreshToken = refreshToken else {
            throw AuthError.notSignedIn
        }

        let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(Self.firebaseAPIKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "grant_type=refresh_token&refresh_token=\(currentRefreshToken)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            logError("AuthService: Token refresh failed (status \(statusCode)): \(responseBody)")
            throw AuthError.tokenRefreshFailed("Status \(statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newIdToken = json["id_token"] as? String,
              let newRefreshToken = json["refresh_token"] as? String else {
            throw AuthError.tokenRefreshFailed("Invalid response")
        }

        self.idToken = newIdToken
        self.refreshToken = newRefreshToken

        if let expiresIn = json["expires_in"] as? String, let seconds = Double(expiresIn) {
            self.tokenExpiry = Date().addingTimeInterval(seconds)
        } else {
            self.tokenExpiry = Date().addingTimeInterval(3600)
        }

        saveAuthState()

        log("AuthService: Token refreshed successfully")
    }

    /// Start a timer that periodically checks and refreshes the token.
    private func startTokenRefreshTimer() {
        tokenRefreshTimer?.invalidate()
        tokenRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isSignedIn else { return }
                guard let expiry = self.tokenExpiry else { return }

                // Refresh if token expires within 5 minutes
                if expiry.timeIntervalSinceNow < 300 {
                    do {
                        try await self.refreshIdToken()
                    } catch {
                        log("AuthService: Background token refresh failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Sign Out

    func signOut() {
        log("AuthService: Signing out")

        // Clear stored tokens
        idToken = nil
        refreshToken = nil
        tokenExpiry = nil
        userId = nil
        userEmail = nil

        // Clear UserDefaults
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.kIdToken)
        defaults.removeObject(forKey: Self.kRefreshToken)
        defaults.removeObject(forKey: Self.kTokenExpiry)
        defaults.removeObject(forKey: Self.kTokenUserId)
        defaults.removeObject(forKey: Self.kUserEmail)
        defaults.removeObject(forKey: Self.kGivenName)
        defaults.removeObject(forKey: Self.kFamilyName)
        defaults.removeObject(forKey: Self.kDisplayName)

        // Sign out of Firebase SDK
        do {
            try Auth.auth().signOut()
        } catch {
            log("AuthService: Firebase SDK signOut error (non-fatal): \(error.localizedDescription)")
        }

        // Clear Sentry user context
        SentrySDK.setUser(nil)

        // Update AuthState
        updateAuthState()

        // Analytics
        AnalyticsManager.shared.signedOut()
        AnalyticsManager.shared.reset()

        // Post notification
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.fazm.desktop.userDidSignOut"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        log("AuthService: Signed out successfully")
    }

    // MARK: - Name Management

    func updateGivenName(_ name: String) async {
        UserDefaults.standard.set(name, forKey: Self.kGivenName)
        UserDefaults.standard.set(name, forKey: Self.kDisplayName)
        log("AuthService: Updated given name to: \(name)")
    }

    func updateDisplayName(_ name: String) {
        UserDefaults.standard.set(name, forKey: Self.kDisplayName)
    }

    func updateFamilyName(_ name: String) {
        UserDefaults.standard.set(name, forKey: Self.kFamilyName)
    }

    // MARK: - Auth State Persistence

    private func saveAuthState() {
        let defaults = UserDefaults.standard
        defaults.set(idToken, forKey: Self.kIdToken)
        defaults.set(refreshToken, forKey: Self.kRefreshToken)
        defaults.set(tokenExpiry, forKey: Self.kTokenExpiry)
        defaults.set(userId, forKey: Self.kTokenUserId)
        defaults.set(userEmail, forKey: Self.kUserEmail)
    }

    private func restoreAuthState() {
        let defaults = UserDefaults.standard
        idToken = defaults.string(forKey: Self.kIdToken)
        refreshToken = defaults.string(forKey: Self.kRefreshToken)
        tokenExpiry = defaults.object(forKey: Self.kTokenExpiry) as? Date
        userId = defaults.string(forKey: Self.kTokenUserId)
        userEmail = defaults.string(forKey: Self.kUserEmail)

        if isSignedIn {
            log("AuthService: Restored auth state (userId: \(userId ?? "nil"), email: \(userEmail ?? "nil"))")
            setSentryUserContext()
            setPostHogUserContext()
            // Don't call updateAuthState() here — AuthState.init() already restored
            // isSignedIn from UserDefaults synchronously. Calling updateAuthState() during
            // applicationDidFinishLaunching would mutate @Published properties while
            // SwiftUI's view graph is being laid out, causing an AttributeGraph crash.
        } else {
            log("AuthService: No saved auth state found")
        }
    }

    /// Update the shared AuthState singleton.
    private func updateAuthState() {
        AuthState.shared.update(isSignedIn: isSignedIn, userEmail: userEmail)
    }

    /// Set Sentry user context for crash reporting.
    private func setSentryUserContext() {
        guard let userId = userId else { return }
        let sentryUser = User(userId: userId)
        sentryUser.email = userEmail
        sentryUser.username = displayName.isEmpty ? nil : displayName
        SentrySDK.setUser(sentryUser)
    }

    /// Link authenticated user to PostHog for analytics attribution.
    func setPostHogUserContext() {
        guard let userId = userId else { return }
        var properties: [String: Any] = ["firebase_uid": userId]
        if let email = userEmail { properties["email"] = email }
        if !displayName.isEmpty { properties["name"] = displayName }
        PostHogManager.shared.identifyAuthUser(userId: userId, properties: properties)
    }

    // MARK: - Localhost HTTP Server for OAuth

    /// Create a listening socket on a random localhost port. Returns the socket FD and port.
    /// Caller is responsible for closing the socket when done.
    private func createLocalhostListener() throws -> (socketFD: Int32, port: UInt16) {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw AuthError.serverError("Failed to create socket")
        }

        var reuseAddr: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                Darwin.bind(socketFD, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(socketFD)
            throw AuthError.serverError("Failed to bind socket")
        }

        var boundAddr = sockaddr_in()
        var boundAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                getsockname(socketFD, ptr, &boundAddrLen)
            }
        }
        let port = UInt16(bigEndian: boundAddr.sin_port)

        guard Darwin.listen(socketFD, 1) == 0 else {
            Darwin.close(socketFD)
            throw AuthError.serverError("Failed to listen on socket")
        }

        return (socketFD, port)
    }

    /// Wait for an OAuth callback on the given listening socket. Blocks until a request arrives.
    private func waitForOAuthCallback(socketFD: Int32) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                defer { Darwin.close(socketFD) }

                let clientFD = accept(socketFD, nil, nil)
                guard clientFD >= 0 else {
                    continuation.resume(throwing: AuthError.cancelled)
                    return
                }
                defer { Darwin.close(clientFD) }

                var buffer = [UInt8](repeating: 0, count: 4096)
                let bytesRead = recv(clientFD, &buffer, buffer.count, 0)
                guard bytesRead > 0 else {
                    continuation.resume(throwing: AuthError.invalidResponse)
                    return
                }

                let requestString = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

                var code: String?
                var errorMessage: String?

                if let firstLine = requestString.components(separatedBy: "\r\n").first,
                   let urlPart = firstLine.components(separatedBy: " ").dropFirst().first,
                   let urlComponents = URLComponents(string: "http://localhost\(urlPart)") {
                    code = urlComponents.queryItems?.first(where: { $0.name == "code" })?.value
                    errorMessage = urlComponents.queryItems?.first(where: { $0.name == "error" })?.value
                }

                let responseHTML: String
                if code != nil {
                    responseHTML = """
                    <html>
                    <head><meta charset="utf-8"><title>Fazm — Signed In</title></head>
                    <body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #0F0F0F; color: white;">
                    <div style="text-align: center; max-width: 400px; padding: 40px;">
                    <div style="width: 64px; height: 64px; margin: 0 auto 24px; background: linear-gradient(135deg, #8B5CF6, #7C3AED); border-radius: 16px; display: flex; align-items: center; justify-content: center; font-size: 32px;">&#10003;</div>
                    <h1 style="margin: 0 0 8px; font-size: 24px; font-weight: 700;">You're in!</h1>
                    <p style="margin: 0 0 32px; color: #888; font-size: 15px; line-height: 1.5;">Sign-in successful. Returning you to Fazm&hellip;</p>
                    <a href="fazm://auth-success" style="display: inline-block; padding: 12px 32px; background: linear-gradient(135deg, #8B5CF6, #7C3AED); color: white; text-decoration: none; border-radius: 10px; font-size: 15px; font-weight: 600;">Open Fazm</a>
                    <p style="margin-top: 16px; color: #555; font-size: 12px;">This tab will close automatically.</p>
                    <script>
                    setTimeout(function() { window.location.href = 'fazm://auth-success'; }, 1500);
                    setTimeout(function() { window.close(); }, 3000);
                    </script>
                    </div></body></html>
                    """
                } else {
                    responseHTML = """
                    <html>
                    <head><meta charset="utf-8"><title>Fazm — Sign-In Failed</title></head>
                    <body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #0F0F0F; color: white;">
                    <div style="text-align: center; max-width: 400px; padding: 40px;">
                    <div style="width: 64px; height: 64px; margin: 0 auto 24px; background: #2A2A2A; border-radius: 16px; display: flex; align-items: center; justify-content: center; font-size: 32px;">&#10007;</div>
                    <h1 style="margin: 0 0 8px; font-size: 24px; font-weight: 700;">Sign-in failed</h1>
                    <p style="margin: 0 0 32px; color: #888; font-size: 15px; line-height: 1.5;">\(errorMessage ?? "Something went wrong. Please try again.")</p>
                    <a href="fazm://auth-failed" style="display: inline-block; padding: 12px 32px; background: #2A2A2A; color: white; text-decoration: none; border-radius: 10px; font-size: 15px; font-weight: 600; border: 1px solid #333;">Back to Fazm</a>
                    </div></body></html>
                    """
                }

                let htmlData = Data(responseHTML.utf8)
                let httpHeader = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(htmlData.count)\r\nConnection: close\r\n\r\n"
                let fullResponse = Data(httpHeader.utf8) + htmlData
                fullResponse.withUnsafeBytes { ptr in
                    _ = send(clientFD, ptr.baseAddress!, ptr.count, 0)
                }
                // Graceful shutdown so the browser receives all data before close
                shutdown(clientFD, SHUT_WR)
                usleep(100_000) // 100ms for browser to read

                if let code = code {
                    continuation.resume(returning: code)
                } else {
                    continuation.resume(throwing: AuthError.serverError(errorMessage ?? "No auth code received"))
                }
            }
        }
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncoded()
    }

    // MARK: - Nonce Helpers (Apple Sign-In)

    private func generateNonce(length: Int = 32) -> String {
        precondition(length > 0)
        var bytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if errorCode != errSecSuccess {
            fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
        }
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - JWT Decoding

    /// Decode a JWT and return the payload claims (best-effort, no signature verification).
    private func decodeJWT(_ jwt: String) -> [String: Any]? {
        let segments = jwt.components(separatedBy: ".")
        guard segments.count >= 2 else { return nil }

        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Pad to multiple of 4
        while base64.count % 4 != 0 {
            base64 += "="
        }

        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - AppleSignInDelegate

/// Delegate for ASAuthorizationController that handles Apple Sign-In callbacks for AuthService.
class AuthServiceAppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate {
    private let nonce: String
    private let completion: (Result<(String, PersonNameComponents?), Error>) -> Void

    init(nonce: String, completion: @escaping (Result<(String, PersonNameComponents?), Error>) -> Void) {
        self.nonce = nonce
        self.completion = completion
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityTokenData = appleIDCredential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8) else {
            completion(.failure(AuthError.invalidResponse))
            return
        }

        let fullName = appleIDCredential.fullName
        log("AuthService: Apple Sign-In authorization received (email: \(appleIDCredential.email ?? "hidden"))")
        completion(.success((identityToken, fullName)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let asError = error as? ASAuthorizationError
        if asError?.code == .canceled {
            log("AuthService: Apple Sign-In cancelled by user")
            completion(.failure(AuthError.cancelled))
        } else {
            logError("AuthService: Apple Sign-In failed", error: error)
            completion(.failure(error))
        }
    }
}

// MARK: - Data Extension for Base64 URL Encoding

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
