import Foundation

enum HealthImportEndpointError: Error, Equatable {
    case empty
    case invalidURL
    case requiresHTTPS
    case requiresTailnetHost
}

enum HealthImportEndpoint {
    static let importPath = "/health-json/v1/import"

    static func normalize(_ rawValue: String) throws -> URL {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { throw HealthImportEndpointError.empty }

        let candidate = trimmedValue.contains("://")
            ? trimmedValue
            : "https://\(trimmedValue)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            throw HealthImportEndpointError.invalidURL
        }
        guard scheme == "https" else { throw HealthImportEndpointError.requiresHTTPS }
        guard host.hasSuffix(".ts.net"), host.count > ".ts.net".count else {
            throw HealthImportEndpointError.requiresTailnetHost
        }

        components.scheme = "https"
        components.host = host
        components.path = importPath
        components.query = nil
        components.fragment = nil
        guard let endpoint = components.url else {
            throw HealthImportEndpointError.invalidURL
        }
        return endpoint
    }
}
