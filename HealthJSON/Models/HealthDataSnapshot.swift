import Foundation

/// A typed, read-only representation of the full JSON snapshot written by
/// `AgentHealthExporter`. The in-app viewer deliberately reads this file rather
/// than querying HealthKit again, so it always shows exactly what is available
/// to iCloud Drive, CSV export, and the optional API receiver.
struct HealthDataSnapshot: Sendable, Decodable {
    let schemaVersion: Int
    let kind: String
    let generatedAt: String
    let period: SnapshotPeriod
    let profile: [String: JSONValue]
    let metrics: [String: SnapshotMetric]
    let categories: [String: SnapshotCategory]
    let activityRings: [SnapshotActivityRing]
    let workouts: [SnapshotWorkout]
    let special: [String: [SnapshotSpecialRecord]]
    let sleepIntervals: [[String]]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case kind
        case generatedAt
        case period
        case profile
        case metrics
        case categories
        case activityRings
        case workouts
        case special
        case sleepIntervals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        kind = try container.decode(String.self, forKey: .kind)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
        period = try container.decode(SnapshotPeriod.self, forKey: .period)
        profile = try container.decodeIfPresent([String: JSONValue].self, forKey: .profile) ?? [:]
        metrics = try container.decodeIfPresent([String: SnapshotMetric].self, forKey: .metrics) ?? [:]
        categories = try container.decodeIfPresent([String: SnapshotCategory].self, forKey: .categories) ?? [:]
        activityRings = try container.decodeIfPresent([SnapshotActivityRing].self, forKey: .activityRings) ?? []
        workouts = try container.decodeIfPresent([SnapshotWorkout].self, forKey: .workouts) ?? []
        special = try container.decodeIfPresent([String: [SnapshotSpecialRecord]].self, forKey: .special) ?? [:]
        sleepIntervals = try container.decodeIfPresent([[String]].self, forKey: .sleepIntervals) ?? []
    }

    static func decode(data: Data) throws -> HealthDataSnapshot {
        let snapshot = try JSONDecoder().decode(HealthDataSnapshot.self, from: data)
        guard snapshot.schemaVersion == 1 else {
            throw HealthDataSnapshotError.unsupportedSchema(snapshot.schemaVersion)
        }
        guard snapshot.kind == "health-agent-context" else {
            throw HealthDataSnapshotError.unsupportedKind(snapshot.kind)
        }
        return snapshot
    }

    var generatedDate: Date? { SnapshotDate.parseTimestamp(generatedAt) }

    var allRecordCount: Int {
        let metricRows = metrics.values.reduce(0) { $0 + $1.daily.count }
        let categoryRows = categories.values.reduce(0) { $0 + $1.daily.count }
        let specialRows = special.values.reduce(0) { $0 + $1.count }
        return metricRows + categoryRows + activityRings.count + workouts.count + sleepIntervals.count + specialRows
    }

    func metricPoints(for metric: SnapshotMetric) -> [SnapshotMetricPoint] {
        metric.daily.compactMap { SnapshotMetricPoint(row: $0, aggregation: metric.aggregation) }
    }

    func categoryPoints(for category: SnapshotCategory) -> [SnapshotCategoryPoint] {
        category.daily.flatMap { SnapshotCategoryPoint.points(row: $0) }
    }

    var parsedSleepIntervals: [SnapshotSleepInterval] {
        sleepIntervals.compactMap(SnapshotSleepInterval.init(row:))
    }
}

enum HealthDataSnapshotError: LocalizedError {
    case unsupportedSchema(Int)
    case unsupportedKind(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema:
            "The saved snapshot uses an unsupported schema."
        case .unsupportedKind:
            "The saved file is not a complete Health JSON snapshot."
        }
    }
}

struct SnapshotPeriod: Sendable, Decodable {
    let start: String
    let end: String
    let days: Int
    let timeZone: String
}

struct SnapshotMetric: Sendable, Decodable {
    let typeIdentifier: String
    let unit: String
    let aggregation: String
    let daily: [[JSONValue]]
}

struct SnapshotMetricPoint: Identifiable, Sendable {
    let date: String
    let sum: Double?
    let average: Double?
    let minimum: Double?
    let maximum: Double?
    let latest: Double?

    var id: String { date }
    var parsedDate: Date? { SnapshotDate.parseDay(date) }

    init?(row: [JSONValue], aggregation: String) {
        guard let date = row.first?.stringValue else { return nil }
        self.date = date
        if aggregation == "dailySum" {
            sum = row.value(at: 1)?.doubleValue
            average = nil
            minimum = nil
            maximum = nil
            latest = nil
        } else {
            sum = nil
            average = row.value(at: 1)?.doubleValue
            minimum = row.value(at: 2)?.doubleValue
            maximum = row.value(at: 3)?.doubleValue
            latest = row.value(at: 4)?.doubleValue
        }
    }
}

struct SnapshotCategory: Sendable, Decodable {
    let typeIdentifier: String
    let daily: [[JSONValue]]
}

struct SnapshotCategoryPoint: Identifiable, Sendable {
    let date: String
    let value: String
    let count: Int?
    let minutes: Double?

