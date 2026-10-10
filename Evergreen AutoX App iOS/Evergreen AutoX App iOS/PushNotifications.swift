import SwiftUI
import UIKit
import UserNotifications

// What iOS hands the app delegate, passed on to the model by
// PushNotificationWatcher. Kept out of AppModel so it stays free of UIKit.
@Observable
final class PushBridge {
    static let shared = PushBridge()

    var deviceToken: String?
    var openedEventID: Int?
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushBridge.shared.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Asked again on the next activation.
    }

    // A time posted while the app is open still shows; the Live tab may be
    // on another event or session.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let eventID = response.notification.request.content.userInfo["event_id"] as? Int {
            Task { @MainActor in PushBridge.shared.openedEventID = eventID }
        }
        completionHandler()
    }
}

enum PushPermission {
    // Asks the first time; afterwards iOS answers from Settings without asking.
    static func request() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
        return granted
    }

    static func allowed() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }
}

// iOS hands out the APNs token afresh on each registration, so every
// activation registers while notifications are wanted.
struct PushNotificationWatcher: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: scenePhase == .active && model.wantsNotifications) {
                guard scenePhase == .active, model.wantsNotifications, await PushPermission.allowed() else { return }
                UIApplication.shared.registerForRemoteNotifications()
            }
            .onChange(of: PushBridge.shared.deviceToken, initial: true) { _, token in
                if let token { model.pushToken = token }
            }
            .onChange(of: PushBridge.shared.openedEventID, initial: true) { _, eventID in
                guard let eventID else { return }
                PushBridge.shared.openedEventID = nil
                model.openNotifiedEvent(eventID)
            }
    }
}
