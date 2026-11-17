import OrganizerCore
import SwiftUI

/// "Open in web": a link to the same page of the web app, on the server the app uses.
///
///     OpenInWebLink(path: "/jobs/applications/\(application.id)")
///     .toolbar { OpenInWebLink(path: "/jobs").labelStyle(.iconOnly) }
public struct OpenInWebLink: View {
    @Environment(AppEnvironment.self) private var app
    let path: String
    let title: String

    public init(path: String, title: String = "Open in Web") {
        self.path = path
        self.title = title
    }

    public var body: some View {
        Link(destination: app.webURL(path)) {
            Label(title, systemImage: "safari")
        }
    }
}
