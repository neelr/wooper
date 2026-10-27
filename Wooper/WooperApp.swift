import BackgroundTasks
import SwiftData
import SwiftUI

extension Notification.Name {
    /// Posted when a silent push says the papery list changed server-side;
    /// any visible list should reload rather than wait for pull-to-refresh.
    static let paperyServerChanged = Notification.Name("paperyServerChanged")
}

/// Minimal delegate whose only job is instantiating the BLE central before
/// application(_:didFinishLaunching...) returns — CoreBluetooth state
/// restoration requires the restored central to exist by then — and
/// registering the lens cache refresh background task.
final class WooperAppDelegate: NSObject, UIApplicationDelegate {
    static let lensRefreshTaskID = "com.neelr.Wooper.lensrefresh"

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        DSOrientationLock.orientations(for: window)
    }


    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = LensSyncService.shared

        // Periodic background refresh: while the phone has internet, keep the
        // offline cache (index + article texts) current, so a later reader
        // sync works with no connectivity at all. iOS decides the actual
        // cadence; typically a handful of runs per day.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.lensRefreshTaskID, using: nil) { task in
            Self.scheduleLensRefresh()
            let work = Task {
                await PaperyCache.refresh()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Silent pushes need no user permission prompt — just the entitlement.
        // papery's server pings us when an article is saved, so the reader can
        // be topped up within seconds instead of at the next 5-min window.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        lensLog("[lens] apns token registered")
        Task { try? await PaperyService.registerPushToken(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        lensLog("[lens] apns registration failed: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        lensLog("[lens] apns push received")
        LensSyncService.shared.markServerDirty()
        NotificationCenter.default.post(name: .paperyServerChanged, object: nil)
        Task {
            // Refresh the phone-side cache, then nudge the reader if in range.
            await PaperyCache.refresh()
            LensSyncService.shared.syncNow()
            completionHandler(.newData)
        }
    }

    static func scheduleLensRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: lensRefreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

@main
struct WooperApp: App {
    @UIApplicationDelegateAdaptor(WooperAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppShell()
        }
        .modelContainer(for: Recording.self)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Every foregrounding tops up the offline cache and flushes any
                // read states collected from the reader while offline.
                Task.detached { await PaperyCache.refresh() }
            case .background:
                WooperAppDelegate.scheduleLensRefresh()
            default:
                break
            }
        }
    }
}
