import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Watches the main thread from a background thread so a hang can be recorded
/// before iOS kills the app.
///
/// A watchdog termination (0x8badf00d) is a plain SIGKILL: no signal handler,
/// no NSException handler, nothing in the log. The only symptom is that the
/// previous session's marker stayed "running" while the last log line stops
/// mid-operation. This watchdog turns that invisible case into an explicit
/// `[FATAL] [crash] 主线程无响应` line, and also samples the memory footprint so
/// a jetsam kill can be told apart from a hang.
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()

    /// How long the main thread may stay unresponsive before it is reported.
    private let hangThreshold: TimeInterval = 8
    /// At most one hang report per window, so a permanent hang does not fill
    /// the log with the same line.
    private let reportCooldown: TimeInterval = 60
    /// Memory footprint sampling interval.
    private let memorySampleInterval: TimeInterval = 300

    private let lock = NSLock()
    private var started = false
    private var lastHeartbeat = Date()
    private var lastHangReport = Date.distantPast
    private var lastMemorySample = Date.distantPast
    private var heartbeatTimer: Timer?

    private init() {}

    /// Call on the main thread once the app is launched.
    func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lastHeartbeat = Date()
        lock.unlock()

        // A main-run-loop timer only fires while the main thread is free, which
        // is exactly the signal we want to measure.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.beat()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer

        let thread = Thread { [weak self] in self?.monitor() }
        thread.name = "MainThreadWatchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func beat() {
        lock.lock()
        lastHeartbeat = Date()
        lock.unlock()
    }

    private func monitor() {
        var wasForeground = false
        while true {
            Thread.sleep(forTimeInterval: 2)

            let isForeground = AppLifecycleTracker.shared.isForeground
            // Coming back from the background freezes this thread too, so the
            // heartbeat is stale by definition. Rebase instead of reporting a
            // hang that never happened.
            if isForeground != wasForeground {
                wasForeground = isForeground
                beat()
            }
            guard isForeground else { continue }

            let now = Date()
            lock.lock()
            let silence = now.timeIntervalSince(lastHeartbeat)
            let mayReport = now.timeIntervalSince(lastHangReport) >= reportCooldown
            let maySample = now.timeIntervalSince(lastMemorySample) >= memorySampleInterval
            if silence > hangThreshold, mayReport {
                lastHangReport = now
            }
            if maySample {
                lastMemorySample = now
            }
            lock.unlock()

            if silence > hangThreshold, mayReport {
                DiagnosticLogger.shared.fatal(
                    "主线程无响应 \(Int(silence)) 秒（疑似死循环或阻塞；系统可能以 watchdog 强杀）",
                    category: "crash"
                )
            }
            if maySample {
                let used = Self.footprintMB().map { "\(Int($0)) MB" } ?? "未知"
                DiagnosticLogger.shared.info(
                    "内存占用 \(used)",
                    category: "memory"
                )
            }
        }
    }

    private static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1024 / 1024
    }
}
