import Foundation

enum CloudExportStoreError: LocalizedError {
    case wouldReplacePopulatedSnapshotWithEmpty

    var errorDescription: String? {
        switch self {
        case .wouldReplacePopulatedSnapshotWithEmpty:
            "HealthKit временно не вернул данные; предыдущий снимок сохранён."
        }
    }
}

final class CloudExportStore {
    private let fileManager: FileManager
    private let folderAccess: ExportFolderAccess
    private let encoder: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    private let updateRetention: TimeInterval = 7 * 24 * 60 * 60

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
                    let url = Self.exportRoot(for: selectedFolder)
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

    func writeAgentSnapshot(_ object: [String: Any]) async throws -> (ExportLocation, URL, Data) {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let csvData = try HealthContextCSVEncoder.data(from: object)
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
        let csvDestination = agentFolder.appendingPathComponent("health-context.csv")
        if !Self.hasHealthContent(object),
           let existingData = try? Data(contentsOf: destination),
           let existingObject = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
           Self.hasHealthContent(existingObject) {
            throw CloudExportStoreError.wouldReplacePopulatedSnapshotWithEmpty
        }
        // Write CSV first so a failed CSV write leaves the JSON snapshot untouched.
        // Each public file is atomically replaced; JSON remains the canonical sync contract.
        try coordinatedWrite(csvData, to: csvDestination)
        try coordinatedWrite(data, to: destination)
        if let documents = try? fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            try? fileManager.removeItem(at: documents.appendingPathComponent("AgentDebug", isDirectory: true))
        }
        return (location, destination, data)
    }

    func writeAgentUpdate(_ object: [String: Any]) async throws -> (ExportLocation, URL, Data) {
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

        let inbox = location.url
            .deletingLastPathComponent()
            .appendingPathComponent("Agent/Inbox", isDirectory: true)
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        try pruneAgentUpdates(in: inbox, before: Date().addingTimeInterval(-updateRetention))

        let milliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let filename = "health-update-\(milliseconds)-\(UUID().uuidString.lowercased()).json"
        let destination = inbox.appendingPathComponent(filename)
        try coordinatedWrite(data, to: destination)
        return (location, destination, data)
    }

    func makeAgentSnapshotShareCopy(format: ShareFormat) async throws -> URL {
        let location = try await resolveLocation()
        let selectedFolder = folderAccess.resolve()
        return try await Task.detached(priority: .userInitiated) { [fileManager] in
            let startedAccess = selectedFolder?.startAccessingSecurityScopedResource() ?? false
            defer {
                if startedAccess { selectedFolder?.stopAccessingSecurityScopedResource() }
            }

            let source = location.url
                .deletingLastPathComponent()
                .appendingPathComponent("Agent/\(format.fileName)")
            guard fileManager.fileExists(atPath: source.path) else {
                throw CocoaError(.fileNoSuchFile)
            }

            let shareFolder = fileManager.temporaryDirectory
                .appendingPathComponent("HealthJSONShare", isDirectory: true)
            try fileManager.createDirectory(at: shareFolder, withIntermediateDirectories: true)
            let destination = shareFolder.appendingPathComponent(format.fileName)
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: source, to: destination)
            return destination
        }.value
    }

    static func exportRoot(for selectedFolder: URL) -> URL {
        selectedFolder.lastPathComponent.caseInsensitiveCompare("Health JSON") == .orderedSame
            ? selectedFolder
            : selectedFolder.appendingPathComponent("Health JSON", isDirectory: true)
    }

    private static func hasHealthContent(_ object: [String: Any]) -> Bool {
        let dictionaries = ["metrics", "categories", "special"]
        if dictionaries.contains(where: { !(object[$0] as? [String: Any] ?? [:]).isEmpty }) {
            return true
        }
        let arrays = ["activityRings", "workouts"]
        return arrays.contains { !(object[$0] as? [Any] ?? []).isEmpty }
    }

    private func coordinatedWrite(_ data: Data, to destination: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        let options: NSFileCoordinator.WritingOptions = fileManager.fileExists(atPath: destination.path)
            ? .forReplacing
            : []
        coordinator.coordinate(writingItemAt: destination, options: options, error: &coordinationError) { url in
            do {
                try data.write(
                    to: url,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
            } catch {
                writeError = error
            }
        }
        if let writeError { throw writeError }
        if let coordinationError { throw coordinationError }
    }

    private func pruneAgentUpdates(in inbox: URL, before cutoff: Date) throws {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        for url in try fileManager.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) where url.lastPathComponent.hasPrefix("health-update-") && url.pathExtension == "json" {
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate,
                  modified < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter
    }()
}
