import SwiftUI
import UIKit

struct TailscaleSettingsView: View {
    @EnvironmentObject private var coordinator: HealthExportCoordinator
    @State private var endpointDraft = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                syncCard
                apiCard
                fallbackCard
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.text("connection.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: coordinator.directSyncEndpoint) {
            endpointDraft = coordinator.directSyncEndpoint ?? ""
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 54, height: 54)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("connection.hero.title"))
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("connection.hero.subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text("connection.sync.title"), systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                    .lineLimit(2)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }

            Toggle(
                L10n.text("connection.sync.toggle"),
                isOn: Binding(
                    get: { coordinator.directSyncEnabled },
                    set: { enabled in
                        Task { await coordinator.setDirectSyncEnabled(enabled) }
                    }
                )
            )
            .tint(.blue)
            .lineLimit(2)

            if coordinator.directSyncEnabled {
                Button {
                    Task { await coordinator.checkDirectSyncConnection() }
                } label: {
                    Label(L10n.text("connection.sync.check"), systemImage: "arrow.clockwise")
                        .connectionActionLabelStyle()
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.directSyncConnectionState == .checking)
            }

            Text(L10n.text("connection.sync.caption"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .settingsCard(padding: 18)
    }

    private var apiCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.text("connection.api.title"), systemImage: "arrow.left.arrow.right.circle.fill")
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text(L10n.text("connection.api.explanation"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text(L10n.text("connection.endpoint.label"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(L10n.text("connection.endpoint.placeholder"), text: $endpointDraft)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("tailscale-endpoint-input")

            Button {
                Task { _ = await coordinator.configureDirectSyncEndpoint(endpointDraft) }
            } label: {
                Label(L10n.text("connection.endpoint.save"), systemImage: "checkmark")
                    .connectionActionLabelStyle()
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            if let message = coordinator.endpointConfigurationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(endpointMessageColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if coordinator.directSyncEndpoint != nil {
                Button(role: .destructive) {
                    Task { await coordinator.clearDirectSyncEndpoint() }
                } label: {
                    Label(L10n.text("connection.endpoint.clear"), systemImage: "trash")
                        .connectionActionLabelStyle()
                }
                .buttonStyle(.borderless)
            }

            Text(L10n.text("connection.api.import_address"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let endpoint = coordinator.directSyncEndpoint {
                Text(endpoint)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    UIPasteboard.general.string = endpoint
                } label: {
                    Label(L10n.text("connection.api.copy_address"), systemImage: "doc.on.doc")
                        .connectionActionLabelStyle()
                }
                .buttonStyle(.bordered)
            } else {
                Text(L10n.text("connection.api.no_address"))
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(L10n.text("connection.api.setup_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(L10n.text("connection.api.success_statuses"), systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                .lineLimit(2)

            Text(L10n.text("connection.api.contract"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .settingsCard(padding: 18)
    }

    private var fallbackCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("connection.fallback.title"))
                    .font(.headline)
                Text(L10n.text("connection.fallback.caption"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
        }
        .settingsCard(padding: 18)
    }

    private var statusText: String {
        guard coordinator.directSyncEnabled else { return L10n.text("connection.status.off") }
        switch coordinator.directSyncConnectionState {
        case .checking:
            return L10n.text("connection.status.checking")
        case .connected:
            return coordinator.lastDirectSyncDate.map {
                L10n.format("connection.status.delivered", L10n.time($0))
            } ?? L10n.text("connection.status.connected")
        case .unauthorized:
            return L10n.text("connection.status.no_access")
        case .unreachable:
            return coordinator.directSyncPendingCount > 0
                ? L10n.text("connection.status.offline_queued")
                : L10n.text("connection.status.offline")
        case .serverUnavailable:
            return coordinator.directSyncMessage ?? L10n.text("connection.status.service_unavailable")
        case .notConfigured:
            return L10n.text("connection.status.not_configured")
        case .idle:
            return coordinator.directSyncPendingCount > 0
                ? L10n.format("connection.status.queued", coordinator.directSyncPendingCount)
                : coordinator.directSyncMessage ?? L10n.text("connection.status.waiting")
        }
    }

    private var statusColor: Color {
        guard coordinator.directSyncEnabled else { return .secondary }
        switch coordinator.directSyncConnectionState {
        case .connected:
            return .green
        case .checking, .idle:
            return .secondary
        case .unreachable, .serverUnavailable:
            return .orange
        case .unauthorized, .notConfigured:
            return .red
        }
    }

    private var endpointMessageColor: Color {
        guard let message = coordinator.endpointConfigurationMessage else { return .secondary }
        return message == L10n.text("connection.endpoint.saved")
            || message == L10n.text("connection.endpoint.cleared")
            ? .green
            : .red
    }
}

private extension View {
    func settingsCard(padding: CGFloat) -> some View {
        self
            .padding(padding)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }

    func connectionActionLabelStyle() -> some View {
        self
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
    }
}
