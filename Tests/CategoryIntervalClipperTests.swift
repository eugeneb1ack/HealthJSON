import Foundation

@main
struct CategoryIntervalClipperTests {
    static func main() {
        let start = date("2025-07-17T00:00:00Z")
        let end = date("2026-07-18T00:00:00Z")

        expect(
            CategoryIntervalClipper.clip(
                sampleStart: date("2025-07-16T23:30:00Z"),
                sampleEnd: date("2025-07-17T00:30:00Z"),
                to: start..<end
            ),
            equals: start..<date("2025-07-17T00:30:00Z")
        )
        expect(
            CategoryIntervalClipper.clip(
                sampleStart: date("2026-07-17T23:30:00Z"),
                sampleEnd: date("2026-07-18T00:30:00Z"),
                to: start..<end
            ),
            equals: date("2026-07-17T23:30:00Z")..<end
        )
        expect(
            CategoryIntervalClipper.clip(sampleStart: start, sampleEnd: start, to: start..<end),
            equals: start..<start
        )
        precondition(CategoryIntervalClipper.clip(sampleStart: end, sampleEnd: end, to: start..<end) == nil)
        precondition(CategoryIntervalClipper.clip(
            sampleStart: date("2025-07-16T22:00:00Z"),
            sampleEnd: start,
            to: start..<end
        ) == nil)
        precondition(CategoryIntervalClipper.clip(
            sampleStart: date("2025-07-17T01:00:00Z"),
            sampleEnd: start,
            to: start..<end
        ) == nil)

        let sleepRows = CategoryIntervalClipper.sleepIntervals(samples: [
            (date("2025-07-17T02:00:00Z"), date("2025-07-17T03:00:00Z"), 5),
            (date("2025-07-16T23:30:00Z"), date("2025-07-17T00:30:00Z"), 3),
            (date("2025-07-17T02:00:00Z"), date("2025-07-17T03:00:00Z"), 4),
            (date("2025-07-17T02:00:00Z"), date("2025-07-17T03:00:00Z"), 4),
            (date("2025-07-17T04:00:00Z"), date("2025-07-17T04:00:00Z"), 3),
            (date("2025-07-17T05:00:00Z"), date("2025-07-17T06:00:00Z"), 99),
        ], to: start..<end)
        precondition(sleepRows == [
            .init(start: start, end: date("2025-07-17T00:30:00Z"), value: "asleepCore"),
            .init(start: date("2025-07-17T02:00:00Z"), end: date("2025-07-17T03:00:00Z"), value: "asleepDeep"),
            .init(start: date("2025-07-17T02:00:00Z"), end: date("2025-07-17T03:00:00Z"), value: "asleepREM"),
        ])
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private static func expect(_ actual: Range<Date>?, equals expected: Range<Date>) {
        precondition(actual?.lowerBound == expected.lowerBound)
        precondition(actual?.upperBound == expected.upperBound)
    }
}
