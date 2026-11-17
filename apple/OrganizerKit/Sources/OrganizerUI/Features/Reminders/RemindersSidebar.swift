import OrganizerAPI
import OrganizerCore
import SwiftUI

/// The views and lists column: Today, Upcoming and All, then each account's lists with their color,
/// a lock when read-only, and the open count; each source's last sync at the foot.
struct RemindersSidebar: View {
    @Bindable var store: RemindersStore
    @Binding var scope: RemindersScope

    var body: some View {
        List(selection: Binding<RemindersScope?>(get: { scope }, set: { if let next = $0 { scope = next } })) {
            Section {
                row(.today, "Today", systemImage: "star")
                row(.upcoming, "Upcoming", systemImage: "calendar")
                row(.all, "All", systemImage: "tray")
            }
            ForEach(store.listGroups) { group in
                Section(group.title) {
                    ForEach(group.lists, id: \.id) { list in
                        listRow(list)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RemindersSourceAges(status: store.status.value)
        }
        .accessibilityIdentifier("reminders.sidebar")
    }

    private func row(_ target: RemindersScope, _ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .badge(store.openCount(for: target))
            .tag(target)
            .accessibilityIdentifier("reminders.scope.\(target.storageKey)")
    }

    private func listRow(_ list: ReminderListOut) -> some View {
        Label {
            HStack(spacing: 4) {
                Text(list.title)
                    .lineLimit(1)
                if !list.writable {
                    Image(systemName: "lock.fill")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                        .help("Read-only in \(RemindersProvider.name(list.source))")
                        .accessibilityLabel("read-only")
                }
            }
        } icon: {
            Image(systemName: "circle.fill")
                .foregroundStyle(Palette.hex(list.color) ?? Palette.source("reminders"))
                .imageScale(.small)
        }
        .badge(store.openCount(for: .list(list.id)))
        .tag(RemindersScope.list(list.id))
        .accessibilityIdentifier("reminders.scope.list:\(list.id)")
    }
}

/// How old each source's copy is: the Mac helper's last push and each Google account's poll.
struct RemindersSourceAges: View {
    let status: ReminderStatusOut?

    private var rows: [(id: String, label: String, freshness: SourceStatusOut)] {
        guard let status else { return [] }
        var rows: [(id: String, label: String, freshness: SourceStatusOut)] = []
        if status.helper.state != .never {
            rows.append(("helper", "Mac helper", status.helper))
        }
        for account in status.google {
            rows.append(("google:\(account.accountId)", account.label, account.freshness))
        }
        return rows
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Divider().padding(.bottom, 4)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rows, id: \.id) { row in
                            HStack(spacing: 6) {
                                ColorDot(Palette.status(row.freshness.state.rawValue), size: 6)
                                Text(row.label)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(RemindersSyncSummary.freshness(row.freshness, now: context.date))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                            .help(help(row.freshness))
                        }
                    }
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("reminders.sourceAges")
        }
    }

    private func help(_ freshness: SourceStatusOut) -> String {
        var text = freshness.lastSuccessAt.map { "Last synced \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not synced yet"
        if freshness.state == .error, let error = freshness.lastError { text += " · \(error)" }
        return text
    }
}

/// The module's sync status (web: HelperBanner and the Sync button): the queue, whether the Mac
/// helper is polling, each source's freshness, and Sync Now.
struct RemindersStatusPanel: View {
    @Bindable var store: RemindersStore

    var body: some View {
        let status = store.status.value
        let summary = RemindersSyncSummary(status)
        VStack(alignment: .leading, spacing: 10) {
            Label(summary.title, systemImage: summary.systemImage)
                .font(.headline)
                .foregroundStyle(remindersToneColor(summary.tone))
            if let status {
                VStack(alignment: .leading, spacing: 4) {
                    if let queue = RemindersSyncSummary.queueLine(status) {
                        Text(queue)
                    }
                    if status.helper.state != .never || status.pendingOps > 0 {
                        Text(RemindersSyncSummary.helperLine(status))
                    }
                    if status.waitingForDevice {
                        Text("Apple Reminders changes will apply when your Mac is awake and the helper is running.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                RemindersSourceAges(status: status)
                    .padding(.horizontal, -12)
                    .padding(.bottom, -10)
            } else if let error = store.status.state.error {
                Text(error.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button {
                    Task { await store.syncNow() }
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.isSyncing)
                .accessibilityIdentifier("reminders.status.syncNow")
            }
        }
        .padding()
        .frame(width: 320)
    }
}

func remindersToneColor(_ tone: RemindersSyncSummary.Tone) -> Color {
    switch tone {
    case .ok: Palette.status(.ok)
    case .busy: Palette.mutedForeground
    case .waiting: Palette.status(.stale)
    case .failed: Palette.status(.error)
    }
}
