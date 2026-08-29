import Foundation

@main
struct HealthContextCSVEncoderTests {
    static func main() throws {
        let context: [String: Any] = [
            "schemaVersion": 1,
            "generatedAt": "2026-08-29T12:00:00.000Z",
            "period": ["start": "2026-08-28", "end": "2026-08-29"],
            "profile": ["biologicalSex": 1],
            "metrics": [
                "stepCount": [
                    "typeIdentifier": "HKQuantityTypeIdentifierStepCount",
                    "unit": "count",
                    "aggregation": "dailySum",
                    "daily": [["2026-08-29", 8123]]
                ],
                "heartRate": [
                    "typeIdentifier": "HKQuantityTypeIdentifierHeartRate",
                    "unit": "count/min",
                    "aggregation": "dailyAverageMinMaxLatest",
                    "daily": [["2026-08-29", 62, 55, 91, 60]]
                ]
            ],
            "categories": [
                "sleepAnalysis": [
                    "typeIdentifier": "HKCategoryTypeIdentifierSleepAnalysis",
                    "daily": [["2026-08-29", [["asleepCore", 1, 420]]]]
                ]
            ],
            "sleepIntervals": [["2026-08-28T23:00:00.000Z", "2026-08-29T07:00:00.000Z", "asleepCore"]],
            "activityRings": [["date": "2026-08-29", "exerciseMinutes": 30]],
            "workouts": [["start": "2026-08-29T09:00:00.000Z", "end": "2026-08-29T09:30:00.000Z", "activity": "walking", "durationMinutes": 30]],
            "special": ["stateOfMind": [["start": "2026-08-29T10:00:00.000Z", "end": "2026-08-29T10:01:00.000Z"]]]
        ]

        let data = try HealthContextCSVEncoder.data(from: context)
        guard let csv = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)

        precondition(lines.first?.contains("schema_version") == true)
        precondition(lines.contains { $0.contains("\"metric\"") && $0.contains("\"stepCount\"") && $0.contains("\"8123\"") })
        precondition(lines.contains { $0.contains("\"metric\"") && $0.contains("\"heartRate\"") && $0.contains("\"62\"") })
        precondition(lines.contains { $0.contains("\"category\"") && $0.contains("\"asleepCore\"") && $0.contains("\"420\"") })
        precondition(lines.contains { $0.contains("\"sleep_interval\"") })
        precondition(lines.contains { $0.contains("\"workout\"") && $0.contains("\"walking\"") })
    }
}
