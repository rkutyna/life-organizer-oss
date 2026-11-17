import OrganizerAPI
import OrganizerCore
import SwiftUI

/// Settings: which server the app talks to and with which token (with a connection test), the
/// cache, and about. Also the app's Settings window (⌘,), General tab.
struct SettingsScreen: View {
    var body: some View {
        ModuleNavigationStack {
            SettingsForm()
                .navigationTitle("Settings")
        }
    }
}

/// The form itself, shared by the Settings module and the Mac Settings window.
public struct SettingsForm: View {
    @Environment(AppEnvironment.self) private var app
    @State private var address = UserDefaults.standard.string(forKey: ServerConfig.settingsKey) ?? ""
    @State private var token = ""
    @State private var tokenError: String?
    @State private var test: ConnectionTest = .idle
    @State private var cacheBytes = 0
    @State private var accessID = ""
    @State private var accessSecret = ""
    @State private var accessError: String?

    public init() {}

    enum ConnectionTest {
        case idle
        case running(URL)
        case finished(URL, ConnectionCheck.Outcome)
    }

    private var typedURL: URL? { ServerConfig.normalize(address) }
    private var addressIsInvalid: Bool { !address.trimmingCharacters(in: .whitespaces).isEmpty && typedURL == nil }
    private var savedAddress: String { UserDefaults.standard.string(forKey: ServerConfig.settingsKey) ?? "" }
    private var typedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var body: some View {
        Form {
            Section("Server in use") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.server.url.absoluteString)
                        .textSelection(.enabled)
                    Text(app.server.source.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("API token", value: app.tokenSource.label)
                if ServerConfig.isInsecureRemote(app.server.url) {
                    Label("Plain http to another machine sends the token unencrypted. Use https (Tailscale or a tunnel, docs/SETUP.md).",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Palette.status(.stale))
                }
            }

            Section {
                TextField("Address", text: $address, prompt: Text(ServerConfig.defaultURL.absoluteString))
                    .autocorrectionDisabled()
                    .onSubmit(saveAddress)
                    .accessibilityIdentifier("settings.address")
                if addressIsInvalid {
                    Text("Enter an http:// or https:// address with a host.")
                        .font(.footnote)
                        .foregroundStyle(Palette.status(.error))
                }
                HStack {
                    Button("Save Address", action: saveAddress)
                        .disabled(addressIsInvalid || address == savedAddress)
                    Spacer()
                    Button("Use Default") {
                        address = ""
                        saveAddress()
                    }
                    .disabled(savedAddress.isEmpty)
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Server address")
            } footer: {
                if app.server.source == .environment {
                    Text("\(ServerConfig.environmentKey) is set at launch, so it wins over the address saved here.")
                } else {
                    Text("Your organizer's address, as you open it in a browser. Blank uses the default: \(ServerConfig.defaultURL.absoluteString).")
                }
            }

            Section {
                SecureField("Token", text: $token, prompt: Text("Paste a new token"))
                    .onSubmit(saveToken)
                    .accessibilityIdentifier("settings.token")
                if let tokenError {
                    Text(tokenError)
                        .font(.footnote)
                        .foregroundStyle(Palette.status(.error))
                }
                HStack {
                    Button("Save Token", action: saveToken)
                        .disabled(typedToken.isEmpty)
                    Spacer()
                    Button("Forget Token", role: .destructive, action: forgetToken)
                        .disabled(app.tokenSource != .keychain)
                }
                .buttonStyle(.borderless)
            } header: {
                Text("API token")
            } footer: {
                if app.tokenSource == .environment {
                    Text("\(ServerConfig.tokenEnvironmentKey) is set at launch, so it wins over a saved token.")
                } else {
                    Text("Make one in the web app: Settings → API tokens, author \"me\", scopes api and mail. It is kept in your Keychain and never shown again.")
                }
            }

            Section {
                Button {
                    Task { await runTest() }
                } label: {
                    Label("Test Connection", systemImage: "network")
                }
                .disabled(isTesting || addressIsInvalid)
                .accessibilityIdentifier("settings.test")
                testResult
            } footer: {
                Text("Uses the address and token typed above, else the ones in use.")
            }

            Section {
                LabeledContent("In use", value: app.accessSource.label)
                TextField("Client ID", text: $accessID, prompt: Text("…access"))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.accessID")
                SecureField("Client secret", text: $accessSecret, prompt: Text(app.accessSource == .saved ? "Saved; paste to replace" : "Paste the secret"))
                    .accessibilityIdentifier("settings.accessSecret")
                if let accessError {
                    Text(accessError)
                        .font(.footnote)
                        .foregroundStyle(Palette.status(.error))
                }
                HStack {
                    Button("Save Access Token", action: saveAccess)
                        .disabled(!accessIsSavable)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        accessID = ""
                        accessSecret = ""
                        saveAccess()
                    }
                    .disabled(app.savedAccessClientID.isEmpty)
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Advanced: Cloudflare Access service token")
            } footer: {
                if app.accessSource == .environment {
                    Text("\(ServerConfig.accessIDEnvironmentKey) and \(ServerConfig.accessSecretEnvironmentKey) are set at launch, so they win over what is saved here.")
                } else {
                    Text("Only if your organizer is behind Cloudflare Access: a service token lets the app through. Both values are sent on every request, with the API token. The secret is kept in your Keychain.")
                }
            }

            Section("Data") {
                LabeledContent("Cached responses", value: cacheBytes.formatted(.byteCount(style: .file)))
                Button("Clear Cached Data", role: .destructive) {
                    app.cache.removeAll()
                    cacheBytes = app.cache.size()
                }
            }

            Section("About") {
                LabeledContent("Version", value: Self.version)
                OpenInWebLink(path: "/", title: "Open the Web App")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            cacheBytes = app.cache.size()
            accessID = app.savedAccessClientID
        }
    }

    /// A new id needs a secret unless one is saved already; an unchanged id with a new secret
    /// replaces the secret.
    private var accessIsSavable: Bool {
        let id = accessID.trimmingCharacters(in: .whitespaces)
        let secret = accessSecret.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return false }
        if !secret.isEmpty { return true }
        return id != app.savedAccessClientID && app.accessSource == .saved
    }

