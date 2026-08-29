import CryptoKit
import Foundation

struct DirectHealthSyncReport: Sendable {
    let deliveredAt: Date?
    let pendingCount: Int
    let message: String?
    let connectionState: DirectHealthSyncConnectionState
}

enum DirectHealthSyncConnectionState: Sendable {
    case idle
    case checking
    case connected
    case unreachable
    case unauthorized
    case serverUnavailable
    case notConfigured
}

actor DirectHealthSyncClient {
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let session: URLSession
    private var endpoint: URL?
    private let maximumPayloadBytes = 8 * 1024 * 1024
    private let maximumPendingFiles = 64

    private let lastDeliveryKey = "health-json.direct.last-delivery"
    private let failureCountKey = "health-json.direct.failure-count"
    private let nextRetryKey = "health-json.direct.next-retry"
    private let endpointKey = "health-json.direct.endpoint"

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        endpoint: URL? = nil
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        if let endpoint {
            self.endpoint = endpoint
        } else {
            self.endpoint = defaults.string(forKey: endpointKey).flatMap {
                try? HealthImportEndpoint.normalize($0)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    func configuredEndpoint() -> URL? {
        endpoint
    }

    func configureEndpoint(_ endpoint: URL?) {
        self.endpoint = endpoint
        if let endpoint {
            defaults.set(endpoint.absoluteString, forKey: endpointKey)
        } else {
            defaults.removeObject(forKey: endpointKey)
        }
        clearBackoff()
    }

    func enqueue(_ payload: Data) -> DirectHealthSyncReport {
        guard let endpoint else {
            return report(message: L10n.text("direct.message.not_configured"), connectionState: .notConfigured)
        }
        guard !payload.isEmpty, payload.count <= maximumPayloadBytes else {
            return report(message: L10n.text("direct.message.payload_too_large"), connectionState: .serverUnavailable)
        }
        do {
            let directory = try queueDirectory()
            let endpointPrefix = queuePrefix(for: endpoint)
            let destination = directory.appendingPathComponent(
                "pending-\(endpointPrefix)-\(Int64(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString.lowercased()).json"
            )
            try payload.write(
                to: destination,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            try pruneQueue(in: directory, for: endpoint)
            return report(message: L10n.text("direct.message.waiting"), connectionState: .idle)
        } catch {
            return report(message: L10n.text("direct.message.queue_failed"), connectionState: .serverUnavailable)
        }
    }

    func checkConnection() async -> DirectHealthSyncReport {
        guard let healthURL else {
            return report(message: L10n.text("direct.message.not_configured"), connectionState: .notConfigured)
        }

        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return report(message: L10n.text("direct.message.offline"), connectionState: .unreachable)
            }
            switch http.statusCode {
            case 200..<300:
                return report(message: nil, connectionState: .connected)
            case 401, 403:
                return report(message: L10n.text("direct.message.access_denied"), connectionState: .unauthorized)
            case 500..<600:
                return report(message: L10n.text("direct.message.server_unavailable"), connectionState: .serverUnavailable)
            default:
                return report(message: L10n.text("direct.message.service_unavailable"), connectionState: .serverUnavailable)
            }
        } catch {
            return report(message: L10n.text("direct.message.offline"), connectionState: .unreachable)
        }
    }

    func flush(force: Bool = false) async -> DirectHealthSyncReport {
        guard let endpoint else {
            return report(message: L10n.text("direct.message.not_configured"), connectionState: .notConfigured)
        }
        if !force,
           let nextRetry = defaults.object(forKey: nextRetryKey) as? Date,
           nextRetry > Date() {
            return report(message: L10n.text("direct.message.retry_waiting"), connectionState: .unreachable)
        }
        let files: [URL]
        do {
            files = try pendingFiles(for: endpoint)
        } catch {
            return report(message: L10n.text("direct.message.queue_unavailable"), connectionState: .serverUnavailable)
        }
        guard !files.isEmpty else {
            return report(message: nil, connectionState: .idle)
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
                    return report(message: L10n.text("direct.message.invalid_update"), connectionState: .serverUnavailable)
                case 401, 403:
                    scheduleRetry()
                    return report(message: L10n.text("direct.message.access_denied"), connectionState: .unauthorized)
                case 500..<600:
                    scheduleRetry()
                    return report(message: L10n.text("direct.message.server_unavailable"), connectionState: .serverUnavailable)
                default:
                    scheduleRetry()
                    return report(message: L10n.text("direct.message.rejected"), connectionState: .serverUnavailable)
                }
            } catch {
                scheduleRetry()
                return report(message: L10n.text("direct.message.offline_queued"), connectionState: .unreachable)
            }
        }
        return report(deliveredAt: deliveredAt, message: nil, connectionState: .connected)
    }

    private var healthURL: URL? {
        guard let endpoint,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let importRange = components.path.range(of: "/v1/import", options: .backwards)
        else {
            return nil
        }
        components.path.replaceSubrange(importRange, with: "/health")
        components.query = nil
        components.fragment = nil
        return components.url
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
        guard let endpoint else { return [] }
        return try pendingFiles(for: endpoint)
    }

    private func pendingFiles(for endpoint: URL) throws -> [URL] {
        let directory = try queueDirectory()
        let prefix = "pending-\(queuePrefix(for: endpoint))-"
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func pruneQueue(in directory: URL, for endpoint: URL) throws {
        let prefix = "pending-\(queuePrefix(for: endpoint))-"
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
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

    private func queuePrefix(for endpoint: URL) -> String {
        let digest = SHA256.hash(data: Data(endpoint.absoluteString.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func report(
        deliveredAt: Date? = nil,
        message: String?,
        connectionState: DirectHealthSyncConnectionState
    ) -> DirectHealthSyncReport {
        DirectHealthSyncReport(
            deliveredAt: deliveredAt ?? defaults.object(forKey: lastDeliveryKey) as? Date,
            pendingCount: (try? pendingFiles().count) ?? 0,
            message: message,
            connectionState: connectionState
        )
    }
}
