import Foundation
import HealthKit

@MainActor
final class HealthExportCoordinator: ObservableObject {
    static let shared = HealthExportCoordinator()

    @Published private(set) var phase: SyncPhase = .idle
    @Published private(set) var exportLocation: ExportLocation?
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastBackgroundSyncDate: Date?
    @Published private(set) var agentFileURL: URL?
    @Published private(set) var hasRequestedAuthorization: Bool
    @Published private(set) var backgroundDeliveryEnabled = false
    @Published private(set) var automaticSyncEnabled: Bool

    let healthStore: HKHealthStore
    let supportedTypeCount = HealthDataCatalog.sampleTypes.count

    private let engine: HealthExportEngine
    private var observerQueries: [String: HKObserverQuery] = [:]
    private var foregroundExportRunning = false
    private var agentExportRunning = false
    private var readableTypeIdentifiers: Set<String>

    private let readableTypesKey = "health-json.readable-types"
    private let lastSyncKey = "health-json.last-sync"
    private let lastBackgroundSyncKey = "health-json.last-background-sync"
    private let automaticSyncKey = "health-json.automatic-sync-enabled"

    private init() {
        let store = HKHealthStore()
        healthStore = store
        engine = HealthExportEngine(healthStore: store)
        hasRequestedAuthorization = UserDefaults.standard.bool(forKey: "health-json.authorization-requested")
        automaticSyncEnabled = UserDefaults.standard.object(forKey: automaticSyncKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: automaticSyncKey)
        readableTypeIdentifiers = Set(UserDefaults.standard.stringArray(forKey: readableTypesKey) ?? [])
        lastSyncDate = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        lastBackgroundSyncDate = UserDefaults.standard.object(forKey: lastBackgroundSyncKey) as? Date

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
                    completion()
                    guard self.automaticSyncEnabled else { return }
                    _ = await self.runAgentExport(isBackground: true)
                }
            }
            observerQueries[type.identifier] = query
            healthStore.execute(query)
        }

        if hasRequestedAuthorization, automaticSyncEnabled {
            Task { await enableBackgroundDelivery() }
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
        guard !foregroundExportRunning, !agentExportRunning else { return }
        if !hasRequestedAuthorization {
            await requestAuthorization()
            guard hasRequestedAuthorization else { return }
        }
        _ = await runAgentExport(isBackground: false)
    }

    func setAutomaticSyncEnabled(_ enabled: Bool) async {
        automaticSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: automaticSyncKey)
        if enabled {
            await enableBackgroundDelivery()
            _ = await runAgentExport(isBackground: true)
        } else {
            do {
                try await healthStore.disableAllBackgroundDelivery()
            } catch {
                print("HealthJSON disable background delivery failed: \(error)")
            }
            backgroundDeliveryEnabled = false
        }
    }

    func selectExportFolder(_ url: URL) async {
        do {
            exportLocation = try await engine.selectExportFolder(url)
            phase = .idle
        } catch {
            phase = .failed("Не удалось сохранить доступ к папке: \(error.localizedDescription)")
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
        return await runAgentExport(isBackground: true)
    }

    private func runAgentExport(isBackground: Bool) async -> Bool {
        guard hasRequestedAuthorization, !agentExportRunning else { return false }
        agentExportRunning = true
        defer { agentExportRunning = false }

        if !isBackground {
            phase = .exporting(current: 1, total: 1, type: "единый файл")
        }
        do {
            let result = try await engine.exportAgentContext()
            exportLocation = result.1
            agentFileURL = result.2
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
