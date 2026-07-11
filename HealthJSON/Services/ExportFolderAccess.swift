import Foundation

final class ExportFolderAccess {
    private let defaults: UserDefaults
    private let bookmarkKey = "health-json.export-folder-bookmark"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ folderURL: URL) throws {
        let startedAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if startedAccess { folderURL.stopAccessingSecurityScopedResource() }
        }

        let bookmark = try folderURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: bookmarkKey)
    }

    func resolve() -> URL? {
        guard let bookmark = defaults.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            defaults.removeObject(forKey: bookmarkKey)
            return nil
        }

        if isStale { try? save(url) }
        return url
    }

    func remove() {
        defaults.removeObject(forKey: bookmarkKey)
    }
}
