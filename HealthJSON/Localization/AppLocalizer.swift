import Foundation

enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: .autoupdatingCurrent, arguments: arguments)
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .day()
                .month(.abbreviated)
                .year()
                .hour()
                .minute()
                .locale(.autoupdatingCurrent)
        )
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(.autoupdatingCurrent))
    }
}
