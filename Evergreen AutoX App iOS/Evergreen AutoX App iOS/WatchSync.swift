import Foundation
import WatchConnectivity

extension AppModel {
    var watchContext: WatchContext {
        WatchContext(
            baseURL: baseURLString,
            eventID: selectedEventID,
            eventDate: selectedEvent?.startDate,
            sessionID: selectedSessionID,
            meNumber: meNumber,
            pins: pins.sorted(),
            nicknames: nicknames
        )
    }
}

// Hands the Watch app the latest WatchContext. Application context keeps only
// the newest value and is delivered whenever the Watch app next runs, so the
// Watch never has to ask. WCSession calls its delegate off the main thread,
// hence nonisolated and the lock.
nonisolated final class WatchSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSync()

    private let lock = NSLock()
    private var pending: WatchContext?
    private var sent: WatchContext?

    func send(_ context: WatchContext) {
        guard WCSession.isSupported() else { return }
        lock.withLock { pending = context }
        let session = WCSession.default
        if session.delegate == nil {
            session.delegate = self
            session.activate()
        } else {
            flush()
        }
    }

    private func flush() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let context: WatchContext? = lock.withLock {
            guard let pending, pending != sent else { return nil }
            return pending
        }
        guard let context else { return }
        do {
            try session.updateApplicationContext(context.message)
            lock.withLock { sent = context }
        } catch {
            // Left pending; the next change or watch state change retries.
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        flush()
    }

    // Installing the Watch app after the phone app sent its context.
    func sessionWatchStateDidChange(_ session: WCSession) {
        lock.withLock { sent = nil }
        flush()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    // Switching to another paired watch.
    func sessionDidDeactivate(_ session: WCSession) {
        lock.withLock { sent = nil }
        session.activate()
    }
}
