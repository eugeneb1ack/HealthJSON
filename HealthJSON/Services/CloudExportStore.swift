import Foundation

final class CloudExportStore {
    private let fileManager: FileManager
    private let folderAccess: ExportFolderAccess
    private let encoder: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    init(
        fileManager: FileManager = .default,
        folderAccess: ExportFolderAccess = ExportFolderAccess()
    ) {
        self.fileManager = fileManager
        self.folderAccess = folderAccess
    }

    func resolveLocation() async throws -> ExportLocation {
        try await Task.detached(priority: .utility) { [fileManager, folderAccess] in
            if let selectedFolder = folderAccess.resolve() {
                let startedAccess = selectedFolder.startAccessingSecurityScopedResource()
                defer {
                    if startedAccess { selectedFolder.stopAccessingSecurityScopedResource() }
                }
                do {
                    let url = selectedFolder
                        .appendingPathComponent("Health JSON", isDirectory: true)
                        .appendingPathComponent("Exports", isDirectory: true)
                    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                    return .selectedFolder(url)
                } catch {
                    folderAccess.remove()
                }
            }

            let documents = try fileManager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let url = documents.appendingPathComponent("HealthJSON-Local/Exports", isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return .local(url)
        }.value
    }

    func selectFolder(_ url: URL) async throws -> ExportLocation {
        try folderAccess.save(url)
        return try await resolveLocation()
    }

    func writeBatch(_ object: [String: Any], typeIdentifier: String) async throws -> ExportLocation {
        let data = try JSONSerialization.data(withJSONObject: object, options: encoder)
        let location = try await resolveLocation()
        let selectedFolder = folderAccess.resolve()
        let startedAccess = selectedFolder?.startAccessingSecurityScopedResource() ?? false
        defer {
            if startedAccess { selectedFolder?.stopAccessingSecurityScopedResource() }
        }
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: now)
        let folder = location.url
            .appendingPathComponent(String(format: "%04d", parts.year ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day ?? 0), isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let shortType = typeIdentifier
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "quantity-")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "category-")
            .replacingOccurrences(of: "HKClinicalTypeIdentifier", with: "clinical-")
            .replacingOccurrences(of: "HKCorrelationTypeIdentifier", with: "correlation-")
            .replacingOccurrences(of: "HK", with: "")
        let stamp = Self.fileDateFormatter.string(from: now)
        let name = "\(stamp)_\(shortType)_\(UUID().uuidString.lowercased()).json"
        try data.write(
            to: folder.appendingPathComponent(name),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        return location
    }

    func writeAgentSnapshot(_ object: [String: Any]) async throws -> (ExportLocation, URL) {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let location = try await resolveLocation()
        let selectedFolder = folderAccess.resolve()
        let startedAccess = selectedFolder?.startAccessingSecurityScopedResource() ?? false
        defer {
            if startedAccess { selectedFolder?.stopAccessingSecurityScopedResource() }
        }

        let agentFolder = location.url
            .deletingLastPathComponent()
            .appendingPathComponent("Agent", isDirectory: true)
        try fileManager.createDirectory(at: agentFolder, withIntermediateDirectories: true)
        let destination = agentFolder.appendingPathComponent("health-context.json")
        try data.write(
            to: destination,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        if let documents = try? fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            try? fileManager.removeItem(at: documents.appendingPathComponent("AgentDebug", isDirectory: true))
        }
        return (location, destination)
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter
    }()
}
