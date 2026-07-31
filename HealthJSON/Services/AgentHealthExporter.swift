import Foundation
import HealthKit

actor AgentHealthExporter {
    private let healthStore: HKHealthStore
    private let cloudStore: CloudExportStore
    private let calendar = Calendar.autoupdatingCurrent
    private let historyDays = 365
    private let recentUpdateDays = 3

    init(healthStore: HKHealthStore, cloudStore: CloudExportStore) {
        self.healthStore = healthStore
        self.cloudStore = cloudStore
    }

    func export() async throws -> (ExportStatistics, ExportLocation, URL) {
        try await export(days: historyDays, isDelta: false)
    }

    func exportRecentUpdate() async throws -> (ExportStatistics, ExportLocation, URL) {
        try await export(days: recentUpdateDays, isDelta: true)
    }

    private func export(
        days: Int,
        isDelta: Bool
    ) async throws -> (ExportStatistics, ExportLocation, URL) {
        print("HealthJSON agent \(isDelta ? "delta" : "full") export started")
        let generatedAt = Date()
        let today = calendar.startOfDay(for: generatedAt)
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? generatedAt
        let startOffset = isDelta ? -(days - 1) : -days
        let start = calendar.date(byAdding: .day, value: startOffset, to: today) ?? today
        let units = try await healthStore.preferredUnits(for: Set(HealthDataCatalog.quantityTypes))

        let metrics = try await withThrowingTaskGroup(of: (String, [String: Any]?).self) { group in
            for type in HealthDataCatalog.quantityTypes {
                guard let unit = units[type] else { continue }
                group.addTask {
                    let value = try await self.quantityMetric(type, unit: unit, start: start, end: end)
                    return (await self.semanticKey(type.identifier), value)
                }
            }
            var result: [String: Any] = [:]
            for try await (key, value) in group {
                if let value { result[key] = value }
            }
            return result
        }
        print("HealthJSON agent metrics ready: \(metrics.count)")

        let categories = try await withThrowingTaskGroup(of: (String, [String: Any]?).self) { group in
            for type in HealthDataCatalog.categoryTypes {
                group.addTask {
                    let samples = try await self.samples(of: type, start: start, end: end)
                    let values = samples.compactMap { $0 as? HKCategorySample }
                    return (
                        await self.semanticKey(type.identifier),
                        await self.categoryMetric(type, samples: values, start: start, end: end)
                    )
                }
            }
            var result: [String: Any] = [:]
            for try await (key, value) in group {
                if let value { result[key] = value }
            }
            return result
        }
        print("HealthJSON agent categories ready: \(categories.count)")

        let sleepIntervals = try await sleepIntervalPayload(start: start, end: end)
        print("HealthJSON agent sleep intervals ready: \(sleepIntervals.count)")

        let workouts = try await workoutPayload(start: start, end: end, units: units)
        print("HealthJSON agent workouts ready: \(workouts.count)")
        let activity = try await activityPayload(start: start, end: generatedAt)
        print("HealthJSON agent activity ready: \(activity.count)")
        let special = try await specialPayload(start: start, end: end)
        print("HealthJSON agent special ready: \(special.count)")
        let exportedWorkouts = isDelta ? [] : workouts
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "kind": isDelta ? "health-agent-delta" : "health-agent-context",
            "generatedAt": Self.iso8601.string(from: generatedAt),
            "updateSemantics": isDelta
                ? [
                    "mode": "replaceWindow",
                    "replacesPreviousFile": false,
                    "appendOnly": false,
                    "readerInstruction": "Replace normalized rows only within the declared period."
                ]
                : [
                    "mode": "atomicFullSnapshot",
                    "replacesPreviousFile": true,
                    "appendOnly": false,
                    "readerInstruction": "Process only when generatedAt changes. This file is a complete replacement snapshot."
                ],
            "period": [
                "start": Self.dayFormatter.string(from: start),
                "end": Self.dayFormatter.string(from: generatedAt),
                "days": days,
                "timeZone": TimeZone.autoupdatingCurrent.identifier
            ],
            "rowFormats": [
                "cumulativeMetric": ["date", "sum"],
                "discreteMetric": ["date", "average", "minimum", "maximum", "latest"],
                "categoryDay": ["date", ["value", "count", "minutes"]],
                "sleepInterval": ["start", "end", "value"]
            ],
            "profile": profilePayload(),
            "metrics": metrics,
            "categories": categories,
            "activityRings": activity,
            "workouts": exportedWorkouts,
            "special": special,
            "sleepIntervals": sleepIntervals
        ]

        let writeResult: (ExportLocation, URL)
        if isDelta {
            writeResult = try await cloudStore.writeAgentUpdate(payload)
        } else {
            writeResult = try await cloudStore.writeAgentSnapshot(payload)
        }
        let (location, fileURL) = writeResult
        print("HealthJSON agent export wrote \(fileURL.path)")
        return (
            ExportStatistics(
                filesWritten: 1,
                samplesAdded: metrics.count + categories.count + exportedWorkouts.count + activity.count + sleepIntervals.count
            ),
            location,
            fileURL
        )
    }

    private func quantityMetric(
        _ type: HKQuantityType,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async throws -> [String: Any]? {
        let cumulative = type.aggregationStyle == .cumulative
        let options: HKStatisticsOptions = cumulative
            ? [.cumulativeSum]
            : [.discreteAverage, .discreteMin, .discreteMax, .mostRecent]
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let rows: [[Any]] = try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: calendar.startOfDay(for: start),
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let collection else {
                    continuation.resume(returning: [])
                    return
                }
                var values: [[Any]] = []
                collection.enumerateStatistics(from: start, to: end) { statistics, _ in
                    let day = Self.dayFormatter.string(from: statistics.startDate)
                    if cumulative {
                        guard let sum = statistics.sumQuantity()?.doubleValue(for: unit) else { return }
                        values.append([day, Self.rounded(sum)])
                    } else {
                        let average = statistics.averageQuantity()?.doubleValue(for: unit)
                        let minimum = statistics.minimumQuantity()?.doubleValue(for: unit)
                        let maximum = statistics.maximumQuantity()?.doubleValue(for: unit)
                        let latest = statistics.mostRecentQuantity()?.doubleValue(for: unit)
                        guard average != nil || minimum != nil || maximum != nil || latest != nil else { return }
                        values.append([
                            day,
                            average.map(Self.rounded) ?? NSNull(),
                            minimum.map(Self.rounded) ?? NSNull(),
                            maximum.map(Self.rounded) ?? NSNull(),
                            latest.map(Self.rounded) ?? NSNull()
                        ])
                    }
                }
                continuation.resume(returning: values)
            }
            healthStore.execute(query)
        }
        guard !rows.isEmpty else { return nil }
        return [
            "typeIdentifier": type.identifier,
            "unit": unit.unitString,
            "aggregation": cumulative ? "dailySum" : "dailyAverageMinMaxLatest",
            "daily": rows
        ]
    }

    private func categoryMetric(
        _ type: HKCategoryType,
        samples: [HKCategorySample],
        start: Date,
        end: Date
    ) -> [String: Any]? {
        guard !samples.isEmpty else { return nil }
        struct Bucket {
            var count = 0
            var seconds = 0.0
        }
        var days: [String: [Int: Bucket]] = [:]
        for sample in samples {
            guard let interval = CategoryIntervalClipper.clip(
                sampleStart: sample.startDate,
                sampleEnd: sample.endDate,
                to: start..<end
            ) else { continue }
            if interval.isEmpty {
                let day = Self.dayFormatter.string(from: interval.lowerBound)
                var bucket = days[day, default: [:]][sample.value, default: Bucket()]
                bucket.count += 1
                days[day, default: [:]][sample.value] = bucket
                continue
            }

            var cursor = interval.lowerBound
            while cursor < interval.upperBound {
                let dayStart = calendar.startOfDay(for: cursor)
                let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? interval.upperBound
                let segmentEnd = min(nextDay, interval.upperBound)
                let day = Self.dayFormatter.string(from: dayStart)
                var bucket = days[day, default: [:]][sample.value, default: Bucket()]
                bucket.count += cursor == interval.lowerBound ? 1 : 0
                bucket.seconds += segmentEnd.timeIntervalSince(cursor)
                days[day, default: [:]][sample.value] = bucket
                cursor = segmentEnd
            }
        }

        guard !days.isEmpty else { return nil }
        let daily: [[Any]] = days.keys.sorted().map { day in
            let values: [[Any]] = (days[day] ?? [:]).keys.sorted().map { value in
                let bucket = days[day]?[value] ?? Bucket()
                return [categoryValueName(type.identifier, value: value), bucket.count, Self.rounded(bucket.seconds / 60)]
            }
            return [day, values]
        }
        return ["typeIdentifier": type.identifier, "daily": daily]
    }

    private func workoutPayload(
        start: Date,
        end: Date,
        units: [HKQuantityType: HKUnit]
    ) async throws -> [[String: Any]] {
        let workouts = try await samples(of: HKObjectType.workoutType(), start: start, end: end)
            .compactMap { $0 as? HKWorkout }
            .sorted { $0.startDate < $1.startDate }
        return workouts.map { workout in
            var statistics: [String: Any] = [:]
            for value in workout.allStatistics.values {
                guard let unit = units[value.quantityType] else { continue }
                var row: [String: Any] = ["unit": unit.unitString]
                if let sum = value.sumQuantity()?.doubleValue(for: unit) { row["sum"] = Self.rounded(sum) }
                if let average = value.averageQuantity()?.doubleValue(for: unit) { row["average"] = Self.rounded(average) }
                if let minimum = value.minimumQuantity()?.doubleValue(for: unit) { row["minimum"] = Self.rounded(minimum) }
                if let maximum = value.maximumQuantity()?.doubleValue(for: unit) { row["maximum"] = Self.rounded(maximum) }
                statistics[semanticKey(value.quantityType.identifier)] = row
            }
            return [
                "start": Self.iso8601.string(from: workout.startDate),
                "end": Self.iso8601.string(from: workout.endDate),
                "durationMinutes": Self.rounded(workout.duration / 60),
                "activity": workoutActivityName(workout.workoutActivityType),
                "activityCode": workout.workoutActivityType.rawValue,
                "statistics": statistics
            ]
        }
    }

    private func sleepIntervalPayload(start: Date, end: Date) async throws -> [[String]] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let samples = try await samples(of: type, start: start, end: end)
            .compactMap { $0 as? HKCategorySample }
            .map { (start: $0.startDate, end: $0.endDate, value: $0.value) }
        return CategoryIntervalClipper.sleepIntervals(samples: samples, to: start..<end).map {
            [Self.iso8601.string(from: $0.start), Self.iso8601.string(from: $0.end), $0.value]
        }
    }

    private func activityPayload(start: Date, end: Date) async throws -> [[String: Any]] {
        var startComponents = calendar.dateComponents([.era, .year, .month, .day], from: start)
        var endComponents = calendar.dateComponents([.era, .year, .month, .day], from: end)
        startComponents.calendar = calendar
        endComponents.calendar = calendar
        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: startComponents, end: endComponents)
        let summaries = try await HKActivitySummaryQueryDescriptor(predicate: predicate).result(for: healthStore)
        return summaries.compactMap { summary in
            guard let date = summary.dateComponents(for: calendar).date else { return nil }
            return [
                "date": Self.dayFormatter.string(from: date),
                "activeEnergyKilocalories": Self.rounded(summary.activeEnergyBurned.doubleValue(for: .kilocalorie())),
                "exerciseMinutes": Self.rounded(summary.appleExerciseTime.doubleValue(for: .minute())),
                "standHours": Self.rounded(summary.appleStandHours.doubleValue(for: .count()))
            ]
        }.sorted { ($0["date"] as? String ?? "") < ($1["date"] as? String ?? "") }
    }

    private func specialPayload(start: Date, end: Date) async throws -> [String: Any] {
        var result: [String: Any] = [:]
        let assessmentTypes = [
            "HKScoredAssessmentTypeIdentifierGAD7",
            "HKScoredAssessmentTypeIdentifierPHQ9"
        ].map { HKScoredAssessmentType(HKScoredAssessmentTypeIdentifier(rawValue: $0)) }
        let types: [HKSampleType] = [
            HKObjectType.electrocardiogramType(),
            HKObjectType.stateOfMindType(),
            HKObjectType.audiogramSampleType()
        ] + assessmentTypes

        for type in types {
            let values = try await samples(of: type, start: start, end: end)
            guard !values.isEmpty else { continue }
            result[semanticKey(type.identifier)] = values.suffix(100).map { sample in
                var item: [String: Any] = [
                    "start": Self.iso8601.string(from: sample.startDate),
                    "end": Self.iso8601.string(from: sample.endDate)
                ]
                if let ecg = sample as? HKElectrocardiogram {
                    item["classification"] = ecg.classification.rawValue
                    item["symptomsStatus"] = ecg.symptomsStatus.rawValue
                    if let heartRate = ecg.averageHeartRate {
                        item["averageHeartRateBPM"] = Self.rounded(heartRate.doubleValue(
                            for: HKUnit.count().unitDivided(by: .minute())
                        ))
                    }
                } else if let state = sample as? HKStateOfMind {
                    item["kind"] = state.kind.rawValue
                    item["valence"] = state.valence
                    item["labels"] = state.labels.map(\.rawValue)
                    item["associations"] = state.associations.map(\.rawValue)
                } else if let assessment = sample as? HKScoredAssessment {
                    item["score"] = assessment.score
                } else if let audiogram = sample as? HKAudiogramSample {
                    item["frequencyPointCount"] = audiogram.sensitivityPoints.count
                }
                return item
            }
        }
        return result
    }

    private func samples(of type: HKSampleType, start: Date, end: Date) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            healthStore.execute(query)
        }
    }

    private func profilePayload() -> [String: Any] {
        var result: [String: Any] = [:]
        if let date = try? healthStore.dateOfBirthComponents() {
            result["dateOfBirth"] = [
                "year": date.year.map { $0 as Any } ?? NSNull(),
                "month": date.month.map { $0 as Any } ?? NSNull(),
                "day": date.day.map { $0 as Any } ?? NSNull()
            ]
        }
        if let sex = try? healthStore.biologicalSex() { result["biologicalSex"] = sex.biologicalSex.rawValue }
        if let blood = try? healthStore.bloodType() { result["bloodType"] = blood.bloodType.rawValue }
        if let wheelchair = try? healthStore.wheelchairUse() { result["wheelchairUse"] = wheelchair.wheelchairUse.rawValue }
        return result
    }

    private func semanticKey(_ identifier: String) -> String {
        let prefixes = [
            "HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier", "HKScoredAssessmentTypeIdentifier",
            "HKDataTypeIdentifier", "HKWorkoutTypeIdentifier", "HK"
        ]
        var key = identifier
        for prefix in prefixes where key.hasPrefix(prefix) {
            key.removeFirst(prefix.count)
            break
        }
        guard let first = key.first else { return identifier }
        return first.lowercased() + key.dropFirst()
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    private func categoryValueName(_ identifier: String, value: Int) -> String {
        if identifier == "HKCategoryTypeIdentifierSleepAnalysis" {
            return [0: "inBed", 1: "asleepUnspecified", 2: "awake", 3: "asleepCore", 4: "asleepDeep", 5: "asleepREM"][value]
                ?? "value_\(value)"
        }
        if identifier == "HKCategoryTypeIdentifierAppleStandHour" {
            return [0: "stood", 1: "idle"][value] ?? "value_\(value)"
        }
        return "value_\(value)"
    }

    private func workoutActivityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking: "walking"
        case .running: "running"
        case .cycling: "cycling"
        case .swimming: "swimming"
        case .hiking: "hiking"
        case .yoga: "yoga"
        case .traditionalStrengthTraining: "traditionalStrengthTraining"
        case .functionalStrengthTraining: "functionalStrengthTraining"
        case .highIntensityIntervalTraining: "highIntensityIntervalTraining"
        case .coreTraining: "coreTraining"
        case .elliptical: "elliptical"
        case .rowing: "rowing"
        case .stairClimbing: "stairClimbing"
        case .dance: "dance"
        case .mindAndBody: "mindAndBody"
        case .soccer: "soccer"
        case .basketball: "basketball"
        case .tennis: "tennis"
        case .crossTraining: "crossTraining"
        case .cooldown: "cooldown"
        default: "activity_\(type.rawValue)"
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
