import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var coordinator: HealthExportCoordinator
    @State private var showsFolderPicker = false
    @State private var sharedFile: SharedFile?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    statusCard
                    syncCard
                    exportCard
                    connectionCard
                    privacyCard
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L10n.text("home.title"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showsFolderPicker) {
                FolderPicker { url in
                    showsFolderPicker = false
                    Task { await coordinator.selectExportFolder(url) }
                }
            }
            .sheet(item: $sharedFile) { item in
                ActivityView(items: [item.url])
            }
        }
        .task {
            await coordinator.checkDirectSyncConnection()
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.red.gradient)
                    .frame(width: 84, height: 84)
                Image(systemName: "heart.text.clipboard.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text(L10n.text("home.hero.title"))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.text("home.hero.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var statusCard: some View {
        VStack(spacing: 0) {
            statusRow(
                icon: coordinator.hasRequestedAuthorization ? "checkmark.shield.fill" : "shield.lefthalf.filled",
                color: coordinator.hasRequestedAuthorization ? .green : .orange,
                title: L10n.text("home.status.health_access"),
                value: coordinator.hasRequestedAuthorization
                    ? L10n.text("home.status.requested")
                    : L10n.text("home.status.not_requested")
            )
            Divider().padding(.leading, 44)
            statusRow(
                icon: coordinator.exportLocation?.isSelectedFolder == true ? "icloud.fill" : "folder.fill",
                color: coordinator.exportLocation?.isSelectedFolder == true ? .blue : .orange,
                title: L10n.text("home.status.storage"),
                value: coordinator.exportLocation?.isSelectedFolder == true
                    ? L10n.text("home.status.icloud_drive")
                    : L10n.text("home.status.needs_folder")
            )
            Divider().padding(.leading, 44)
            statusRow(
                icon: "arrow.triangle.2.circlepath",
                color: coordinator.automaticSyncEnabled && coordinator.backgroundDeliveryEnabled ? .green : .secondary,
                title: L10n.text("home.status.automatic_sync"),
                value: automaticSyncStatus
            )
            Divider().padding(.leading, 44)
            statusRow(
                icon: "clock.badge.checkmark",
                color: coordinator.lastSyncDate == nil ? .secondary : .green,
                title: L10n.text("home.status.last_update"),
                value: compactLastSyncText
            )
        }
        .cardStyle()
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text("home.sync.title"), systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                    .lineLimit(2)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if !isBusy, coordinator.hasRequestedAuthorization {
                    Label(L10n.text("home.sync.ready"), systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
            }

            phaseView

            if !coordinator.hasRequestedAuthorization {
                Button {
                    Task { await coordinator.requestAuthorization() }
                } label: {
                    Label(L10n.text("home.sync.authorize"), systemImage: "heart.fill")
                        .actionLabelStyle()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else {
                Divider()

                Toggle(
                    L10n.text("home.sync.automatic_toggle"),
                    isOn: Binding(
                        get: { coordinator.automaticSyncEnabled },
                        set: { enabled in
                            Task { await coordinator.setAutomaticSyncEnabled(enabled) }
                        }
                    )
                )
                .tint(.green)
                .lineLimit(2)

                Text(automaticSyncDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await coordinator.syncChanges() }
                } label: {
                    Label(L10n.text("home.sync.update"), systemImage: "heart.text.clipboard")
                        .actionLabelStyle()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(isBusy)
            }
        }
        .cardStyle(padding: 18)
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text("home.export.title"), systemImage: "square.and.arrow.up")
                    .font(.headline)
                Spacer(minLength: 8)
                Text(L10n.text("home.status.icloud_drive"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Picker(
                L10n.text("home.export.format_picker"),
                selection: Binding(
                    get: { coordinator.shareFormat },
                    set: { coordinator.setShareFormat($0) }
                )
            ) {
                ForEach(ShareFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)

            Button {
                Task {
                    if let url = await coordinator.prepareAgentFileForSharing() {
                        sharedFile = SharedFile(url: url)
                    }
                }
            } label: {
                Label(
                    L10n.format("home.export.share_file", coordinator.shareFormat.title),
                    systemImage: "square.and.arrow.up"
                )
                .actionLabelStyle()
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)

            Button {
                showsFolderPicker = true
            } label: {
                Label(
                    coordinator.exportLocation?.isSelectedFolder == true
                        ? L10n.text("home.export.change_folder")
                        : L10n.text("home.export.choose_folder"),
                    systemImage: "folder.badge.gearshape"
                )
                .actionLabelStyle()
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)

            Text(L10n.text("home.export.caption"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle(padding: 18)
    }

    private var connectionCard: some View {
        NavigationLink {
            TailscaleSettingsView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 42, height: 42)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("home.connection.title"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(L10n.text("home.connection.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)

                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle()
    }

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(L10n.text("home.privacy.caption"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .cardStyle()
    }

    @ViewBuilder
    private var phaseView: some View {
        switch coordinator.phase {
        case .idle:
            Label(lastSyncText, systemImage: "clock")
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .requestingAccess:
            HStack {
                ProgressView()
                Text(L10n.text("home.phase.requesting_access"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .exporting(let current, let total, let type):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    ProgressView()
                    Text(L10n.format("home.phase.exporting", type))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ProgressView(value: Double(current), total: Double(total))
                Text(L10n.format("home.phase.progress", current, total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .finished(let stats):
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    stats.typesFailed == 0
                        ? L10n.format("home.phase.finished", stats.samplesAdded)
                        : L10n.format("home.phase.finished_with_errors", stats.typesFailed),
                    systemImage: stats.typesFailed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .foregroundStyle(stats.typesFailed == 0 ? Color.green : Color.orange)
                .lineLimit(2)

                if stats.typesSkipped > 0 {
                    Text(L10n.format("home.phase.skipped", stats.typesSkipped))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !stats.issues.isEmpty {
                    DisclosureGroup(L10n.text("home.phase.diagnostics")) {
                        ForEach(Array(stats.issues.prefix(10).enumerated()), id: \.offset) { _, issue in
                            Text("\(readableIssueType(issue.typeIdentifier)): \(issue.message)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    private func statusRow(icon: String, color: Color, title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 32)
            Text(title)
                .lineLimit(2)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .padding(14)
    }

    private var isBusy: Bool {
        switch coordinator.phase {
        case .requestingAccess, .exporting: true
        default: false
        }
    }

    private var automaticSyncStatus: String {
        guard coordinator.automaticSyncEnabled else { return L10n.text("home.status.paused") }
        return coordinator.backgroundDeliveryEnabled
            ? L10n.text("home.status.enabled")
            : L10n.text("home.status.waiting_ios")
    }

    private var lastSyncText: String {
        guard let date = coordinator.lastSyncDate else { return L10n.text("home.last_sync.never") }
        return L10n.format("home.last_sync.full", L10n.dateTime(date))
    }

    private var compactLastSyncText: String {
        guard let date = coordinator.lastSyncDate else { return L10n.text("home.last_sync.never_short") }
        return L10n.dateTime(date)
    }

    private var automaticSyncDescription: String {
        guard coordinator.automaticSyncEnabled else {
            return L10n.text("home.sync.automatic_paused")
        }
        if coordinator.automaticChangesPending {
            return L10n.text("home.sync.automatic_pending")
        }
        return L10n.text("home.sync.automatic_description")
    }

    private func readableIssueType(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "Identifier", with: "")
    }
}

private struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private extension View {
    func cardStyle(padding: CGFloat = 0) -> some View {
        self
            .padding(padding)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }

    func actionLabelStyle() -> some View {
        self
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(HealthExportCoordinator.shared)
    }
}
#endif
