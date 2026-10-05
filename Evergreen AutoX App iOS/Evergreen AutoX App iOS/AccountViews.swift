import AuthenticationServices
import CryptoKit
import SwiftUI

struct AppleSignInButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var message: String?
    @State private var nonce = ""

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
        let name = shared ?? DeviceIdentity.appleName
        do {
            try await model.signIn(
                identityToken: identityToken,
                nonce: nonce,
                authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
                name: name
            )
            DeviceIdentity.appleUser = credential.user
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

struct SignInView: View {
    var body: some View {
        EGSheetFrame(title: "Sign In to Post", subtitle: "Browsing never needs an account.") {
            Text("Signing in with Apple ties your leaderboards and times to you instead of this phone, so you can still edit them after a reinstall or on a new phone.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            AppleSignInButton()
        }
    }
}

struct AccountSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingDelete = false
    @State private var message: String?
    @State private var name = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        if model.signedIn {
            Text("Signed in with Apple. Your name is filled in for you when you post; you can still change it on each post.")
                .font(.system(size: 11))
                .foregroundStyle(Color.egGrayDark)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Your name", text: $name)
                    .font(.system(size: 12))
                    .autocorrectionDisabled()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(Color.egCard)
                    .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 1))
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
                .font(.system(size: 11))
                .foregroundStyle(Color.egGrayDark)
                .fixedSize(horizontal: false, vertical: true)
            AppleSignInButton()
        }
    }

    private func saveName() {
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
