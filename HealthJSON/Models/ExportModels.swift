import Foundation

struct ExportIssue: Codable, Equatable {
    let typeIdentifier: String
    let message: String
    let code: Int
    let skipped: Bool
}

struct ExportStatistics: Codable, Equatable {
    var filesWritten = 0
    var samplesAdded = 0
    var samplesDeleted = 0
    var typesFailed = 0
    var typesSkipped = 0
    var issues: [ExportIssue] = []

    static func + (lhs: ExportStatistics, rhs: ExportStatistics) -> ExportStatistics {
        ExportStatistics(
            filesWritten: lhs.filesWritten + rhs.filesWritten,
            samplesAdded: lhs.samplesAdded + rhs.samplesAdded,
            samplesDeleted: lhs.samplesDeleted + rhs.samplesDeleted,
            typesFailed: lhs.typesFailed + rhs.typesFailed,
            typesSkipped: lhs.typesSkipped + rhs.typesSkipped,
            issues: lhs.issues + rhs.issues
        )
    }
}

enum ExportLocation: Equatable {
    case selectedFolder(URL)
    case local(URL)

    var url: URL {
        switch self {
        case .selectedFolder(let url), .local(let url): url
        }
    }

    var isSelectedFolder: Bool {
        if case .selectedFolder = self { return true }
        return false
    }
}

enum SyncPhase: Equatable {
    case idle
    case requestingAccess
    case exporting(current: Int, total: Int, type: String)
    case finished(ExportStatistics)
    case failed(String)
}
