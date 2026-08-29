import Foundation

@main
struct HealthDataSnapshotTests {
    static func main() throws {
        let fixture = """
        {
          "schemaVersion": 1,
          "kind": "health-agent-context",
          "generatedAt": "2026-08-29T12:00:00.000Z",
          "period": { "start": "2026-08-28", "end": "2026-08-29", "days": 2, "timeZone": "UTC" },
          "profile": { "biologicalSex": 1 },
          "metrics": {
            "stepCount": {
              "typeIdentifier": "HKQuantityTypeIdentifierStepCount",
              "unit": "count",
              "aggregation": "dailySum",
              "daily": [["2026-08-29", 8123]]
            },
            "heartRate": {
              "typeIdentifier": "HKQuantityTypeIdentifierHeartRate",
              "unit": "count/min",
              "aggregation": "dailyAverageMinMaxLatest",
              "daily": [["2026-08-29", 62, 55, 91, 60]]
            }
          },
          "categories": {
            "sleepAnalysis": {
              "typeIdentifier": "HKCategoryTypeIdentifierSleepAnalysis",
              "daily": [["2026-08-29", [["asleepCore", 1, 420]]]]
            }
          },
          "activityRings": [{ "date": "2026-08-29", "activeEnergyKilocalories": 450, "exerciseMinutes": 30, "standHours": 10 }],
          "workouts": [{ "start": "2026-08-29T09:00:00.000Z", "end": "2026-08-29T09:30:00.000Z", "durationMinutes": 30, "activity": "walking", "activityCode": 52, "statistics": {} }],
          "sleepIntervals": [["2026-08-28T23:00:00.000Z", "2026-08-29T07:00:00.000Z", "asleepCore"]],
          "special": { "electrocardiogram": [{ "start": "2026-08-29T10:00:00.000Z", "end": "2026-08-29T10:01:00.000Z", "classification": 1 }] }
        }
        """

        let snapshot = try HealthDataSnapshot.decode(data: try XCTData.data(from: fixture))
        precondition(snapshot.metrics.count == 2)
        precondition(snapshot.categories.count == 1)
        precondition(snapshot.activityRings.count == 1)
        precondition(snapshot.workouts.count == 1)
        precondition(snapshot.parsedSleepIntervals.count == 1)
        precondition(snapshot.special["electrocardiogram"]?.first?.details["classification"]?.integerValue == 1)

        let steps = try unwrap(snapshot.metrics["stepCount"])
        let stepPoint = try unwrap(snapshot.metricPoints(for: steps).first)
        precondition(stepPoint.sum == 8123)

        let heartRate = try unwrap(snapshot.metrics["heartRate"])
        let heartRatePoint = try unwrap(snapshot.metricPoints(for: heartRate).first)
        precondition(heartRatePoint.average == 62)
        precondition(heartRatePoint.minimum == 55)
        precondition(heartRatePoint.maximum == 91)
        precondition(heartRatePoint.latest == 60)

        let sleep = try unwrap(snapshot.categories["sleepAnalysis"])
        let sleepPoint = try unwrap(snapshot.categoryPoints(for: sleep).first)
        precondition(sleepPoint.value == "asleepCore")
        precondition(sleepPoint.minutes == 420)

        let today = try unwrap(SnapshotDate.parseDay("2026-08-29"))
        precondition(HealthDataPeriod.today.includes(stepPoint.parsedDate, now: today))
        precondition(HealthDataPeriod.week.includes(stepPoint.parsedDate, now: today))
        precondition(HealthDataPeriod.month.includes(stepPoint.parsedDate, now: today))
        precondition(HealthDataPeriod.year.includes(stepPoint.parsedDate, now: today))

        let weekBoundary = try unwrap(SnapshotDate.parseDay("2026-08-23"))
        let beforeWeek = try unwrap(SnapshotDate.parseDay("2026-08-22"))
        let monthBoundary = try unwrap(SnapshotDate.parseDay("2026-07-31"))
        let beforeMonth = try unwrap(SnapshotDate.parseDay("2026-07-30"))
        let yearBoundary = try unwrap(SnapshotDate.parseDay("2025-08-30"))
        let beforeYear = try unwrap(SnapshotDate.parseDay("2025-08-29"))
        precondition(HealthDataPeriod.week.includes(weekBoundary, now: today))
        precondition(!HealthDataPeriod.week.includes(beforeWeek, now: today))
        precondition(HealthDataPeriod.month.includes(monthBoundary, now: today))
        precondition(!HealthDataPeriod.month.includes(beforeMonth, now: today))
        precondition(HealthDataPeriod.year.includes(yearBoundary, now: today))
        precondition(!HealthDataPeriod.year.includes(beforeYear, now: today))
        precondition(HealthDisplayValue.normalized(0.98, unit: "%") == 98)
        precondition(HealthDisplayValue.normalized(450, unit: "Cal") == 450)
        precondition(snapshot.allRecordCount == 7)
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.coderValueNotFound) }
        return value
    }
}

private enum XCTData {
    static func data(from string: String) throws -> Data {
        guard let data = string.data(using: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return data
    }
}
