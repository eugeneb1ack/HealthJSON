import Foundation

@main
struct CloudExportStorePathTests {
    static func main() {
        let parent = URL(fileURLWithPath: "/tmp/HealthJSON-Export-Tests", isDirectory: true)
        let ordinarySelection = parent.appendingPathComponent("My exports", isDirectory: true)
        let namedSelection = parent.appendingPathComponent("Health JSON", isDirectory: true)

        precondition(
            CloudExportStore.exportRoot(for: ordinarySelection).path
                == parent.appendingPathComponent("My exports/Health JSON", isDirectory: true).path
        )
        precondition(CloudExportStore.exportRoot(for: namedSelection).path == namedSelection.path)
        precondition(
            CloudExportStore.exportRoot(for: namedSelection).path
                != parent.appendingPathComponent("Health JSON/Health JSON", isDirectory: true).path
        )
    }
}
