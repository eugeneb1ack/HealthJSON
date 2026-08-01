import Foundation
import HealthKit

@MainActor
final class HealthExportCoordinator: ObservableObject {
    static let shared = HealthExportCoordinator()

    @Published private(set) var phase: SyncPhase = .idle
    @Published private(set) var exportLocation: ExportLocation?
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastBackgroundSyncDate: Date?
    @Published private(set) var lastDirectSyncDate: Date?
    @Published private(set) var directSyncPendingCount = 0
    @Published private(set) var directSyncMessage: String?
    @Published private(set) var directSyncConnectionState: DirectHealthSyncConnectionState = .idle
    @Published private(set) var agentFileURL: URL?
    @Published private(set) var hasRequestedAuthorization: Bool
    @Published private(set) var backgroundDeliveryEnabled = false
    @Published private(set) var automaticSyncEnabled: Bool
    @Published private(set) var automaticChangesPending: Bool
    @Published private(set) var directSyncEnabled: Bool

    let healthStore: HKHealthStore
    let supportedTypeCount = HealthDataCatalog.sampleTypes.count

    private let engine: HealthExportEngine
    private let directSync = DirectHealthSyncClient()
    private var observerQueries: [String: HKObserverQuery] = [:]
    private var foregroundExportRunning = false
    private var agentExportRunning = false
    private var agentExportWaiters: [CheckedContinuation<Void, Never>] = []
    private var automaticRefreshTask: Task<Void, Never>?
    private var automaticRefreshDeadline: Date?
    private var automaticRefreshToken = 0
    private var automaticChangeGeneration = 0
    private var readableTypeIdentifiers: Set<String>

    private let readableTypesKey = "health-json.readable-types"
    private let lastSyncKey = "health-json.last-sync"
    private let lastBackgroundSyncKey = "health-json.last-background-sync"
    private let lastFullSyncKey = "health-json.last-full-sync"
    private let automaticSyncKey = "health-json.automatic-sync-enabled"
    private let directSyncEnabledKey = "health-json.direct.enabled"
    private let automaticChangesPendingKey = "health-json.automatic-changes-pending"
    private let lastDirectSyncKey = "health-json.direct.last-delivery"
    private let minimumAutomaticInterval: TimeInterval = 5 * 60
    private let fullReconciliationInterval: TimeInterval = 24 * 60 * 60
    private var lastFullSyncDate: Date?

    private init() {
        let store = HKHealthStore()
        healthStore = store
        engine = HealthExportEngine(healthStore: store)
        hasRequestedAuthorization = UserDefaults.standard.bool(forKey: "health-json.authorization-requested")
        automaticSyncEnabled = UserDefaults.standard.object(forKey: automaticSyncKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: automaticSyncKey)
        directSyncEnabled = UserDefaults.standard.object(forKey: directSyncEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: directSyncEnabledKey)
        automaticChangesPending = UserDefaults.standard.bool(forKey: automaticChangesPendingKey)
        readableTypeIdentifiers = Set(UserDefaults.standard.stringArray(forKey: readableTypesKey) ?? [])
        lastSyncDate = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        lastBackgroundSyncDate = UserDefaults.standard.object(forKey: lastBackgroundSyncKey) as? Date
        lastDirectSyncDate = UserDefaults.standard.object(forKey: lastDirectSyncKey) as? Date
        lastFullSyncDate = UserDefaults.standard.object(forKey: lastFullSyncKey) as? Date

        Task {
            exportLocation = try? await engine.exportLocation()
            agentFileURL = exportLocation?.url
                .deletingLastPathComponent()
                .appendingPathComponent("Agent/health-context.json")
        }
    }

