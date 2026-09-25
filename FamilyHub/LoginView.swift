import SwiftUI

struct LoginView: View {
    @Environment(AppStore.self) private var store

    @State private var server = FamilyConfig.defaultServer
    @State private var user = ""
    @State private var password = ""
    @State private var mfaCode = ""
    @State private var mfaFlow: String?
    @State private var useToken = false
    @State private var token = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "house.and.flag.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.indigo.gradient)
                        Text("Familie Mohs").font(.title.bold())
                        Text("Melde dich mit deinem Home-Assistant-Benutzer an.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section("Server") {
                    TextField("https://…", text: $server)
                        .keyboardType(.URL).textContentType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }

                if useToken {
                    Section {
                        SecureField("Langlebiges Zugriffs-Token", text: $token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("Token") } footer: {
                        Text("In Home Assistant: Profil → Sicherheit → Langlebige Zugriffs-Tokens → Token erstellen.")
                    }
                } else if mfaFlow != nil {
                    Section("Zwei-Faktor-Code") {
                        TextField("6-stelliger Code", text: $mfaCode)
                            .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    }
                } else {
                    Section("Anmeldung") {
                        TextField("Benutzername", text: $user)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Passwort", text: $password)
                            .textContentType(.password)
                    }
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if working { ProgressView() } else { Text("Anmelden").bold() }
                            Spacer()
                        }
                    }
                    .disabled(working || !canSubmit)
                }

                Section {
                    Button(useToken ? "Mit Benutzername anmelden" : "Stattdessen mit Token anmelden") {
                        useToken.toggle(); error = nil; mfaFlow = nil
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var canSubmit: Bool {
        if useToken { return !token.isEmpty }
        if mfaFlow != nil { return !mfaCode.isEmpty }
        return !user.isEmpty && !password.isEmpty
    }

    private func submit() async {
        working = true; error = nil
        defer { working = false }
        do {
            if useToken {
                try await store.loginWithToken(server: server, token: token)
            } else {
                try await store.login(server: server, user: user, password: password,
                                      mfa: mfaFlow == nil ? nil : mfaCode, flow: mfaFlow)
            }
            password = ""; mfaCode = ""; mfaFlow = nil
        } catch HAError.mfaRequired(let flow) {
            mfaFlow = flow
        } catch {
            self.error = error.localizedDescription
        }
    }
}
