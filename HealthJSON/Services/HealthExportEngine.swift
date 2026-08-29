import Foundation
import HealthKit
import CoreLocation

actor HealthExportEngine {
    private let healthStore: HKHealthStore
    private let cloudStore: CloudExportStore
    private let agentExporter: AgentHealthExporter
    private let anchorStore: AnchorStore
    private let pageSize = 1_000
    private var cachedPreferredUnits: [HKQuantityType: HKUnit]?
    private var exclusiveAccessHeld = false
    private var exclusiveAccessWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        healthStore: HKHealthStore,
        cloudStore: CloudExportStore = CloudExportStore(),
        anchorStore: AnchorStore = AnchorStore()
    ) {
        self.healthStore = healthStore
        self.cloudStore = cloudStore
        self.agentExporter = AgentHealthExporter(healthStore: healthStore, cloudStore: cloudStore)
        self.anchorStore = anchorStore
    }

    func resetAnchors() async {
        await acquireExclusiveAccess()
        defer { releaseExclusiveAccess() }
        anchorStore.removeAll()
    }

    func exportCharacteristics() async throws -> (ExportStatistics, ExportLocation) {
        await acquireExclusiveAccess()
        defer { releaseExclusiveAccess() }
        let payload = HealthKitEncoder.characteristics(from: healthStore)
        let location = try await cloudStore.writeBatch(payload, typeIdentifier: "HealthKitCharacteristics")
        return (ExportStatistics(filesWritten: 1, samplesAdded: 1), location)
    }

    func exportMedications() async throws -> (ExportStatistics, ExportLocation) {
        await acquireExclusiveAccess()
        defer { releaseExclusiveAccess() }
        let medications = try await fetchMedications()
        let payload = HealthKitEncoder.medications(medications)
        let location = try await cloudStore.writeBatch(payload, typeIdentifier: "HKUserAnnotatedMedicationType")
        return (
            ExportStatistics(filesWritten: 1, samplesAdded: medications.count),
            location
        )
    }

    func exportActivitySummaries() async throws -> (ExportStatistics, ExportLocation) {
        await acquireExclusiveAccess()
        defer { releaseExclusiveAccess() }
        let summaries = try await HKActivitySummaryQueryDescriptor(predicate: nil).result(for: healthStore)
        let payload = HealthKitEncoder.activitySummaries(summaries)
        let location = try await cloudStore.writeBatch(payload, typeIdentifier: "HKActivitySummaryType")
        return (
            ExportStatistics(filesWritten: 1, samplesAdded: summaries.count),
            location
        )
    }

    func export(type: HKSampleType, fromBeginning: Bool = false) async throws -> (ExportStatistics, ExportLocation?) {
        await acquireExclusiveAccess()
        defer { releaseExclusiveAccess() }
        var currentAnchor = fromBeginning ? nil : anchorStore.anchor(for: type.identifier)
        var statistics = ExportStatistics()
        var lastLocation: ExportLocation?
        let units = await preferredUnits()

        while true {
            let limit = pageLimit(for: type)
            let result = try await anchoredPage(type: type, anchor: currentAnchor, limit: limit)
            guard let newAnchor = result.anchor else {
                throw ExportError.missingAnchor(type.identifier)
            }

            if !result.samples.isEmpty || !result.deleted.isEmpty {
                var encodedSamples: [[String: Any]] = []
                for sample in result.samples {
                    encodedSamples.append(await encode(sample, preferredUnits: units))
                }
                let payload = HealthKitEncoder.batch(
                    type: type,
                    encodedSamples: encodedSamples,
                    deleted: result.deleted,
                    exportedAt: Date()
                )
                lastLocation = try await cloudStore.writeBatch(payload, typeIdentifier: type.identifier)
                statistics = statistics + ExportStatistics(
                    filesWritten: 1,
                    samplesAdded: result.samples.count,
                    samplesDeleted: result.deleted.count
                )
            }

            // Commit only after the JSON change set is durable.
            try anchorStore.save(newAnchor, for: type.identifier)
            currentAnchor = newAnchor

            if result.samples.count + result.deleted.count < limit {
                break
            }
        }

        return (statistics, lastLocation)
    }

    func exportLocation() async throws -> ExportLocation {
        try await cloudStore.resolveLocation()
    }

    func selectExportFolder(_ url: URL) async throws -> ExportLocation {
        await acquireExclusiveAccess()
        defer { releaseExclusiveAccess() }
        return try await cloudStore.selectFolder(url)
    }

    func exportAgentContext() async throws -> (ExportStatistics, ExportLocation, URL, Data) {
        await acquireExclusiveAccess()
        defer { releaseExclusiveAccess() }
        return try await agentExporter.export()
    }

    func exportAgentUpdate() async throws -> (ExportStatistics, ExportLocation, URL, Data) {
        await acquireExclusiveAccess()
        defer { releaseExclusiveAccess() }
        return try await agentExporter.exportRecentUpdate()
    }

    func makeAgentSnapshotShareCopy(format: ShareFormat) async throws -> URL {
        await acquireExclusiveAccess()
        defer { releaseExclusiveAccess() }
        return try await cloudStore.makeAgentSnapshotShareCopy(format: format)
    }

    func loadAgentSnapshot() async throws -> HealthDataSnapshot {
        let data = try await cloudStore.readAgentSnapshot()
        return try HealthDataSnapshot.decode(data: data)
    }

    private func preferredUnits() async -> [HKQuantityType: HKUnit] {
        if let cachedPreferredUnits { return cachedPreferredUnits }
        let units = (try? await healthStore.preferredUnits(for: Set(HealthDataCatalog.quantityTypes))) ?? [:]
        cachedPreferredUnits = units
        return units
    }

    private func acquireExclusiveAccess() async {
        if !exclusiveAccessHeld {
            exclusiveAccessHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            exclusiveAccessWaiters.append(continuation)
        }
    }

    private func releaseExclusiveAccess() {
        if exclusiveAccessWaiters.isEmpty {
            exclusiveAccessHeld = false
        } else {
            exclusiveAccessWaiters.removeFirst().resume()
        }
    }

    private func anchoredPage(type: HKSampleType, anchor: HKQueryAnchor?, limit: Int) async throws -> Page {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: nil,
                anchor: anchor,
                limit: limit
            ) { _, samples, deleted, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: Page(
                    samples: samples ?? [],
                    deleted: deleted ?? [],
                    anchor: newAnchor
                ))
            }
            healthStore.execute(query)
        }
    }

    private func encode(_ sample: HKSample, preferredUnits: [HKQuantityType: HKUnit]) async -> [String: Any] {
        var payload = HealthKitEncoder.sample(sample, preferredUnits: preferredUnits)
        do {
            switch sample {
            case let ecg as HKElectrocardiogram:
                var points: [[String: Any]] = []
                let unit = HKUnit.voltUnit(with: .micro)
                for try await measurement in HKElectrocardiogramQueryDescriptor(ecg).results(for: healthStore) {
                    points.append([
                        "timeSinceSampleStart": measurement.timeSinceSampleStart,
                        "lead": HKElectrocardiogram.Lead.appleWatchSimilarToLeadI.rawValue,
                        "voltageMicrovolts": measurement.quantity(for: .appleWatchSimilarToLeadI)?.doubleValue(for: unit) ?? NSNull()
                    ])
                }
                payload["voltageMeasurements"] = points
                payload["voltageUnit"] = unit.unitString

            case let route as HKWorkoutRoute:
                var locations: [[String: Any]] = []
                for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: healthStore) {
                    locations.append([
                        "timestamp": ISO8601DateFormatter.healthJSON.string(from: location.timestamp),
                        "latitude": location.coordinate.latitude,
                        "longitude": location.coordinate.longitude,
                        "altitude": location.altitude,
                        "horizontalAccuracy": location.horizontalAccuracy,
                        "verticalAccuracy": location.verticalAccuracy,
                        "speed": location.speed,
                        "speedAccuracy": location.speedAccuracy,
                        "course": location.course,
                        "courseAccuracy": location.courseAccuracy
                    ])
                }
                payload["locations"] = locations

            case let series as HKHeartbeatSeriesSample:
                var heartbeats: [[String: Any]] = []
                for try await heartbeat in HKHeartbeatSeriesQueryDescriptor(series).results(for: healthStore) {
                    heartbeats.append([
                        "timeSinceSeriesStart": heartbeat.timeIntervalSinceStart,
                        "precededByGap": heartbeat.precededByGap
                    ])
                }
                payload["heartbeats"] = heartbeats

            case let document as HKCDADocumentSample:
                if let populatedDocument = try await fetchCDADocument(matching: document) {
                    payload = HealthKitEncoder.sample(populatedDocument, preferredUnits: preferredUnits)
                }

            default:
                break
            }
        } catch {
            payload["seriesExportError"] = error.localizedDescription
        }
        return payload
    }

    private func pageLimit(for type: HKSampleType) -> Int {
        if type == HKObjectType.electrocardiogramType()
            || type == HKSeriesType.workoutRoute() {
            return 1
        }
        if type == HKSeriesType.heartbeat() {
            return 50
        }
        return pageSize
    }

    private func fetchMedications() async throws -> [HKUserAnnotatedMedication] {
        try await withCheckedThrowingContinuation { continuation in
            var medications: [HKUserAnnotatedMedication] = []
            var completed = false
            let query = HKUserAnnotatedMedicationQuery(
                predicate: nil,
                limit: HKObjectQueryNoLimit
            ) { _, medication, done, error in
                guard !completed else { return }
                if let error {
                    completed = true
                    continuation.resume(throwing: error)
                    return
                }
                if let medication { medications.append(medication) }
                if done {
                    completed = true
                    continuation.resume(returning: medications)
                }
            }
            healthStore.execute(query)
        }
    }

    private func fetchCDADocument(matching sample: HKCDADocumentSample) async throws -> HKCDADocumentSample? {
        let documentType = sample.documentType
        return try await withCheckedThrowingContinuation { continuation in
            var match: HKCDADocumentSample?
            var completed = false
            let query = HKDocumentQuery(
                documentType: documentType,
                predicate: HKQuery.predicateForObject(with: sample.uuid),
                limit: 1,
                sortDescriptors: nil,
                includeDocumentData: true
            ) { _, results, done, error in
                guard !completed else { return }
                if let error {
                    completed = true
                    continuation.resume(throwing: error)
                    return
                }
                if let result = results?.first as? HKCDADocumentSample { match = result }
                if done {
                    completed = true
                    continuation.resume(returning: match)
                }
            }
            healthStore.execute(query)
        }
    }

    private struct Page {
        let samples: [HKSample]
        let deleted: [HKDeletedObject]
        let anchor: HKQueryAnchor?
    }

    enum ExportError: LocalizedError {
        case missingAnchor(String)

        var errorDescription: String? {
            switch self {
            case .missingAnchor(let identifier):
                "HealthKit did not return an anchor for \(identifier)."
            }
        }
    }
}

private extension ISO8601DateFormatter {
    static let healthJSON: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
