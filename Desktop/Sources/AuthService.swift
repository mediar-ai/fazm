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
    case oauthTimeout

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in"
        case .unauthorized: return "Unauthorized"
        case .tokenRefreshFailed(let msg): return "Token refresh failed: \(msg)"
        case .invalidResponse: return "Invalid response from server"
        case .serverError(let msg): return "Server error: \(msg)"
        case .cancelled: return "Sign in was cancelled"
        case .oauthTimeout: return "Sign-in timed out. Try again."
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

    // Google Desktop OAuth client secrets are non-confidential per Google's docs.
    // Hardcoded here instead of bundling in .env to reduce secret exposure surface.
    private static let googleClientSecret = "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"

    // MARK: - UserDefaults Keys

    private static let kIdToken = "auth_idToken"
    private static let kRefreshToken = "auth_refreshToken"
    private static let kTokenExpiry = "auth_tokenExpiry"
    private static let kTokenUserId = "auth_tokenUserId"
    private static let kUserEmail = "auth_userEmail"
    private static let kGivenName = "user_givenName"
    private static let kFamilyName = "user_familyName"
    private static let kDisplayName = "user_displayName"
    /// Persisted flag set by `signInAnonymously` and cleared by a successful
    /// linkWithIdp upgrade or signOut. Used because Firebase's SDK
    /// `Auth.auth().currentUser` is unreliable in this app's signing
    /// configuration (the app lacks `keychain-access-groups` entitlements, so
    /// SDK keychain writes fail). Authoritative source for `isAnonymous`.
    private static let kIsAnonymous = "auth_isAnonymous"

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

    /// Whether the current user was created via `signInAnonymously` (the
    /// `signin-optional` experiment's variant-B path) and hasn't yet upgraded
    /// to a named account via REST link. Persisted in UserDefaults rather
    /// than read from `Auth.auth().currentUser?.isAnonymous` because the
    /// Firebase SDK can't reliably keep `currentUser` in this app's signing
    /// configuration (no `keychain-access-groups` entitlement → SDK keychain
    /// writes fail). The REST flow drives the app's notion of auth state, so
    /// we track anon-ness alongside it.
    var isAnonymous: Bool {
        return UserDefaults.standard.bool(forKey: Self.kIsAnonymous)
    }

    // MARK: - Private State

    private var tokenRefreshTimer: Timer?
    private var appleSignInDelegate: AuthServiceAppleSignInDelegate?
    private var firebaseAuthStateListener: AuthStateDidChangeListenerHandle?
    private var googleSignInSocketFD: Int32?

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
                    // Persist Firebase creation date and sync trial start
                    if let creationDate = user.metadata.creationDate {
                        UserDefaults.standard.set(creationDate, forKey: "fazm_firebase_creation_date")
                    }

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
                    // Re-link PostHog identity on every auth state change. The initial
                    // identify attempts at restoreAuthState() (too early, PostHog SDK not
                    // initialized) and FazmApp.applicationDidFinishLaunching (might fire
                    // before Firebase restores userId asynchronously) can both miss.
                    // identifyAuthUser is idempotent for the same user (line 112 in
                    // PostHogManager short-circuits to $set), so calling it again is safe
                    // and ensures the device UUID gets linked to firebase_uid + email
                    // exactly once the auth state is fully restored.
                    if self.userId != nil {
                        self.setPostHogUserContext()
                    }
                } else {
                    log("AuthService: Firebase auth state changed - no user")
                }
            }
        }

        // Start token refresh timer (every 30 seconds, checks if refresh is needed)
        startTokenRefreshTimer()

        // Reconcile any auth state desync deferred past initial SwiftUI layout
        // (mutating @Published state during layout would crash AttributeGraph).
        DispatchQueue.main.async { [weak self] in
            self?.reconcileAuthState()
        }

        log("AuthService: Configured, isSignedIn=\(isSignedIn), userId=\(userId ?? "nil")")
    }

    // MARK: - Google Sign-In (Desktop OAuth + Firebase)

    /// Start Google Sign-In using Desktop OAuth flow with localhost redirect.
    /// When the current user is anonymous (variant B of the `signin-optional`
    /// experiment), `signInWithGoogleIdToken` transparently turns the REST
    /// signInWithIdp call into a server-side link so the anon UID and all
    /// its data are preserved — no separate code path needed here.
    func signInWithGoogle() async throws {
        AnalyticsManager.shared.signInStarted(provider: "google")
        log("AuthService: Starting Google Sign-In (Desktop OAuth)\(isAnonymous ? " — will link to existing anon UID" : "")")

        let googleIdToken: String
        do {
            googleIdToken = try await acquireGoogleIdTokenViaDesktopOAuth(analyticsProvider: "google")
        } catch {
            throw error
        }

        // Exchange Google id_token with Firebase signInWithIdp
        try await signInWithGoogleIdToken(googleIdToken)

        AnalyticsManager.shared.signInCompleted(provider: "google")
        log("AuthService: Google Sign-In completed successfully")
    }

    /// Run the Google Desktop-OAuth dance (PKCE + localhost callback + token
    /// exchange) and return the resulting Google id_token. Extracted from the
    /// signInWithGoogle method body so future sign-in variants (anonymous
    /// upgrades, etc.) can reuse the dance and only differ in the final
    /// REST exchange. `analyticsProvider` lets callers attribute failures.
    private func acquireGoogleIdTokenViaDesktopOAuth(analyticsProvider: String) async throws -> String {
        // 1. Generate PKCE code verifier + challenge
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        // 2. Start temporary localhost HTTP server
        let (socketFD, port) = try createLocalhostListener()
        self.googleSignInSocketFD = socketFD
        defer { self.googleSignInSocketFD = nil }
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
            // Force the Google account chooser. Without this, a browser signed
            // into a single Google account auto-selects it, so a user who
            // signed in with the wrong account can never switch.
            URLQueryItem(name: "prompt", value: "select_account"),
        ]

        guard let authURL = urlComponents.url else {
            Darwin.close(socketFD)
            throw AuthError.invalidResponse
        }

        log("AuthService: Opening Google OAuth URL in default browser")
        NSWorkspace.shared.open(authURL)

        // 4. Wait for the callback on localhost (capture the auth code)
        let authCode: String
        do {
            authCode = try await waitForOAuthCallback(socketFD: socketFD)
        } catch {
            AnalyticsManager.shared.signInFailed(provider: analyticsProvider, error: error.localizedDescription)
            throw error
        }

        log("AuthService: Received auth code from Google OAuth callback")

        // 5. Exchange the code with Google's token endpoint for an id_token
        return try await exchangeGoogleCode(authCode, codeVerifier: codeVerifier, redirectURI: redirectURI)
    }

    /// Cancel an in-flight Google sign-in by shutting down the localhost listener.
    /// Causes the blocked `poll()`/`accept()` to return so `waitForOAuthCallback`
    /// throws `AuthError.cancelled`. Safe to call when no sign-in is in flight.
    func cancelGoogleSignIn() {
        guard let fd = googleSignInSocketFD else { return }
        googleSignInSocketFD = nil
        log("AuthService: Cancelling in-flight Google Sign-In")
        // shutdown() wakes the blocked poll/accept; close() stays owned by waitForOAuthCallback's defer.
        Darwin.shutdown(fd, SHUT_RDWR)
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
    /// When the current user is anonymous (variant B of the `signin-optional`
    /// experiment), we pass the existing idToken in the request body so the
    /// server LINKS the Google credential to that anon UID instead of
    /// creating a brand-new user — preserves trial state, Stripe customer,
    /// chat history, PostHog person, everything.
    ///
    /// If the link fails because the Google account is already bound to
    /// another Firebase user (`FEDERATED_USER_ID_ALREADY_LINKED` /
    /// `EMAIL_EXISTS`), we retry without the `idToken` field — that signs the
    /// user into their existing account, abandoning the anon UID. This is
    /// the right UX: the user picked that Google identity on purpose, so
    /// give them their real account back rather than blocking them.
    private func signInWithGoogleIdToken(_ googleIdToken: String) async throws {
        let attemptingLink = isAnonymous && self.idToken != nil
        // Capture the anon user's identity BEFORE the call. If the link fails
        // and we fall back to plain sign-in, we'll use these to self-delete
        // the orphan from Firebase Auth so the analytics dashboard doesn't
        // accumulate ghost rows.
        let orphanCandidateUid = attemptingLink ? self.userId : nil
        let orphanCandidateIdToken = attemptingLink ? self.idToken : nil

        var json = try await callFirebaseSignInWithIdp(
            googleIdToken: googleIdToken,
            linkToExistingIdToken: attemptingLink ? self.idToken : nil
        )

        // If a link attempt failed because the credential is already in use
        // by another Firebase user, retry as a fresh sign-in (no idToken).
        // The anon UID gets orphaned but the user lands in their real account.
        var didFallBack = false
        if attemptingLink, let errorCode = json["__errorCode__"] as? String,
           errorCode.contains("FEDERATED_USER_ID_ALREADY_LINKED") ||
           errorCode.contains("EMAIL_EXISTS") ||
           errorCode.contains("CREDENTIAL_ALREADY_IN_USE") {
            log("AuthService: link rejected (\(errorCode)) — Google account already on another Firebase user; falling back to plain sign-in (anon UID will be deleted)")
            json = try await callFirebaseSignInWithIdp(
                googleIdToken: googleIdToken,
                linkToExistingIdToken: nil
            )
            didFallBack = true
        }

        if let errorCode = json["__errorCode__"] as? String {
            // Either a non-recoverable link error or a plain-sign-in error.
            throw AuthError.serverError("Firebase signInWithIdp failed: \(errorCode)")
        }

        try processFirebaseAuthResponse(json, provider: "google")

        // Fallback succeeded: delete the orphaned anon Firebase user so it
        // doesn't sit in Auth forever cluttering the analytics dashboard with
        // ghost rows. Uses the anon user's OWN idToken to authorize the
        // self-delete (REST /accounts:delete acts on the token bearer's UID),
        // so we don't need any backend or Firebase Admin SDK changes. Fire and
        // forget — if it fails we just have one stale row, not a real problem.
        if didFallBack,
           let anonUid = orphanCandidateUid,
           let anonIdToken = orphanCandidateIdToken,
           anonUid != self.userId {
            Task.detached { [weak self] in
                await self?.deleteOrphanedAnonymousUser(anonUid: anonUid, anonIdToken: anonIdToken)
            }
        }

        // Also sign in via Firebase SDK for auth state listener
        if let credential = GoogleAuthProvider.credential(withIDToken: googleIdToken, accessToken: "") as AuthCredential? {
            do {
                let result = try await Auth.auth().signIn(with: credential)
                log("AuthService: Firebase SDK sign-in successful (uid: \(result.user.uid))")
                if let creationDate = result.user.metadata.creationDate {
                    UserDefaults.standard.set(creationDate, forKey: "fazm_firebase_creation_date")
                    log("AuthService: Stored Firebase creation date: \(creationDate)")
                }
            } catch {
                // Non-fatal — the REST API token is sufficient
                log("AuthService: Firebase SDK sign-in failed (non-fatal): \(error.localizedDescription)")
            }
        }
    }

    /// Self-delete a Firebase user via REST `/v1/accounts:delete`. The
    /// endpoint deletes the user identified by the supplied idToken — so we
    /// can clean up an orphaned anonymous account without any backend or
    /// Firebase Admin SDK plumbing. Called after the link-conflict fallback
    /// signs the user into their existing named account, to keep the dashboard
    /// clean of "ghost" anon UIDs from variant-B users who already had an
    /// account. Errors are logged but never thrown — a stale row is better
    /// than a broken sign-in.
    private func deleteOrphanedAnonymousUser(anonUid: String, anonIdToken: String) async {
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:delete?key=\(Self.firebaseAPIKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["idToken": anonIdToken]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            log("AuthService: deleteOrphanedAnonymousUser body encode failed: \(error.localizedDescription)")
            return
        }
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            if statusCode == 200 {
                log("AuthService: deleted orphaned anon UID \(anonUid)")
                PostHogManager.shared.track("anonymous_account_orphan_deleted", properties: [
                    "uid": anonUid
                ])
            } else {
                let body = String(data: data, encoding: .utf8) ?? ""
                log("AuthService: orphan-delete returned HTTP \(statusCode) for \(anonUid): \(body)")
            }
        } catch {
            log("AuthService: orphan-delete network error for \(anonUid): \(error.localizedDescription)")
        }
    }

    /// Single REST call to `/accounts:signInWithIdp`. Returns the parsed JSON
    /// on success; on a 400 error, returns a dict with `__errorCode__` set to
    /// the Firebase error code so the caller can decide whether to retry
    /// (e.g. fall back from link to plain sign-in when the credential is
    /// already in use). Throws only on transport / parse / non-400 server
    /// failures.
    private func callFirebaseSignInWithIdp(
        googleIdToken: String,
        linkToExistingIdToken: String?
    ) async throws -> [String: Any] {
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(Self.firebaseAPIKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "postBody": "id_token=\(googleIdToken)&providerId=google.com",
            "requestUri": "http://localhost",
            "returnSecureToken": true,
        ]
        if let existingIdToken = linkToExistingIdToken {
            body["idToken"] = existingIdToken
            log("AuthService: signInWithIdp — link mode (anon UID will be upgraded if Google account is free)")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        if httpResponse.statusCode == 400 {
            // Surface the Firebase error code to the caller instead of
            // throwing, so the caller can decide whether to retry. Firebase
            // returns { "error": { "message": "FEDERATED_USER_ID_ALREADY_LINKED", … } }.
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            log("AuthService: signInWithIdp returned 400: \(responseBody)")
            if let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errObj = errJson["error"] as? [String: Any],
               let message = errObj["message"] as? String {
                return ["__errorCode__": message]
            }
            return ["__errorCode__": "UNKNOWN_400"]
        }

        guard httpResponse.statusCode == 200 else {
            let statusCode = httpResponse.statusCode
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            logError("AuthService: Firebase signInWithIdp failed (status \(statusCode)): \(responseBody)")
            throw AuthError.serverError("Firebase signInWithIdp failed (status \(statusCode))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse
        }
        return json
    }

    // MARK: - Magic Link (Email OTP) Sign-In

    /// Request a magic-link OTP for the given email address.
    /// Backend generates a 6-digit code, stores it hashed in Firestore, and sends it via Resend.
    func requestMagicLinkCode(email: String) async throws {
        AnalyticsManager.shared.signInStarted(provider: "magic_link")
        log("AuthService: Requesting magic-link code for email")

        let backendUrl = Self.backendBaseURL()
        guard !backendUrl.isEmpty else {
            throw AuthError.serverError("Backend URL not configured")
        }

        let url = URL(string: "\(backendUrl)/api/auth/magic-link/request")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email])
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            logError("AuthService: Magic-link request failed (status \(httpResponse.statusCode)): \(body)")
            // Map backend message into the error so the UI can show it.
            let friendly = !body.isEmpty ? body : "Failed to send code"
            if httpResponse.statusCode == 429 {
                throw AuthError.serverError(friendly)
            }
            throw AuthError.serverError(friendly)
        }

        log("AuthService: Magic-link code sent")
    }

    /// Verify a magic-link OTP and complete sign-in.
    /// Exchanges the code with the backend for a Firebase custom token, then exchanges
    /// that for an ID/refresh token via Firebase REST `signInWithCustomToken`.
    ///
    /// When the user is currently anonymous (variant-B of the `signin-optional`
    /// experiment), magic-link can't preserve the anon UID — Firebase has no
    /// "link via custom token" path, so the new sign-in necessarily creates or
    /// signs into a different Firebase user. We capture the anon UID + idToken
    /// before the new sign-in and self-delete the orphan once it lands, so the
    /// analytics dashboard doesn't accumulate ghost rows.
    func verifyMagicLinkCode(email: String, code: String) async throws {
        log("AuthService: Verifying magic-link code\(isAnonymous ? " (anon UID will be deleted after upgrade)" : "")")

        // Snapshot anon identity before the new sign-in overwrites self.idToken.
        let orphanCandidateUid = isAnonymous ? self.userId : nil
        let orphanCandidateIdToken = isAnonymous ? self.idToken : nil

        let backendUrl = Self.backendBaseURL()
        guard !backendUrl.isEmpty else {
            throw AuthError.serverError("Backend URL not configured")
        }

        let url = URL(string: "\(backendUrl)/api/auth/magic-link/verify")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "code": code])
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "Invalid code"
            logError("AuthService: Magic-link verify failed (status \(httpResponse.statusCode)): \(body)")
            AnalyticsManager.shared.signInFailed(provider: "magic_link", error: body)
            throw AuthError.serverError(body)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let customToken = json["custom_token"] as? String else {
            AnalyticsManager.shared.signInFailed(provider: "magic_link", error: "invalid_response")
            throw AuthError.invalidResponse
        }
        let backendUid = json["uid"] as? String
        let backendEmail = (json["email"] as? String) ?? email

        try await signInWithCustomToken(customToken, expectedUid: backendUid, expectedEmail: backendEmail)

        AnalyticsManager.shared.signInCompleted(provider: "magic_link")
        log("AuthService: Magic-link sign-in completed successfully")

        // Anon UID was abandoned by the new sign-in (different localId). Fire
        // the self-delete via the anon's own idToken so the orphan doesn't
        // sit in Firebase Auth. Same pattern as the Google link-conflict
        // fallback; non-fatal if it fails.
        if let anonUid = orphanCandidateUid,
           let anonIdToken = orphanCandidateIdToken,
           anonUid != self.userId {
            Task.detached { [weak self] in
                await self?.deleteOrphanedAnonymousUser(anonUid: anonUid, anonIdToken: anonIdToken)
            }
        }
    }

    /// Exchange a Firebase custom token for an ID/refresh token pair via the
    /// `accounts:signInWithCustomToken` REST endpoint, then run the standard
    /// post-auth pipeline.
    ///
    /// Note: `accounts:signInWithCustomToken` does NOT include `localId` or
    /// `email` in its response (unlike `signInWithIdp`). We inject the known
    /// UID/email from the backend so `processFirebaseAuthResponse` can persist
    /// them via the shared path used by Google/Apple sign-in.
    private func signInWithCustomToken(_ customToken: String, expectedUid: String?, expectedEmail: String?) async throws {
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=\(Self.firebaseAPIKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "token": customToken,
            "returnSecureToken": true,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            logError("AuthService: signInWithCustomToken failed (status \(statusCode)): \(responseBody)")
            throw AuthError.serverError("signInWithCustomToken failed (status \(statusCode))")
        }

        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse
        }

        // Firebase's `accounts:signInWithCustomToken` REST endpoint returns
        // only `idToken`, `refreshToken`, and `expiresIn` (no `localId`, no
        // `email`). `processFirebaseAuthResponse` requires `localId`, so we
        // inject it from one of three sources, in order of preference:
        //   1. Backend response (we trust our own verify endpoint).
        //   2. The idToken JWT's `user_id` / `sub` claim.
        //   3. Nothing — and `processFirebaseAuthResponse` will throw.
        if json["localId"] == nil {
            if let uid = expectedUid, !uid.isEmpty {
                json["localId"] = uid
            } else if let idToken = json["idToken"] as? String,
                      let claims = decodeJWT(idToken),
                      let uid = (claims["user_id"] as? String) ?? (claims["sub"] as? String) {
                json["localId"] = uid
            }
        }
        if json["email"] == nil {
            if let email = expectedEmail, !email.isEmpty {
                json["email"] = email
            } else if let idToken = json["idToken"] as? String,
                      let claims = decodeJWT(idToken),
                      let email = claims["email"] as? String {
                json["email"] = email
            }
        }

        try processFirebaseAuthResponse(json, provider: "magic_link")

        // Also sign in via Firebase SDK for the auth state listener.
        do {
            let result = try await Auth.auth().signIn(withCustomToken: customToken)
            log("AuthService: Firebase SDK custom-token sign-in successful (uid: \(result.user.uid))")
            if let creationDate = result.user.metadata.creationDate {
                UserDefaults.standard.set(creationDate, forKey: "fazm_firebase_creation_date")
            }
        } catch {
            // Non-fatal — the REST API tokens we just stored are enough for the backend.
            log("AuthService: Firebase SDK signInWithCustomToken failed (non-fatal): \(error.localizedDescription)")
        }
    }

    /// Resolve `FAZM_BACKEND_URL` from the runtime environment (trimming trailing slashes).
    private static func backendBaseURL() -> String {
        if let raw = ProcessInfo.processInfo.environment["FAZM_BACKEND_URL"], !raw.isEmpty {
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if let cstr = getenv("FAZM_BACKEND_URL"), let s = String(cString: cstr, encoding: .utf8), !s.isEmpty {
            return s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return ""
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
            if let creationDate = result.user.metadata.creationDate {
                UserDefaults.standard.set(creationDate, forKey: "fazm_firebase_creation_date")
                log("AuthService: Stored Firebase creation date: \(creationDate)")
            }

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

    // MARK: - Anonymous Sign-In

    /// Sign in anonymously via the Firebase REST API — no UI, no browser, no
    /// user input. Gives the device a real Firebase UID + idToken so backend
    /// calls work without forcing the user through Google/Apple sign-in.
    ///
    /// Uses REST `/accounts:signUp` (without email/password = anonymous)
    /// instead of the Firebase SDK's `signInAnonymously()` because the SDK
    /// writes tokens to the Keychain and this app lacks the
    /// `keychain-access-groups` entitlement → SDK keychain writes throw and
    /// the sign-in fails. The REST flow mirrors how Google/Apple sign-in
    /// already work in this codebase.
    ///
    /// Used by the `signin-optional` PostHog experiment: variant B starts new
    /// users with an anonymous account on first launch. If they later upgrade
    /// (via `signInWithGoogle()` while anon), the REST link path preserves
    /// the same UID and all backend data.
    func signInAnonymously() async throws {
        let attemptId = UUID().uuidString
        PostHogManager.shared.track("anonymous_signin_started", properties: [
            "attempt_id": attemptId
        ])
        AnalyticsManager.shared.signInStarted(provider: "anonymous")
        log("AuthService: Starting anonymous sign-in via REST signUp")
        // Trial start is keyed in UserDefaults per-device, not per-user. If a
        // previous (named) user was signed in on this device, their stored
        // `fazm_trial_start_date` would carry over to the new anon user —
        // making the trial already-expired and firing the paywall immediately
        // even though this is effectively a fresh signup. Reset before sign-up
        // so fetchAccountCreationDate, called later, sets it from the new
        // anon user's Firebase creation timestamp (= now).
        UserDefaults.standard.removeObject(forKey: "fazm_trial_start_date")
        UserDefaults.standard.removeObject(forKey: "fazm_firebase_creation_date")

        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(Self.firebaseAPIKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Empty body with returnSecureToken: true creates an anonymous user.
        let body: [String: Any] = ["returnSecureToken": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let responseBody = String(data: data, encoding: .utf8) ?? ""
                logError("AuthService: anonymous sign-up REST failed (status \(statusCode)): \(responseBody)")
                AnalyticsManager.shared.signInFailed(provider: "anonymous", error: "HTTP \(statusCode): \(responseBody)")
                throw AuthError.serverError("Anonymous sign-up failed (status \(statusCode))")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AuthError.invalidResponse
            }

            try processFirebaseAuthResponse(json, provider: "anonymous")
            AnalyticsManager.shared.signInCompleted(provider: "anonymous")
            PostHogManager.shared.track("anonymous_signin_completed", properties: [
                "attempt_id": attemptId
            ])
            log("AuthService: anonymous sign-in completed (uid: \(self.userId ?? "?"))")
        } catch {
            PostHogManager.shared.track("anonymous_signin_failed", properties: [
                "attempt_id": attemptId,
                "error": String(error.localizedDescription.prefix(500))
            ])
            AnalyticsManager.shared.signInFailed(provider: "anonymous", error: error.localizedDescription)
            logError("AuthService: anonymous sign-in failed", error: error)
            throw error
        }
    }

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

        // Detect anon→named upgrade. If we were anonymous and now we're not,
        // the user just completed the upgrade flow (paywall or Settings) and
        // we should refresh the cached pricing variant (UID-hash bucket may
        // differ from email-hash bucket) and emit the analytics event.
        let wasAnonymous = UserDefaults.standard.bool(forKey: Self.kIsAnonymous)
        let isNowAnonymous = (provider == "anonymous")
        UserDefaults.standard.set(isNowAnonymous, forKey: Self.kIsAnonymous)
        if wasAnonymous && !isNowAnonymous {
            log("AuthService: anon→named upgrade detected (provider=\(provider))")
            PostHogManager.shared.track("anonymous_account_upgraded", properties: [
                "provider": provider
            ])
            // Re-fetch the variant so the post-link paywall + checkout use the
            // user's email-hash bucket instead of the pre-link UID-hash bucket.
            // SubscriptionService caches the result; openCheckout reads it.
            Task { await SubscriptionService.shared.fetchVariantPrice() }
        }

        saveAuthState()
        updateAuthState()
        setSentryUserContext()
        setPostHogUserContext()

        // Fetch API keys from backend now that user is authenticated
        Task { await KeyService.shared.fetchKeys() }

        // Re-check session recording flag now that distinct_id is the Firebase UID
        SessionRecordingManager.shared.recheckAfterSignIn()

        log("AuthService: Firebase auth successful (provider: \(provider), userId: \(localId), email: \(userEmail ?? "nil"))")
    }

    // MARK: - Token Management

    /// Get a valid ID token, refreshing if necessary.
    func getIdToken(forceRefresh: Bool = false) async throws -> String {
        guard let _ = idToken, let _ = refreshToken else {
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
            if Self.isPermanentRefreshFailure(statusCode: statusCode, body: responseBody) {
                log("AuthService: refresh token revoked (status \(statusCode)); signing out for re-auth")
                signOut()
                throw AuthError.tokenRefreshFailed("revoked")
            }
            if statusCode == 403 {
                // Misconfigured build (e.g. source build without FIREBASE_API_KEY):
                // Google Secure Token rejects with "unregistered callers". Retrying
                // can never succeed, so stop the background timer instead of looping
                // every 30s and flooding Sentry (FAZM-170). Local log only.
                log("AuthService: token refresh rejected with 403 (missing/invalid API key); stopping refresh timer")
                tokenRefreshTimer?.invalidate()
                tokenRefreshTimer = nil
                throw AuthError.tokenRefreshFailed("misconfigured_api_key")
            }
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

    /// A refresh-token failure that will never recover without the user re-authenticating.
    /// Firebase returns 400 with messages like TOKEN_EXPIRED or INVALID_REFRESH_TOKEN
    /// when the refresh token is revoked; OAuth peers use `invalid_grant`.
    private static func isPermanentRefreshFailure(statusCode: Int, body: String) -> Bool {
        guard statusCode == 400 || statusCode == 401 else { return false }
        let markers = [
            "TOKEN_EXPIRED",
            "INVALID_REFRESH_TOKEN",
            "USER_DISABLED",
            "USER_NOT_FOUND",
            "CREDENTIAL_TOO_OLD_LOGIN_AGAIN",
            "invalid_grant",
        ]
        return markers.contains(where: { body.contains($0) })
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

        // Stop the refresh timer so we don't keep ticking after sign-out
        tokenRefreshTimer?.invalidate()
        tokenRefreshTimer = nil

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
        defaults.removeObject(forKey: Self.kIsAnonymous)

        // Clear cached subscription state so the next user doesn't inherit
        // the previous user's `isActive` flag if refreshStatus() fails on
        // sign-in. The sign-in task in DesktopHomeView calls refreshStatus()
        // which repopulates from the backend.
        SubscriptionService.shared.resetForSignOut()

        // Sign out of Firebase SDK
        do {
            try Auth.auth().signOut()
        } catch {
            log("AuthService: Firebase SDK signOut error (non-fatal): \(error.localizedDescription)")
        }

        // Clear Sentry user context
        SentrySDK.setUser(nil)

        // Reset PostHog identity so post-signOut anonymous activity does not
        // get attributed to the user who just signed out. Without this, if
        // another user signs in on the same device, the brief anonymous window
        // between signOut and the next identify aliases to the previous user.
        PostHogManager.shared.reset()
        log("AuthService: PostHog identity reset on sign-out")

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
            Task { await KeyService.shared.fetchKeys() }
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
        AuthState.shared.update(
            isSignedIn: isSignedIn,
            userEmail: userEmail,
            isAnonymous: isAnonymous
        )
    }

    /// Detect and fix auth state desync: the UserDefaults `auth_isSignedIn` flag is set
    /// but actual tokens are missing. UI thinks user is signed in, network layer disagrees,
    /// so any token-using button silently fails (e.g. Upgrade in Settings).
    /// Triggered at launch (deferred), on foreground, and on AuthError.notSignedIn at call sites.
    func reconcileAuthState() {
        let stored = UserDefaults.standard.bool(forKey: "auth_isSignedIn")
        guard stored && !isSignedIn else { return }
        log("AuthService: auth state desync detected (stored=true, tokens missing); signing out")
        signOut()
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
        guard let userId = userId else {
            log("AuthService: setPostHogUserContext skipped — userId is nil")
            return
        }
        var properties: [String: Any] = ["firebase_uid": userId]
        if let email = userEmail { properties["email"] = email }
        if !displayName.isEmpty { properties["name"] = displayName }
        if let creationDate = Auth.auth().currentUser?.metadata.creationDate {
            let formatter = ISO8601DateFormatter()
            properties["created_at"] = formatter.string(from: creationDate)
        }
        log("AuthService: setPostHogUserContext — userId=\(userId), email=\(userEmail ?? "nil")")
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
        _ = withUnsafeMutablePointer(to: &boundAddr) {
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

    /// Wait for an OAuth callback on the given listening socket.
    /// Waits up to `timeoutSeconds` (default 5 min) for an incoming connection.
    /// Throws `AuthError.oauthTimeout` on timeout, `AuthError.cancelled` if the
    /// socket is shut down externally (e.g. via `cancelGoogleSignIn()`).
    private func waitForOAuthCallback(socketFD: Int32, timeoutSeconds: Int = 300) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                defer { Darwin.close(socketFD) }

                // Wait up to timeoutSeconds for the OAuth redirect to hit the listener.
                // poll() is interruptible: shutdown(fd, SHUT_RDWR) from cancelGoogleSignIn
                // returns POLLHUP/POLLNVAL so the user can abort without waiting the full timeout.
                var pollFD = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
                let pollResult = withUnsafeMutablePointer(to: &pollFD) { ptr in
                    poll(ptr, 1, Int32(timeoutSeconds * 1000))
                }
                if pollResult == 0 {
                    continuation.resume(throwing: AuthError.oauthTimeout)
                    return
                }
                if pollResult < 0 || (pollFD.revents & Int16(POLLIN)) == 0 {
                    continuation.resume(throwing: AuthError.cancelled)
                    return
                }

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
