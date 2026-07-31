import Foundation

struct DirectHealthSyncReport: Sendable {
    let deliveredAt: Date?
    let pendingCount: Int
    let message: String?
}

actor DirectHealthSyncClient {
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let session: URLSession
    private let endpoint: URL?
    private let maximumPayloadBytes = 8 * 1024 * 1024
    private let maximumPendingFiles = 64

    private let lastDeliveryKey = "health-json.direct.last-delivery"
    private let failureCountKey = "health-json.direct.failure-count"
    private let nextRetryKey = "health-json.direct.next-retry"

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        endpoint: URL? = nil
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        if let endpoint {
            self.endpoint = endpoint
        } else if let raw = Bundle.main.object(forInfoDictionaryKey: "HealthUploadURL") as? String {
            self.endpoint = URL(string: raw)
        } else {
            self.endpoint = nil
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    func enqueueAndFlush(_ payload: Data) async -> DirectHealthSyncReport {
        guard endpoint != nil else {
            return report(message: "Прямая доставка не настроена")
        }
        guard !payload.isEmpty, payload.count <= maximumPayloadBytes else {
            return report(message: "Обновление слишком большое для прямой доставки")
        }
        do {
            let directory = try queueDirectory()
            let destination = directory.appendingPathComponent(
                "pending-\(Int64(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString.lowercased()).json"
            )
            try payload.write(
                to: destination,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            try pruneQueue(in: directory)
            return await flush(force: true)
        } catch {
            return report(message: "Не удалось поставить обновление в очередь")
        }
    }

    func flush(force: Bool = false) async -> DirectHealthSyncReport {
        guard let endpoint else {
            return report(message: "Прямая доставка не настроена")
        }
        if !force,
           let nextRetry = defaults.object(forKey: nextRetryKey) as? Date,
           nextRetry > Date() {
            return report(message: "Ожидается повторная отправка")
        }
        let files: [URL]
        do {
            files = try pendingFiles()
        } catch {
            return report(message: "Очередь отправки недоступна")
        }
        guard !files.isEmpty else {
            return report(message: nil)
        }

        var deliveredAt = defaults.object(forKey: lastDeliveryKey) as? Date
        for file in files {
            do {
                let payload = try Data(contentsOf: file, options: [.mappedIfSafe])
                guard !payload.isEmpty, payload.count <= maximumPayloadBytes else {
                    try? fileManager.removeItem(at: file)
                    continue
                }
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.httpBody = payload
                request.timeoutInterval = 30
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-HealthJSON-Request-ID")
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                switch http.statusCode {
                case 200..<300, 409:
                    try fileManager.removeItem(at: file)
                    deliveredAt = Date()
                    defaults.set(deliveredAt, forKey: lastDeliveryKey)
                    clearBackoff()
                case 422:
                    try fileManager.removeItem(at: file)
                    clearBackoff()
                    return report(message: "Mac отклонил некорректное обновление")
                case 401, 403:
                    scheduleRetry()
                    return report(message: "Tailscale не подтвердил доступ")
                case 500..<600:
                    scheduleRetry()
                    return report(message: "Mac временно недоступен")
                default:
                    scheduleRetry()
                    return report(message: "Mac отклонил обновление")
                }
            } catch {
                scheduleRetry()
                return report(message: "Нет связи с Mac — обновление сохранено")
            }
        }
        return report(deliveredAt: deliveredAt, message: nil)
    }

    private func queueDirectory() throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("HealthUploadQueue", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func pendingFiles() throws -> [URL] {
        let directory = try queueDirectory()
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("pending-") && $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func pruneQueue(in directory: URL) throws {
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("pending-") && $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for stale in files.dropLast(maximumPendingFiles) {
            try? fileManager.removeItem(at: stale)
        }
    }

    private func scheduleRetry() {
        let failures = min(defaults.integer(forKey: failureCountKey) + 1, 8)
        defaults.set(failures, forKey: failureCountKey)
        let delay = min(pow(2.0, Double(failures - 1)) * 5, 300)
        defaults.set(Date().addingTimeInterval(delay), forKey: nextRetryKey)
    }

    private func clearBackoff() {
        defaults.removeObject(forKey: failureCountKey)
        defaults.removeObject(forKey: nextRetryKey)
    }

    private func report(deliveredAt: Date? = nil, message: String?) -> DirectHealthSyncReport {
        DirectHealthSyncReport(
            deliveredAt: deliveredAt ?? defaults.object(forKey: lastDeliveryKey) as? Date,
            pendingCount: (try? pendingFiles().count) ?? 0,
            message: message
        )
    }
}
