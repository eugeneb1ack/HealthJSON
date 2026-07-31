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
                    privacyCard
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Здоровье в JSON")
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
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.red.gradient)
                    .frame(width: 88, height: 88)
                Image(systemName: "heart.text.clipboard")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Данные здоровья — в одном JSON")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Резервная копия в iCloud и быстрая доставка вашему тренеру через Tailscale.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var statusCard: some View {
        VStack(spacing: 0) {
            statusRow(
                icon: coordinator.hasRequestedAuthorization ? "checkmark.shield.fill" : "shield.lefthalf.filled",
                color: coordinator.hasRequestedAuthorization ? .green : .orange,
                title: "Доступ к Здоровью",
                value: coordinator.hasRequestedAuthorization ? "Запрошен" : "Не запрошен"
            )
            Divider().padding(.leading, 44)
            statusRow(
                icon: coordinator.exportLocation?.isSelectedFolder == true ? "icloud.fill" : "folder.fill",
                color: coordinator.exportLocation?.isSelectedFolder == true ? .blue : .orange,
                title: "Хранилище",
                value: coordinator.exportLocation?.isSelectedFolder == true ? "Выбранная папка" : "Нужно выбрать"
            )
            Divider().padding(.leading, 44)
            statusRow(
                icon: "arrow.triangle.2.circlepath",
                color: coordinator.automaticSyncEnabled && coordinator.backgroundDeliveryEnabled ? .green : .secondary,
                title: "Автосинхронизация",
                value: coordinator.automaticSyncEnabled
                    ? (coordinator.backgroundDeliveryEnabled ? "Включена" : "Ожидание")
                    : "Приостановлена"
            )
            Divider().padding(.leading, 44)
            statusRow(
                icon: coordinator.directSyncPendingCount > 0 ? "clock.arrow.circlepath" : "paperplane.circle.fill",
                color: coordinator.directSyncPendingCount > 0
                    ? .orange
                    : (coordinator.lastDirectSyncDate == nil ? .secondary : .green),
                title: "Доставка тренеру",
                value: directSyncText
            )
            Divider().padding(.leading, 44)
            statusRow(
                icon: "clock.badge.checkmark",
                color: coordinator.lastBackgroundSyncDate == nil ? .secondary : .green,
                title: "Последняя фоновая",
                value: backgroundSyncText
            )
        }
        .cardStyle()
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            phaseView

            if !coordinator.hasRequestedAuthorization {
                Button {
                    Task { await coordinator.requestAuthorization() }
                } label: {
                    Label("Разрешить доступ", systemImage: "heart.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else {
                Toggle(
                    "Автоматическая синхронизация",
                    isOn: Binding(
                        get: { coordinator.automaticSyncEnabled },
                        set: { enabled in
                            Task { await coordinator.setAutomaticSyncEnabled(enabled) }
                        }
                    )
                )
                .tint(.green)

                Text(
                    coordinator.automaticSyncEnabled
                        ? (coordinator.automaticChangesPending
                            ? "Изменения накоплены и будут отправлены тренеру в ближайшем обновлении."
                            : "При изменениях HealthKit: напрямую на Mac, с объединением до 5 минут. iCloud остаётся резервом.")
                        : "Автоматическое обновление приостановлено."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button {
                    Task { await coordinator.syncChanges() }
                } label: {
                    Label("Обновить единый JSON", systemImage: "heart.text.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBusy)

            }

            Button {
                Task {
                    if let url = await coordinator.prepareAgentFileForSharing() {
                        sharedFile = SharedFile(url: url)
                    }
                }
            } label: {
                Label("Поделиться единым файлом", systemImage: "doc.badge.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)

            Button {
                showsFolderPicker = true
            } label: {
                Label(
                    coordinator.exportLocation?.isSelectedFolder == true
                        ? "Изменить папку iCloud Drive"
                        : "Выбрать папку iCloud Drive",
                    systemImage: "folder.badge.plus"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)

            Text("Единый файл содержит только доступные показатели за последний год: дневные агрегаты, сон, пульс, кислород, HRV, тренировки и события.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle(padding: 18)
    }

    @ViewBuilder
    private var phaseView: some View {
        switch coordinator.phase {
        case .idle:
            Label(lastSyncText, systemImage: "clock")
                .foregroundStyle(.secondary)
        case .requestingAccess:
            HStack { ProgressView(); Text("Ожидание разрешения HealthKit…") }
        case .exporting(let current, let total, let type):
            VStack(alignment: .leading, spacing: 8) {
                HStack { ProgressView(); Text("Экспорт: \(type)").lineLimit(1) }
                ProgressView(value: Double(current), total: Double(total))
                Text("Тип \(current) из \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .finished(let stats):
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    stats.typesFailed == 0
                        ? (stats.filesWritten == 1
                            ? "Единый файл обновлён · разделов и записей: \(stats.samplesAdded)"
                            : "Файлов: \(stats.filesWritten) · добавлено: \(stats.samplesAdded) · удалено: \(stats.samplesDeleted)")
                        : "Файлов: \(stats.filesWritten) · ошибок: \(stats.typesFailed)",
                    systemImage: stats.typesFailed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .foregroundStyle(stats.typesFailed == 0 ? Color.green : Color.orange)
                if stats.typesSkipped > 0 {
                    Text("Пропущено недоступных или неразрешённых типов: \(stats.typesSkipped)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !stats.issues.isEmpty {
                    DisclosureGroup("Диагностика") {
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
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Важно", systemImage: "lock.fill")
                .font(.headline)
            Text("Данные о здоровье чувствительны. Прямая доставка доступна только внутри вашего зашифрованного Tailscale-соединения; iCloud остаётся резервной копией.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Автосинхронизацию можно приостановить. Неотправленные обновления остаются в защищённой очереди приложения и повторяются с паузой. Ручная кнопка создаёт и отправляет полный снимок сразу. Точное время фонового запуска определяет iOS.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .cardStyle(padding: 18)
    }

    private func statusRow(icon: String, color: Color, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 32)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
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

    private var lastSyncText: String {
        guard let date = coordinator.lastSyncDate else { return "Синхронизации ещё не было" }
        return "Последняя синхронизация: \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var backgroundSyncText: String {
        guard let date = coordinator.lastBackgroundSyncDate else { return "Ожидается iOS" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var directSyncText: String {
        if coordinator.directSyncPendingCount > 0 {
            return coordinator.directSyncMessage ?? "В очереди: \(coordinator.directSyncPendingCount)"
        }
        guard let date = coordinator.lastDirectSyncDate else {
            return coordinator.directSyncMessage ?? "Ожидается отправка"
        }
        return date.formatted(date: .omitted, time: .shortened)
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
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

#Preview {
    ContentView()
        .environmentObject(HealthExportCoordinator.shared)
}
