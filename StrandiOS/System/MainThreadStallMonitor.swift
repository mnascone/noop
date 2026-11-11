import Foundation
import UIKit

// MARK: - Main-thread stalls (iOS)
//
// A frozen or laggy screen is the main thread busy with something else. A utility-queue timer posts a
// ping to the main queue every 250 ms. When the main thread answers a ping late by `reportS` or more while
// the app is in the foreground, one `perf:` line records how long it was blocked and which tab was showing,
// so it can be lined up with the timed `perf:` steps around it. Nothing is logged when nothing stalls.
//
// A ping left outstanding when the app is suspended would come back as one long "stall" on resume. Each
// foreground/background transition starts a new epoch and a ping from an older epoch is dropped.

final class MainThreadStallMonitor: @unchecked Sendable {

    static let shared = MainThreadStallMonitor()

    /// Shorter waits are frame hitches, not the multi-second waits being chased.
    static let reportS = 0.5
    static let pingInterval: DispatchTimeInterval = .milliseconds(250)

    /// Set by the tab shell so a stall line says what was on screen.
    @MainActor static var currentScreen = "?"

    private let queue = DispatchQueue(label: "noop.perf.stall", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var outstanding: (sentAt: UInt64, epoch: Int)?
    private var epoch = 0
    private var foreground = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Called once at launch. Safe to call again.
    @MainActor func start() {
        guard timer == nil else { return }
        let nc = NotificationCenter.default
        let active = { [weak self] (on: Bool) in
            guard let self else { return }
            self.lock.lock()
            self.epoch &+= 1
            self.foreground = on
            self.outstanding = nil
            self.lock.unlock()
        }
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                        queue: .main) { _ in active(true) })
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                        queue: .main) { _ in active(false) })
        active(UIApplication.shared.applicationState == .active)

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        t.setEventHandler { [weak self] in self?.ping() }
        timer = t
        t.resume()
    }

    private func ping() {
        lock.lock()
        guard foreground, outstanding == nil else { lock.unlock(); return }
        let token = (sentAt: PerfLog.mark(), epoch: epoch)
        outstanding = token
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.pong(token) }
    }

    private func pong(_ token: (sentAt: UInt64, epoch: Int)) {
        lock.lock()
        let current = outstanding.map { $0.epoch == token.epoch && $0.sentAt == token.sentAt } ?? false
        if current { outstanding = nil }
        let stillForeground = foreground && epoch == token.epoch
        lock.unlock()
        guard current, stillForeground else { return }
        let waited = PerfLog.seconds(since: token.sentAt)
        guard waited >= Self.reportS else { return }
        MainActor.assumeIsolated {
            PerfLog.sink?("perf: main thread blocked \(String(format: "%.2f", waited)) s on \(Self.currentScreen)")
        }
    }
}
