import AuthenticationServices
import CryptoKit
import SwiftUI

struct AppleSignInButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var message: String?
    @State private var nonce = ""
    @State private var pending: PendingSignIn?
    @State private var username = ""
    @State private var usernameMessage: String?
    @State private var saving = false

    // What Apple returned for a sign-in the server will not finish until it
    // has a username. Apple's token only lasts a few minutes.
    private struct PendingSignIn {
        let identityToken: String
        let authorizationCode: String?
        let user: String
    }

    // The server's answer when Apple shared no name and the account has none.
    private static let usernameRequired = 428

    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SignInWithAppleButton(.signIn) { request in
                // Apple signs the hash into its token and the server checks it
                // against the nonce itself, so a token Apple issued for some
                // other request cannot be used to sign in here.
                nonce = UUID().uuidString + UUID().uuidString
                request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
                    Task { await signIn(credential) }
                case .failure(let error):
                    if (error as? ASAuthorizationError)?.code != .canceled {
                        message = error.localizedDescription
                    }
                }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 44)
            EGErrorText(text: message)
        }
        // Closing the sheet abandons the sign-in; no account exists yet.
        .sheet(isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            EGSheetFrame(title: "Choose a Username", subtitle: "One more step to finish signing in.") {
                Text("Your username identifies your account to the people who run the leaderboards. Other users don't see it; the name on each post is still yours to type.")
                    .egFont(13)
                    .fixedSize(horizontal: false, vertical: true)
                EGFormField(label: "USERNAME", placeholder: "Your name or a nickname", text: $username)
                EGErrorText(text: usernameMessage)
                Button("FINISH SIGNING IN") {
                    guard let pending else { return }
                    Task { await finish(pending, name: trimmedUsername) }
                }
                .buttonStyle(EGButtonStyle(kind: .primary))
                .disabled(saving || trimmedUsername.isEmpty)
            }
            .interactiveDismissDisabled()
        }
    }

    private func signIn(_ credential: ASAuthorizationAppleIDCredential) async {
        guard let identityToken = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
            message = "Apple did not return a sign-in token."
            return
        }
        // Apple only fills the name in the first time this Apple ID signs in.
        let shared = credential.fullName
            .map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
            .flatMap { $0.isEmpty ? nil : $0 }
        if let shared {
            DeviceIdentity.appleName = shared
        }
        await finish(
            PendingSignIn(
                identityToken: identityToken,
                authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
                user: credential.user
            ),
            name: shared ?? DeviceIdentity.appleName
        )
    }

    private func finish(_ signIn: PendingSignIn, name: String?) async {
        saving = true
        defer { saving = false }
        do {
            try await model.signIn(
                identityToken: signIn.identityToken,
                nonce: nonce,
                authorizationCode: signIn.authorizationCode,
                name: name
            )
            DeviceIdentity.appleUser = signIn.user
            pending = nil
            message = nil
        } catch let error as APIError where error.status == Self.usernameRequired {
            if pending == nil, username.isEmpty {
                username = model.posterName
            }
            // Only a username the person typed can have been turned down.
            usernameMessage = pending == nil ? nil : "That username isn't allowed. Try another."
            message = nil
            pending = signIn
        } catch {
            // An expired token cannot be retried, so the Apple button comes back.
            pending = nil
            message = error.localizedDescription
        }
    }
}

struct SignInView: View {
    var body: some View {
        EGSheetFrame(title: "Sign In to Post", subtitle: "Browsing never needs an account.") {
            Text("Signing in with Apple ties your leaderboards and times to you instead of this phone, so you can still edit them after a reinstall or on a new phone.")
                .egFont(13)
                .fixedSize(horizontal: false, vertical: true)
            AppleSignInButton()
        }
    }
}

// Shown after sign-in when Apple shared no name to use as the username.
struct UsernameView: View {
    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var message: String?
    @State private var saving = false

    private var trimmed: String { username.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        EGSheetFrame(title: "Choose a Username", subtitle: "One more step before you post.") {
            Text("Your username identifies your account to the people who run the leaderboards. Other users don't see it; the name on each post is still yours to type.")
                .egFont(13)
                .fixedSize(horizontal: false, vertical: true)
            EGFormField(label: "USERNAME", placeholder: "Your name or a nickname", text: $username)
            EGErrorText(text: message)
            Button("CONTINUE") {
                Task { await save() }
            }
            .buttonStyle(EGButtonStyle(kind: .primary))
            .disabled(saving || trimmed.isEmpty)
        }
        .onAppear {
            if username.isEmpty { username = model.posterName }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await model.updateAccountName(trimmed)
        } catch {
            message = error.localizedDescription
        }
    }
}

struct AccountSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingDelete = false
    @State private var message: String?
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        if model.signedIn {
            Text("Signed in with Apple. Your username identifies your account and is filled in as your name when you post; other users only see the name on each post.")
                .egFont(11)
                .foregroundStyle(Color.egGrayDark)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Username (needed to post)", text: $name)
                    .egFont(12)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(Color.egCard)
                    .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 1))
                    .focused($nameFocused)
                    .onSubmit(saveName)
                Button("SAVE", action: saveName)
                    .buttonStyle(EGChipButtonStyle())
                    .disabled(trimmedName.isEmpty || trimmedName == model.account?.name)
            }
            .task(id: model.account?.name) {
                name = model.account?.name ?? ""
            }
            HStack(spacing: 8) {
                Button("SIGN OUT") {
                    run {
                        try await model.signOut()
                        DeviceIdentity.appleUser = nil
                    }
                }
                Button("DELETE ACCOUNT") {
                    confirmingDelete = true
                }
            }
            .buttonStyle(EGButtonStyle())
            .confirmationDialog(
                "Delete your account?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Account and Posts", role: .destructive) {
                    run {
                        try await model.deleteAccount()
                        DeviceIdentity.appleUser = nil
                        DeviceIdentity.appleName = nil
                    }
                }
            } message: {
                Text("This deletes every leaderboard you created, including other people's times on them, and every time you posted. It cannot be undone.")
            }
            EGErrorText(text: message)
        } else {
            Text("Sign in to post, and to keep your leaderboards and times if you reinstall or change phones.")
                .egFont(11)
                .foregroundStyle(Color.egGrayDark)
                .fixedSize(horizontal: false, vertical: true)
            AppleSignInButton()
        }
    }

    private func saveName() {
        nameFocused = false
        guard !trimmedName.isEmpty else { return }
        run { try await model.updateAccountName(trimmedName) }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                message = nil
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

// Someone can stop using their Apple ID with the app from the Settings app,
// and Apple only says so when asked. Sign-ins made before the identifier was
// kept are not checked.
struct AppleCredentialWatcher: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: scenePhase) {
                if scenePhase == .active { await check() }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)
            ) { _ in
                Task { await check() }
            }
    }

    private func check() async {
        guard let user = DeviceIdentity.appleUser,
              let state = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: user),
              state == .revoked else { return }
        do {
            try await model.signOut()
            DeviceIdentity.appleUser = nil
        } catch {
            // Still signed in on the server, so the next activation tries again.
        }
    }
}
