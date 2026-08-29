import Foundation

enum HealthContextCSVEncoder {
    private static let columns = [
        "schema_version", "generated_at", "period_start", "period_end",
        "record_type", "key", "type_identifier", "unit", "aggregation",
        "date", "value", "average", "minimum", "maximum", "latest",
        "count", "minutes", "start", "end", "activity", "details_json"
    ]

    static func data(from context: [String: Any]) throws -> Data {
        guard let generatedAt = context["generatedAt"] as? String,
              let period = context["period"] as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }

        let schemaVersion = string(context["schemaVersion"])
        let periodStart = string(period["start"])
        let periodEnd = string(period["end"])
        var rows: [[String]] = [columns]

        func add(
            recordType: String,
            key: String = "",
            typeIdentifier: String = "",
            unit: String = "",
            aggregation: String = "",
            date: String = "",
            value: Any? = nil,
            average: Any? = nil,
            minimum: Any? = nil,
            maximum: Any? = nil,
            latest: Any? = nil,
            count: Any? = nil,
            minutes: Any? = nil,
            start: String = "",
            end: String = "",
            activity: String = "",
            details: Any? = nil
        ) {
            rows.append([
                schemaVersion, generatedAt, periodStart, periodEnd,
                recordType, key, typeIdentifier, unit, aggregation,
                date, string(value), string(average), string(minimum), string(maximum), string(latest),
                string(count), string(minutes), start, end, activity, json(details)
            ])
        }

        if let profile = context["profile"] as? [String: Any], !profile.isEmpty {
            add(recordType: "profile", details: profile)
        }

        if let metrics = context["metrics"] as? [String: Any] {
            for key in metrics.keys.sorted() {
                guard let metric = metrics[key] as? [String: Any],
                      let daily = metric["daily"] as? [[Any]] else { continue }
                let typeIdentifier = string(metric["typeIdentifier"])
                let unit = string(metric["unit"])
                let aggregation = string(metric["aggregation"])
                for row in daily {
                    guard let date = row.first as? String else { continue }
                    if aggregation == "dailySum" {
                        add(
                            recordType: "metric", key: key, typeIdentifier: typeIdentifier,
                            unit: unit, aggregation: aggregation, date: date, value: value(row, 1)
                        )
                    } else {
                        add(
                            recordType: "metric", key: key, typeIdentifier: typeIdentifier,
                            unit: unit, aggregation: aggregation, date: date,
                            average: value(row, 1), minimum: value(row, 2),
                            maximum: value(row, 3), latest: value(row, 4)
                        )
                    }
                }
            }
        }

        if let categories = context["categories"] as? [String: Any] {
            for key in categories.keys.sorted() {
                guard let category = categories[key] as? [String: Any],
                      let daily = category["daily"] as? [[Any]] else { continue }
                for row in daily {
                    guard let date = row.first as? String,
                          let values = value(row, 1) as? [[Any]] else { continue }
                    for categoryValue in values {
                        add(
                            recordType: "category", key: key,
                            typeIdentifier: string(category["typeIdentifier"]), date: date,
                            value: value(categoryValue, 0), count: value(categoryValue, 1),
                            minutes: value(categoryValue, 2)
                        )
                    }
                }
            }
        }

        if let intervals = context["sleepIntervals"] as? [[Any]] {
            for interval in intervals {
                add(
                    recordType: "sleep_interval", value: value(interval, 2),
                    start: string(value(interval, 0)), end: string(value(interval, 1))
                )
            }
        }

        if let activityRings = context["activityRings"] as? [[String: Any]] {
            for activityRing in activityRings {
                add(
                    recordType: "activity_ring", date: string(activityRing["date"]), details: activityRing
                )
            }
        }

        if let workouts = context["workouts"] as? [[String: Any]] {
            for workout in workouts {
                add(
                    recordType: "workout", value: workout["durationMinutes"],
                    start: string(workout["start"]), end: string(workout["end"]),
                    activity: string(workout["activity"]), details: workout
                )
            }
        }

        if let special = context["special"] as? [String: Any] {
            for key in special.keys.sorted() {
                guard let records = special[key] as? [[String: Any]] else { continue }
                for record in records {
                    add(
                        recordType: "special", key: key,
                        start: string(record["start"]), end: string(record["end"]), details: record
                    )
                }
            }
        }

        let csv = rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        guard let data = csv.data(using: .utf8) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        return data
    }

    private static func value(_ row: [Any], _ index: Int) -> Any? {
        row.indices.contains(index) ? row[index] : nil
    }

    private static func string(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return value as? String ?? String(describing: value)
    }

    private static func json(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    private static func escape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
