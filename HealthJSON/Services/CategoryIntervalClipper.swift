import Foundation

enum CategoryIntervalClipper {
    struct SleepInterval: Equatable, Hashable {
        let start: Date
        let end: Date
        let value: String
    }

    static func clip(
        sampleStart: Date,
        sampleEnd: Date,
        to range: Range<Date>
    ) -> Range<Date>? {
        guard range.lowerBound < range.upperBound else { return nil }
        if sampleEnd == sampleStart {
            guard range.contains(sampleStart) else { return nil }
            return sampleStart..<sampleStart
        }
        guard sampleEnd > sampleStart else { return nil }

        let start = max(sampleStart, range.lowerBound)
        let end = min(sampleEnd, range.upperBound)
        guard start < end else { return nil }
        return start..<end
    }

    static func sleepIntervals(
        samples: [(start: Date, end: Date, value: Int)],
        to range: Range<Date>
    ) -> [SleepInterval] {
        let clipped: [SleepInterval] = samples.compactMap { sample -> SleepInterval? in
            guard let value = sleepValueName(sample.value),
                  let interval = clip(sampleStart: sample.start, sampleEnd: sample.end, to: range),
                  !interval.isEmpty else { return nil }
            return SleepInterval(start: interval.lowerBound, end: interval.upperBound, value: value)
        }.sorted {
            ($0.start, $0.end, $0.value) < ($1.start, $1.end, $1.value)
        }
        var seen = Set<SleepInterval>()
        return clipped.filter { seen.insert($0).inserted }
    }

    private static func sleepValueName(_ value: Int) -> String? {
        [
            0: "inBed",
            1: "asleepUnspecified",
            2: "awake",
            3: "asleepCore",
            4: "asleepDeep",
            5: "asleepREM",
        ][value]
    }
}
