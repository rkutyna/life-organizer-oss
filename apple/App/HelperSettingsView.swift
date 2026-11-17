import HelperCore
import OrganizerCore
import OrganizerUI
import SwiftUI

/// Settings → Helper: run the Mac helper inside the app (off by default).
struct HelperSettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @Bindable var helper: InAppHelper
    @State private var enabled = UserDefaults.standard.bool(forKey: InAppHelper.enabledKey)
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("Run the Mac helper in this app", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        Task { await helper.setEnabled(on, app: app) }
                    }
                phaseLine
            } footer: {
                Text("It sends Apple Calendar and Apple Reminders to your organizer and applies the reminder changes you make there, while this app is open. It reads no mail, contacts or files. Use it instead of the command-line helper's LaunchAgent, not beside it.")
            }

            Section {
                LabeledContent("Token", value: helper.hasToken ? "Saved in the Keychain" : "Not set")
                SecureField("Ingest token", text: $token, prompt: Text("Paste a token with the ingest scope"))
                HStack {
                    Button("Save Token") {
                        do {
                            try helper.saveToken(token)
                            token = ""
                            error = nil
                            Task { await helper.restart(app: app) }
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    Button("Forget Token", role: .destructive) {
                        try? helper.forgetToken()
                    }
                    .disabled(!helper.hasToken)
                }
                .buttonStyle(.borderless)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Palette.status(.error))
                }
            } header: {
                Text("Helper token")
            } footer: {
                Text("A separate token from the app's: in the web app, Settings → API tokens, author \"helper\", scope ingest only.")
            }

            Section {
                LabeledContent("Calendars", value: label(helper.calendars))
                LabeledContent("Reminders", value: label(helper.reminders))
                Button("Request Access") {
                    Task { await helper.requestAccess() }
                }
                .disabled(!helper.calendars.canRequest && !helper.reminders.canRequest)
            } header: {
                Text("Permissions")
            } footer: {
                Text("macOS asks once per app. A build signed to run locally (no team) counts as a new app after each rebuild, so macOS may ask again. To change an answer: System Settings → Privacy & Security → Calendars or Reminders.")
            }

            if let status = helper.status, !status.streams.isEmpty {
                Section("Streams") {
                    ForEach(status.streams.keys.sorted(), id: \.self) { name in
                        let stream = status.streams[name]!
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.body.weight(.medium))
                            Text(stream.last_result ?? "not run yet")
                                .font(.footnote)
                                .foregroundStyle(stream.last_error == nil ? Color.secondary : Palette.status(.error))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { helper.refreshInfo() }
    }

    @ViewBuilder
    private var phaseLine: some View {
        switch helper.phase {
        case .off:
            Label("Off", systemImage: "pause.circle").foregroundStyle(.secondary)
        case .running:
            Label("Running", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.status(.ok))
        case .refused(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.status(.error))
        }
    }

    private func label(_ access: HelperAuthorization) -> String {
        switch access {
        case .fullAccess: "Full access"
        case .notDetermined: "Not asked yet"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .writeOnly: "Add only (needs full access)"
        case .unknown: "Unknown"
        }
    }
}
