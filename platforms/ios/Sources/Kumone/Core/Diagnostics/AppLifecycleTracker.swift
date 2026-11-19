import Foundation

/// Tracks foreground/background transitions so playback code can tell a real
/// provider timeout apart from one inflated by iOS suspending the process.
///
/// While the app sits in the background its execution is frozen, but the wall
/// clock keeps running. A 5-second probe can therefore report "35 seconds
/// elapsed" the moment the user returns, even though the provider never had a
/// chance to answer. Recording that as a failure would skip a healthy song and
/// poison route-health statistics.
final class AppLifecycleTracker {
    static let shared = AppLifecycleTracker()

    private let lock = NSLock()
    private var lastBackgroundAt: Date?
    private var lastResumeAt: Date?

    /// Call from the scene-phase handler when the app leaves the foreground.
    func markBackground() {
        lock.lock()
        defer { lock.unlock() }
        lastBackgroundAt = Date()
    }

    /// Call from the scene-phase handler when the app becomes active again.
    func markForeground() {
        lock.lock()
        defer { lock.unlock() }
        lastResumeAt = Date()
    }

    /// Wall-clock seconds the process likely spent suspended after `since`,
    /// or 0 when no background→foreground transition overlaps that window.
    func suspensionOverlap(since: Date) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let bg = lastBackgroundAt, let fg = lastResumeAt,
              bg <= fg, fg > since else { return 0 }
        // The suspension ended after `since`, so at least the span from
        // `since` (or from the backgrounding, whichever is later) to the
        // resume was spent frozen.
        let start = max(bg, since)
        return fg.timeIntervalSince(start)
    }
}
