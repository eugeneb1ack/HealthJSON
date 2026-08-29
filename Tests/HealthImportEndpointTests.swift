import Foundation

@main
struct HealthImportEndpointTests {
    static func main() throws {
        let rootURL = try HealthImportEndpoint.normalize("mac.example-tailnet.ts.net")
        precondition(rootURL.absoluteString == "https://mac.example-tailnet.ts.net/health-json/v1/import")

        let fullURL = try HealthImportEndpoint.normalize(
            "HTTPS://MAC.EXAMPLE-TAILNET.TS.NET/another/path?stale=true#fragment"
        )
        precondition(fullURL.absoluteString == "https://mac.example-tailnet.ts.net/health-json/v1/import")

        expectFailure("http://mac.example-tailnet.ts.net") { error in
            error == .requiresHTTPS
        }
        expectFailure("https://example.com") { error in
            error == .requiresTailnetHost
        }
        expectFailure(" ") { error in
            error == .empty
        }
        expectFailure("not a URL") { error in
            error == .invalidURL
        }
    }

    private static func expectFailure(
        _ value: String,
        matching predicate: (HealthImportEndpointError) -> Bool
    ) {
        do {
            _ = try HealthImportEndpoint.normalize(value)
            preconditionFailure("Expected endpoint validation to fail for \(value)")
        } catch let error as HealthImportEndpointError {
            precondition(predicate(error))
        } catch {
            preconditionFailure("Unexpected error: \(error)")
        }
    }
}
