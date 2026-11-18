import SwiftUI
import KumoneIOSFeature
import BackgroundTasks
import UIKit

@main
struct MoumusicIOSApp: App {
    @UIApplicationDelegateAdaptor(MoumusicAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            IOSMainWindow()
        }
    }
}

/// Requests an iOS-managed refresh window. iOS decides the actual execution
/// time; the coordinator still enforces the 12-hour limit and performs the
/// same check when the app returns to the foreground.
final class MoumusicAppDelegate: NSObject, UIApplicationDelegate {
    static let providerRefreshIdentifier = "com.jiajia2222.imusic.provider-refresh"

    /// A re-signed IPA can lose Info.plist keys. `BGTaskScheduler.register`
    /// throws an uncatchable NSException when its identifier is not declared,
    /// which kills the app during launch. Verify the plist before registering.
    private static var backgroundRefreshIsConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let permitted = info["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? []
        let modes = info["UIBackgroundModes"] as? [String] ?? []
        return permitted.contains(providerRefreshIdentifier) && modes.contains("fetch")
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must be the very first statement: everything after this point is
        // recorded even if the process dies during launch.
        DiagnosticLogger.shared.startSession()
        DiagnosticLogger.shared.info("didFinishLaunchingWithOptions", category: "launch")

        guard Self.backgroundRefreshIsConfigured else {
            DiagnosticLogger.shared.warning(
                "跳过 BGTaskScheduler 注册：Info.plist 中 BGTaskSchedulerPermittedIdentifiers / UIBackgroundModes(fetch) 不完整",
                category: "launch"
            )
            return true
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.providerRefreshIdentifier,
            using: nil
        ) { task in
            DiagnosticLogger.shared.info("background refresh task fired", category: "background")
            guard let task = task as? BGAppRefreshTask else {
                DiagnosticLogger.shared.error("background refresh task 类型不是 BGAppRefreshTask", category: "background")
                task.setTaskCompleted(success: false)
                return
            }
            self.handleProviderRefresh(task)
        }
        DiagnosticLogger.shared.info("BGTaskScheduler 注册完成", category: "launch")
        scheduleProviderRefresh()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        DiagnosticLogger.shared.markRunning()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        DiagnosticLogger.shared.markBackground()
        guard Self.backgroundRefreshIsConfigured else { return }
        scheduleProviderRefresh()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        DiagnosticLogger.shared.markWillTerminate()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        DiagnosticLogger.shared.warning("收到内存警告 (didReceiveMemoryWarning)", category: "memory")
    }

    private func handleProviderRefresh(_ task: BGAppRefreshTask) {
        scheduleProviderRefresh()
        let work = Task { @MainActor in
            await MusicSessionRefreshCoordinator.shared.refreshIfNeeded(force: true)
            task.setTaskCompleted(success: true)
            DiagnosticLogger.shared.info("background refresh 完成", category: "background")
        }
        task.expirationHandler = {
            DiagnosticLogger.shared.warning("background refresh 超时被系统取消", category: "background")
            work.cancel()
        }
    }

    private func scheduleProviderRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.providerRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            DiagnosticLogger.shared.warning("BGTaskScheduler.submit 失败：\(error.localizedDescription)", category: "background")
        }
    }
}
