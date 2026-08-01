import UIKit
import BackgroundTasks

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let refreshTaskIdentifier = "com.johndoe.HealthJSON.refresh"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerBackgroundRefresh()
        Self.scheduleBackgroundRefresh()
        HealthExportCoordinator.shared.installBackgroundObservers()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Self.scheduleBackgroundRefresh()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        HealthExportCoordinator.shared.handleAppDidBecomeActive()
    }

    static func scheduleBackgroundRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("HealthJSON BGAppRefresh submit failed: \(error)")
        }
    }

    private func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handle(refreshTask)
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        let operation = Task {
            let success = await HealthExportCoordinator.shared.performScheduledRefresh()
            task.setTaskCompleted(success: success)
        }
        task.expirationHandler = {
            operation.cancel()
        }
    }
}
