import Foundation
import WatchConnectivity

// Receives the phone's WatchContext. WCSession keeps the last one it was sent
// in receivedApplicationContext, so activation alone catches up on anything
// the phone sent while this app was not running. The delegate is called off
// the main thread.
nonisolated final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let onContext: @Sendable (WatchContext) -> Void

    init(onContext: @escaping @Sendable (WatchContext) -> Void) {
        self.onContext = onContext
    }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let context = WatchContext(message: session.receivedApplicationContext) {
            onContext(context)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let context = WatchContext(message: applicationContext) {
            onContext(context)
        }
    }
}
