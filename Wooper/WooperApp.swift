import BackgroundTasks
import SwiftData
import SwiftUI

extension Notification.Name {
    /// Posted when a silent push says the papery list changed server-side;
    /// any visible list should reload rather than wait for pull-to-refresh.
    static let paperyServerChanged = Notification.Name("paperyServerChanged")
}

/// Maintains Papery push notifications and offline cache refresh.
final class WooperAppDelegate: NSObject, UIApplicationDelegate {
    static let paperyRefreshTaskID = "com.neelr.Wooper.paperyrefresh"



    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        // Periodic background refresh: while the phone has internet, keep the
        // offline cache (index + article texts) current, so a later reader
        // sync works with no connectivity at all. iOS decides the actual
        // cadence; typically a handful of runs per day.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.paperyRefreshTaskID, using: nil) { task in
            Self.schedulePaperyRefresh()
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
        paperyLog("[papery] apns token registered")
        Task { try? await PaperyService.registerPushToken(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        paperyLog("[papery] apns registration failed: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        paperyLog("[papery] apns push received")
        NotificationCenter.default.post(name: .paperyServerChanged, object: nil)
        Task {
            // Refresh the phone-side offline cache.
            await PaperyCache.refresh()
            completionHandler(.newData)
        }
    }

    static func schedulePaperyRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: paperyRefreshTaskID)
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
                .onOpenURL { url in
                    // Widget links are delivered to the containing app.
                    // Forward article links to the user's default browser.
                    guard let scheme = url.scheme?.lowercased(),
                          ["https", "http"].contains(scheme),
                          url.host != nil else { return }
                    UIApplication.shared.open(url)
                }
        }
        .modelContainer(for: Recording.self)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Every foregrounding tops up the offline cache and flushes any
                // read states collected from the reader while offline.
                Task.detached { await PaperyCache.refresh() }
            case .background:
                WooperAppDelegate.schedulePaperyRefresh()
            default:
                break
            }
        }
    }
}