    private func saveAccess() {
        do {
            try app.saveAccess(clientID: accessID, clientSecret: accessSecret)
            accessSecret = ""
            accessError = nil
            test = .idle
        } catch {
            accessError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch test {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
            }
        case .finished(let url, let outcome):
            ConnectionOutcomeView(url: url, outcome: outcome)
        }
    }

    private var isTesting: Bool {
        if case .running = test { return true }
        return false
    }

    private func saveAddress() {
        guard !addressIsInvalid else { return }
        ServerConfig.saveSettingsURL(address)
        address = savedAddress
        app.reloadServer()
        test = .idle
        cacheBytes = app.cache.size()
    }

    private func saveToken() {
        guard !typedToken.isEmpty else { return }
        do {
            try app.tokenStore.save(typedToken)
            token = ""
            tokenError = nil
            app.reloadServer()
            test = .idle
        } catch {
            tokenError = error.localizedDescription
        }
    }

    private func forgetToken() {
        do {
            try app.tokenStore.delete()
            tokenError = nil
            app.reloadServer()
        } catch {
            tokenError = error.localizedDescription
        }
    }

    private func runTest() async {
        let url = typedURL ?? app.server.url
        test = .running(url)
        let client = app.testClient(baseURL: url, token: typedToken.isEmpty ? app.currentToken() : typedToken)
        test = .finished(url, await ConnectionCheck(client: client).run())
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}

/// One Test Connection result: a green check or a red cross, and what to do.
struct ConnectionOutcomeView: View {
    let url: URL
    let outcome: ConnectionCheck.Outcome

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if outcome.isSuccess {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.status(.ok))
            } else {
                Label("Couldn't connect", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Palette.status(.error))
            }
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.testResult")
    }

    private var detail: String {
        if case .connected(let status, _) = outcome {
            return "\(url.host() ?? url.absoluteString) · version \(status.version) · \(status.timezone). \(outcome.message)"
        }
        return "\(url.absoluteString): \(outcome.message)"
    }
}

#Preview {
    SettingsScreen().environment(AppEnvironment.preview())
}
