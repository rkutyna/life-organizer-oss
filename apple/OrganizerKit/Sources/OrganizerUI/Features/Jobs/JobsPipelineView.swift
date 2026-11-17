import OrganizerAPI
import OrganizerCore
import SwiftUI

/// The pipeline: counts by current status (active, then closed) and how far applications got,
/// with leads and interviews apart. Counts only, never rates (docs/JOBS.md). A status row opens
/// the applications with that status.
struct JobsPipelineView: View {
    let store: JobsStore

    var body: some View {
        LoadingScaffold(status: store.status(.pipeline), refresh: { await store.refresh(.pipeline) }) {
            if let pipeline = store.pipeline.value {
                content(pipeline)
            }
        }
    }

    private func content(_ pipeline: PipelineOut) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                stats(pipeline)
                HStack(alignment: .top, spacing: 18) {
                    card("By status", footer: "Each application counts once, at its current status.") {
                        byStatus(pipeline)
                    }
                    card("How far applications got", footer: "Applications whose history reached this stage or a later one.") {
                        reached(pipeline)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("jobs.pipeline")
    }

    // MARK: Stats

    private func stats(_ pipeline: PipelineOut) -> some View {
        HStack(spacing: 12) {
            stat("Applications", pipeline.total, systemImage: "tray.full") { store.showApplications(status: nil) }
            stat("Open leads", pipeline.leads.open, systemImage: "lightbulb") { store.section = .leads }
            stat("Dropped leads", pipeline.leads.dropped, systemImage: "xmark.bin") {
                store.setIncludeDroppedLeads(true)
                store.section = .leads
            }
            stat("Interviews", pipeline.interviews.records, systemImage: "person.wave.2") { store.section = .interviews }
            stat("Interviewed at", pipeline.interviews.applications, systemImage: "checkmark.seal", caption: "applications", action: nil)
        }
    }

    private func stat(_ title: String, _ value: Int, systemImage: String, caption: String? = nil, action: (() -> Void)?) -> some View {
        let tile = VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value, format: .number)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)

        return Group {
            if let action {
                Button(action: action) { tile }
                    .buttonStyle(.plain)
                    .help("Show \(title.lowercased())")
            } else {
                tile
            }
        }
    }

    // MARK: Cards

    private func card<Content: View>(_ title: String, footer: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }

    @ViewBuilder
    private func byStatus(_ pipeline: PipelineOut) -> some View {
        let max = pipeline.byStatus.map(\.count).max() ?? 0
        let groups: [(String, String)] = [("active", "Active"), ("closed", "Closed")]
        if pipeline.byStatus.isEmpty {
            Text("No applications yet")
                .foregroundStyle(.secondary)
        }
        ForEach(groups, id: \.0) { kind, title in
            let rows = pipeline.byStatus.filter { $0.kind == kind }
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(title) · \(rows.reduce(0) { $0 + $1.count })")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(rows, id: \.status) { row in
                        Button {
                            store.showApplications(status: row.status)
                        } label: {
                            JobsCountBar(label: row.label, count: row.count, max: max, tone: JobsTone.kind(raw: row.kind))
                        }
                        .buttonStyle(.plain)
                        .help("Show applications: \(row.label)")
                        .accessibilityIdentifier("jobs.pipeline.status.\(row.status)")
                    }
                }
            }
        }
        // A kind this build does not know still counts.
        let others = pipeline.byStatus.filter { $0.kind != "active" && $0.kind != "closed" }
        ForEach(others, id: \.status) { row in
            JobsCountBar(label: row.label, count: row.count, max: max, tone: JobsTone.kind(raw: row.kind))
        }
    }

    @ViewBuilder
    private func reached(_ pipeline: PipelineOut) -> some View {
        let max = pipeline.reached.map(\.count).max() ?? 0
        if pipeline.reached.isEmpty {
            Text("No stages yet")
                .foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(pipeline.reached, id: \.status) { row in
                JobsCountBar(label: row.label, count: row.count, max: max, tone: Palette.primary)
            }
        }
    }
}

/// One labelled bar whose length is its count against the largest in its group.
struct JobsCountBar: View {
    let label: String
    let count: Int
    let max: Int
    let tone: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(tone)
                        .frame(width: width(in: proxy.size.width))
                }
            }
            .frame(height: 8)
            Text(count, format: .number)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .font(.callout)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(count)")
    }

    private func width(in total: CGFloat) -> CGFloat {
        guard max > 0, count > 0 else { return 0 }
        return Swift.max(6, total * CGFloat(count) / CGFloat(max))
    }
}
