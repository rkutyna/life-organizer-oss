import OrganizerAPI
import OrganizerCore
import SwiftUI

/// The first-launch sheet: the server address and an API token, checked before they are saved.
///
/// Shown while no token is set (neither `ORGANIZER_TOKEN` nor a saved one). "Later" closes it;
/// Settings has the same fields.
struct FirstLaunchView: View {
    @Environment(AppEnvironment.self) private var app
    let done: () -> Void

    @State private var address = UserDefaults.standard.string(forKey: ServerConfig.settingsKey) ?? ""
    @State private var token = ""
    @State private var outcome: ConnectionCheck.Outcome?
    @State private var checking = false
    @State private var saveError: String?

    private var url: URL? {
        address.trimmingCharacters(in: .whitespaces).isEmpty ? ServerConfig.defaultURL : ServerConfig.normalize(address)
    }
    private var typedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect to your organizer")
                    .font(.title2.weight(.semibold))
                Text("This app shows your own Life Organizer server. Enter its address, and an API token you make in the web app: **Settings → API tokens**, author **You**, scopes **API** and **Mail**.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                TextField("Server address", text: $address, prompt: Text(ServerConfig.defaultURL.absoluteString))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("setup.address")
                SecureField("API token", text: $token, prompt: Text("Paste the token"))
                    .accessibilityIdentifier("setup.token")
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 110)

            if url == nil {
                Text("Enter an http:// or https:// address with a host.")
                    .font(.footnote)
                    .foregroundStyle(Palette.status(.error))
            }
            if let url, ServerConfig.isInsecureRemote(url) {
                Label("Plain http to another machine sends the token unencrypted. Prefer https.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Palette.status(.stale))
            }
            if checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                }
            } else if let outcome, let url {
                ConnectionOutcomeView(url: url, outcome: outcome)
            }
            if let saveError {
                Text(saveError)
                    .font(.footnote)
                    .foregroundStyle(Palette.status(.error))
            }

            HStack {
                Button("Later", action: done)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Check and Save") {
                    Task { await checkAndSave() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url == nil || typedToken.isEmpty || checking)
                .accessibilityIdentifier("setup.save")
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    /// Saves only when the check passed; a token without the mail scope is saved too (the rest
    /// of the app works), with the warning left on screen.
    private func checkAndSave() async {
        guard let url else { return }
        checking = true
        let result = await ConnectionCheck(client: app.testClient(baseURL: url, token: typedToken)).run()
        checking = false
        outcome = result
        guard case .connected(_, let mail) = result else { return }
        do {
            try app.tokenStore.save(typedToken)
            ServerConfig.saveSettingsURL(address.trimmingCharacters(in: .whitespaces).isEmpty ? nil : address)
            app.reloadServer()
            if mail { done() }
        } catch {
            saveError = error.localizedDescription
        }
    }
}