    func installBackgroundObservers() {
        guard HKHealthStore.isHealthDataAvailable(), observerQueries.isEmpty else { return }

        for type in HealthDataCatalog.backgroundDeliveryTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                guard let self else {
                    completion()
                    return
                }
                guard error == nil else {
                    completion()
                    return
                }

                Task { @MainActor in
                    self.markAutomaticChangesPending()
                    guard self.automaticSyncEnabled else {
                        completion()
                        return
                    }
                    let delay = self.automaticRefreshDelay()
                    if delay == 0, !self.agentExportRunning {
                        self.cancelScheduledAutomaticRefresh()
                        _ = await self.performAutomaticRefreshIfDue(force: true)
                    } else {
                        self.scheduleAutomaticRefresh(after: delay == 0 ? 5 : delay)
                    }
                    completion()
                }
            }
            observerQueries[type.identifier] = query
            healthStore.execute(query)
        }

        if hasRequestedAuthorization, automaticSyncEnabled {
            Task {
                await enableBackgroundDelivery()
                if automaticChangesPending {
                    scheduleAutomaticRefresh()
                }
                if directSyncEnabled {
                    await retryPendingDirectUploads()
                }
            }
        }
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            phase = .failed("HealthKit is not available on this device.")
            return
        }

        phase = .requestingAccess
        do {
            try await healthStore.requestAuthorization(toShare: [], read: HealthDataCatalog.readTypes)
            hasRequestedAuthorization = true
            UserDefaults.standard.set(true, forKey: "health-json.authorization-requested")
            if automaticSyncEnabled {
                await enableBackgroundDelivery()
            }
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func exportAllHistory() async {
        guard !foregroundExportRunning else { return }
        if !hasRequestedAuthorization {
            await requestAuthorization()
            guard hasRequestedAuthorization else { return }
        }

        await runForegroundExport(fromBeginning: true)
    }

    func syncChanges() async {
        guard !foregroundExportRunning else { return }
        if !hasRequestedAuthorization {
            await requestAuthorization()
            guard hasRequestedAuthorization else { return }
        }
        if agentExportRunning {
            phase = .exporting(current: 1, total: 1, type: "ожидание текущей синхронизации")
        }
        let generation = automaticChangeGeneration
        let success = await runAgentExport(isBackground: false)
        if success {
            clearAutomaticChangesPending(ifGenerationIs: generation)
        }
    }

    func setAutomaticSyncEnabled(_ enabled: Bool) async {
        automaticSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: automaticSyncKey)
        if enabled {
            await enableBackgroundDelivery()
            markAutomaticChangesPending()
            cancelScheduledAutomaticRefresh()
            _ = await performAutomaticRefreshIfDue(force: true)
        } else {
            cancelScheduledAutomaticRefresh()
            do {
                try await healthStore.disableAllBackgroundDelivery()
            } catch {
                print("HealthJSON disable background delivery failed: \(error)")
            }
            backgroundDeliveryEnabled = false
        }
    }

    func setDirectSyncEnabled(_ enabled: Bool) async {
        directSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: directSyncEnabledKey)
        if enabled {
            directSyncConnectionState = .checking
            directSyncMessage = "Проверка соединения…"
            await retryPendingDirectUploads(force: true)
            if directSyncConnectionState == .idle {
                await checkDirectSyncConnection()
            }
        } else {
            directSyncConnectionState = .idle
            directSyncMessage = nil
        }
    }

    func checkDirectSyncConnection() async {
        guard directSyncEnabled else { return }
        directSyncConnectionState = .checking
        directSyncMessage = "Проверка соединения…"
        applyDirectSyncReport(await directSync.checkConnection())
    }

    func handleAppDidBecomeActive() {
        if automaticSyncEnabled, automaticChangesPending {
            scheduleAutomaticRefresh()
        }
        if directSyncEnabled {
            Task { [weak self] in
                await self?.retryPendingDirectUploads()
            }
        }
    }

    func selectExportFolder(_ url: URL) async {
        do {
            exportLocation = try await engine.selectExportFolder(url)
            updateAgentFileURL()
            phase = .idle
        } catch {
            phase = .failed("Не удалось сохранить доступ к папке: \(error.localizedDescription)")
        }
    }

    func prepareAgentFileForSharing() async -> URL? {
        do {
            return try await engine.makeAgentSnapshotShareCopy()
        } catch {
            phase = .failed("Не удалось подготовить единый файл: сначала обновите JSON.")
            return nil
        }
    }

    private func runForegroundExport(fromBeginning: Bool) async {
        foregroundExportRunning = true
        defer { foregroundExportRunning = false }

        do {
            if fromBeginning {
                await engine.resetAnchors()
            }

            var total = ExportStatistics()
            if fromBeginning {
                let characteristicResult = try await engine.exportCharacteristics()
                total = total + characteristicResult.0
                exportLocation = characteristicResult.1
            }

            do {
                let medicationResult = try await engine.exportMedications()
                total = total + medicationResult.0
                exportLocation = medicationResult.1
            } catch {
                total.typesFailed += 1
            }

            do {
                let activityResult = try await engine.exportActivitySummaries()
                total = total + activityResult.0
                exportLocation = activityResult.1
            } catch {
                total.typesFailed += 1
            }

            let types = HealthDataCatalog.sampleTypes
            for (index, type) in types.enumerated() {
                phase = .exporting(current: index + 1, total: types.count, type: readableName(type.identifier))
                do {
                    let result = try await engine.export(type: type, fromBeginning: fromBeginning)
                    total = total + result.0
                    recordReadable(type)
                    if let location = result.1 { exportLocation = location }
                } catch {
                    record(error, for: type, in: &total)
                    continue
                }
            }

            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: lastSyncKey)
            phase = .finished(total)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func performScheduledRefresh() async -> Bool {
        guard automaticSyncEnabled else { return false }
        let success = await performAutomaticRefreshIfDue()
        if directSyncEnabled {
            Task { [weak self] in
                await self?.retryPendingDirectUploads()
            }
        }
        return success
    }

    private func performAutomaticRefreshIfDue(force: Bool = false) async -> Bool {
        guard automaticSyncEnabled else { return false }
        guard automaticChangesPending else { return true }
        if !force, automaticRefreshDelay() > 0 {
            scheduleAutomaticRefresh()
            return true
        }
        if agentExportRunning {
            scheduleAutomaticRefresh(after: 5)
            return true
        }

        let generation = automaticChangeGeneration
        let needsFullReconciliation = lastFullSyncDate == nil
            || Date().timeIntervalSince(lastFullSyncDate ?? .distantPast) >= fullReconciliationInterval
        let success = await runAgentExport(
            isBackground: true,
            fullReconciliation: needsFullReconciliation
        )
        if success {
            clearAutomaticChangesPending(ifGenerationIs: generation)
        } else if automaticChangesPending {
            scheduleAutomaticRefresh(after: 30)
        }
        return success
    }

    private func markAutomaticChangesPending() {
        automaticChangeGeneration += 1
        automaticChangesPending = true
        UserDefaults.standard.set(true, forKey: automaticChangesPendingKey)
    }

    private func clearAutomaticChangesPending(ifGenerationIs generation: Int) {
        guard generation == automaticChangeGeneration else { return }
        automaticChangesPending = false
        UserDefaults.standard.set(false, forKey: automaticChangesPendingKey)
        cancelScheduledAutomaticRefresh()
    }

    private func updateAgentFileURL() {
        agentFileURL = exportLocation?.url
            .deletingLastPathComponent()
            .appendingPathComponent("Agent/health-context.json")
    }

    private func runAgentExport(
        isBackground: Bool,
        fullReconciliation: Bool = false
    ) async -> Bool {
        guard hasRequestedAuthorization else { return false }
        await acquireAgentExportAccess()
        defer { releaseAgentExportAccess() }

        if !isBackground {
            phase = .exporting(current: 1, total: 1, type: "единый файл")
        }
        do {
            let writesFullSnapshot = !isBackground || fullReconciliation
            let result: (ExportStatistics, ExportLocation, URL, Data)
            if writesFullSnapshot {
                result = try await engine.exportAgentContext()
            } else {
                result = try await engine.exportAgentUpdate()
            }
            exportLocation = result.1
            if directSyncEnabled {
                applyDirectSyncReport(await directSync.enqueue(result.3))
                Task { [weak self] in
                    await self?.retryPendingDirectUploads(force: true)
                }
            }
            if writesFullSnapshot {
                agentFileURL = result.2
                lastFullSyncDate = Date()
                UserDefaults.standard.set(lastFullSyncDate, forKey: lastFullSyncKey)
            }
            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: lastSyncKey)
            if isBackground {
                lastBackgroundSyncDate = lastSyncDate
                UserDefaults.standard.set(lastBackgroundSyncDate, forKey: lastBackgroundSyncKey)
            } else {
                phase = .finished(result.0)
            }
            return true
        } catch {
            if !isBackground {
                phase = .failed("Не удалось создать единый файл: \(error.localizedDescription)")
            }
            print("HealthJSON agent snapshot failed: \(error)")
            return false
        }
    }

    private func enableBackgroundDelivery() async {
        var enabled = 0
        for type in HealthDataCatalog.backgroundDeliveryTypes {
            do {
                try await healthStore.enableBackgroundDelivery(for: type, frequency: .immediate)
                enabled += 1
            } catch {
                continue
            }
        }
        backgroundDeliveryEnabled = enabled > 0
    }

    private func retryPendingDirectUploads(force: Bool = false) async {
        guard directSyncEnabled else { return }
        applyDirectSyncReport(await directSync.flush(force: force))
    }

    private func applyDirectSyncReport(_ report: DirectHealthSyncReport) {
        lastDirectSyncDate = report.deliveredAt
        directSyncPendingCount = report.pendingCount
        directSyncMessage = report.message
        directSyncConnectionState = report.connectionState
    }

    private func automaticRefreshDelay(now: Date = Date()) -> TimeInterval {
        guard let lastBackgroundSyncDate else { return 0 }
        return max(0, minimumAutomaticInterval - now.timeIntervalSince(lastBackgroundSyncDate))
    }

    private func scheduleAutomaticRefresh(after requestedDelay: TimeInterval? = nil) {
        guard automaticSyncEnabled, automaticChangesPending else { return }
        let delay = max(0, requestedDelay ?? automaticRefreshDelay())
        let deadline = Date().addingTimeInterval(delay)
        if let automaticRefreshDeadline, automaticRefreshDeadline <= deadline {
            return
        }
        automaticRefreshTask?.cancel()
        automaticRefreshToken += 1
        let token = automaticRefreshToken
        automaticRefreshDeadline = deadline
        print("HealthJSON automatic refresh scheduled in \(Int(ceil(delay)))s")
        automaticRefreshTask = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
            guard let self,
                  !Task.isCancelled,
                  token == self.automaticRefreshToken
            else { return }
            self.automaticRefreshDeadline = nil
            print("HealthJSON automatic refresh starting")
            _ = await self.performAutomaticRefreshIfDue(force: true)
        }
    }

    private func cancelScheduledAutomaticRefresh() {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        automaticRefreshDeadline = nil
        automaticRefreshToken += 1
    }

    private func acquireAgentExportAccess() async {
        if !agentExportRunning {
            agentExportRunning = true
            return
        }
        await withCheckedContinuation { continuation in
            agentExportWaiters.append(continuation)
        }
    }

    private func releaseAgentExportAccess() {
        guard !agentExportWaiters.isEmpty else {
            agentExportRunning = false
            return
        }
        agentExportWaiters.removeFirst().resume()
    }

    private func readableName(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKClinicalTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCorrelationTypeIdentifier", with: "")
            .replacingOccurrences(of: "Identifier", with: "")
    }

    private func recordReadable(_ type: HKSampleType) {
        if readableTypeIdentifiers.insert(type.identifier).inserted {
            UserDefaults.standard.set(Array(readableTypeIdentifiers).sorted(), forKey: readableTypesKey)
        }
    }

    private func record(_ error: Error, for type: HKSampleType, in statistics: inout ExportStatistics) {
        let issue = exportIssue(error, type: type)
        statistics.issues.append(issue)
        if issue.skipped {
            statistics.typesSkipped += 1
        } else {
            statistics.typesFailed += 1
        }
        print("HealthJSON export issue \(type.identifier) [\(issue.code)]: \(issue.message)")
    }

    private func exportIssue(_ error: Error, type: HKSampleType) -> ExportIssue {
        let nsError = error as NSError
        let skippedCodes: Set<HKError.Code> = [
            .errorAuthorizationDenied,
            .errorAuthorizationNotDetermined,
            .errorHealthDataUnavailable,
            .errorHealthDataRestricted,
            .errorNoData,
            .errorUserCanceled
        ]
        let skipped = (error as? HKError).map { skippedCodes.contains($0.code) } ?? false
        return ExportIssue(
            typeIdentifier: type.identifier,
            message: nsError.localizedDescription,
            code: nsError.code,
            skipped: skipped
        )
    }
}
