import Foundation

enum CategoryIntervalClipper {
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
}
