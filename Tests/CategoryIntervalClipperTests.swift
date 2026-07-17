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
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private static func expect(_ actual: Range<Date>?, equals expected: Range<Date>) {
        precondition(actual?.lowerBound == expected.lowerBound)
        precondition(actual?.upperBound == expected.upperBound)
    }
}