    var id: String { "\(date)-\(value)" }
    var parsedDate: Date? { SnapshotDate.parseDay(date) }

    static func points(row: [JSONValue]) -> [SnapshotCategoryPoint] {
        guard let date = row.first?.stringValue,
              let values = row.value(at: 1)?.arrayValue else { return [] }
        return values.compactMap { valueRow in
            guard let fields = valueRow.arrayValue,
                  let value = fields.first?.stringValue else { return nil }
            return SnapshotCategoryPoint(
                date: date,
                value: value,
                count: fields.value(at: 1)?.integerValue,
                minutes: fields.value(at: 2)?.doubleValue
            )
        }
    }
}

struct SnapshotActivityRing: Sendable, Decodable, Identifiable {
    let date: String
    let activeEnergyKilocalories: Double?
    let exerciseMinutes: Double?
    let standHours: Double?

    var id: String { date }
    var parsedDate: Date? { SnapshotDate.parseDay(date) }
}

struct SnapshotWorkout: Sendable, Decodable, Identifiable {
    let start: String
    let end: String
    let durationMinutes: Double?
    let activity: String
    let activityCode: Int?
    let statistics: [String: SnapshotWorkoutStatistic]

    var id: String { "\(start)-\(activity)" }
    var startDate: Date? { SnapshotDate.parseTimestamp(start) }
    var endDate: Date? { SnapshotDate.parseTimestamp(end) }
}

struct SnapshotWorkoutStatistic: Sendable, Decodable {
    let unit: String
    let sum: Double?
    let average: Double?
    let minimum: Double?
    let maximum: Double?
}

struct SnapshotSleepInterval: Sendable, Identifiable {
    let start: String
    let end: String
    let value: String

    var id: String { "\(start)-\(end)-\(value)" }
    var startDate: Date? { SnapshotDate.parseTimestamp(start) }
    var endDate: Date? { SnapshotDate.parseTimestamp(end) }

    init?(row: [String]) {
        guard row.count >= 3 else { return nil }
        start = row[0]
        end = row[1]
        value = row[2]
    }
}

struct SnapshotSpecialRecord: Sendable, Decodable, Identifiable {
    let start: String
    let end: String
    let details: [String: JSONValue]

    var id: String { "\(start)-\(end)-\(details.keys.sorted().joined(separator: "-"))" }
    var startDate: Date? { SnapshotDate.parseTimestamp(start) }

    init(from decoder: Decoder) throws {
        var values = try [String: JSONValue](from: decoder)
        start = values.removeValue(forKey: "start")?.stringValue ?? ""
        end = values.removeValue(forKey: "end")?.stringValue ?? ""
        details = values
    }
}

enum HealthDataPeriod: String, CaseIterable, Identifiable, Sendable {
    case today
    case week
    case month
    case year

    var id: String { rawValue }

    func includes(_ date: Date?, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard let date else { return false }
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        guard day <= today else { return false }
        switch self {
        case .today:
            return calendar.isDate(day, inSameDayAs: today)
        case .week:
            guard let start = calendar.date(byAdding: .day, value: -6, to: today) else { return false }
            return day >= start
        case .month:
            guard let start = calendar.date(byAdding: .day, value: -29, to: today) else { return false }
            return day >= start
        case .year:
            guard let start = calendar.date(byAdding: .day, value: -364, to: today) else { return false }
            return day >= start
        }
    }
}

indirect enum JSONValue: Sendable, Decodable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var doubleValue: Double? {
        switch self {
        case let .number(value): value
        case let .string(value): Double(value)
        default: nil
        }
    }

    var integerValue: Int? {
        guard let doubleValue else { return nil }
        return Int(doubleValue)
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var displayText: String {
        switch self {
        case let .string(value): value
        case let .number(value): HealthNumberFormatter.string(value)
        case let .boolean(value): value ? L10n.text("viewer.value.yes") : L10n.text("viewer.value.no")
        case let .array(values): values.map(\.displayText).joined(separator: ", ")
        case let .object(values): values.keys.sorted().map { "\($0): \(values[$0]?.displayText ?? "")" }.joined(separator: ", ")
        case .null: L10n.text("viewer.value.not_available")
        }
    }
}

private extension Array where Element == JSONValue {
    func value(at index: Int) -> JSONValue? {
        indices.contains(index) ? self[index] : nil
    }
}

enum SnapshotDate {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standardISO8601 = ISO8601DateFormatter()

    static func parseDay(_ value: String) -> Date? {
        dayFormatter.date(from: value)
    }

    static func parseTimestamp(_ value: String) -> Date? {
        fractionalISO8601.date(from: value) ?? standardISO8601.date(from: value)
    }
}

enum HealthNumberFormatter {
    static func string(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(.autoupdatingCurrent))
    }
}

enum HealthDisplayValue {
    /// HealthKit represents 100 percent as `1.0` when the unit is `%`.
    /// JSON keeps that canonical HealthKit value; only the interface uses the
    /// human-readable 0…100 scale.
    static func normalized(_ value: Double, unit: String) -> Double {
        unit == "%" ? value * 100 : value
    }
}
