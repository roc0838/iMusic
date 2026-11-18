import Foundation
import OSLog
#if canImport(Darwin)
import Darwin
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Async-signal-safe crash bridge
//
// A signal handler may only call async-signal-safe functions. Everything below
// is a StaticString (already in the binary, no heap allocation) written with
// write(2). The file descriptor is opened once during normal startup.
private var imusicCrashFD: Int32 = -1

private func imusicWriteStatic(_ fd: Int32, _ text: StaticString) {
    guard fd >= 0 else { return }
    text.withUTF8Buffer { buffer in
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        _ = Darwin.write(fd, UnsafeRawPointer(base), buffer.count)
    }
}

private let imusicSignalHandler: @convention(c) (Int32) -> Void = { signalNumber in
    let fd = imusicCrashFD
    imusicWriteStatic(fd, "\n[FATAL] [crash] ======== process terminated by signal ")
    switch signalNumber {
    case SIGABRT: imusicWriteStatic(fd, "SIGABRT(6)")
    case SIGILL:  imusicWriteStatic(fd, "SIGILL(4)")
    case SIGSEGV: imusicWriteStatic(fd, "SIGSEGV(11) EXC_BAD_ACCESS")
    case SIGFPE:  imusicWriteStatic(fd, "SIGFPE(8)")
    case SIGBUS:  imusicWriteStatic(fd, "SIGBUS(10)")
    case SIGTRAP: imusicWriteStatic(fd, "SIGTRAP(5) Swift runtime trap: force-unwrap nil / out-of-range / fatalError")
    case SIGPIPE: imusicWriteStatic(fd, "SIGPIPE(13)")
    default:      imusicWriteStatic(fd, "unknown")
    }
    imusicWriteStatic(fd, " ========\n")
    // Restore the default action and re-raise so iOS still produces a real
    // .ips crash report in Settings > Privacy & Security > Analytics.
    Darwin.signal(signalNumber, SIG_DFL)
    Darwin.raise(signalNumber)
}

private let imusicExceptionHandler: @convention(c) (NSException) -> Void = { exception in
    let reason = exception.reason ?? "(no reason)"
    let stack = exception.callStackSymbols.prefix(25).joined(separator: "\n")
    DiagnosticLogger.shared.fatal(
        "NSException \(exception.name.rawValue): \(reason)\n\(stack)",
        category: "crash"
    )
}

/// Always-on diagnostics log for sideloaded builds.
///
/// The log is written **immediately** (write(2), no in-memory buffering) into
/// `Documents/iMusicDiagnostics/`. `UIFileSharingEnabled` and
/// `LSSupportsOpeningDocumentsInPlace` are already enabled, so the log can be
/// pulled with the Files app / iTunes File Sharing even when the app crashes
/// before the in-app export button can be tapped.
///
/// Credentials are redacted before anything reaches disk.
public final class DiagnosticLogger {
    public static let shared = DiagnosticLogger()

    public enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case fatal = "FATAL"
    }

    private static let osLogger = Logger(
        subsystem: "com.jiajia2222.imusic.ios",
        category: "Diagnostics"
    )

    private static let sensitivePattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?i)(token|access[_-]?token|refresh[_-]?token|cookie|authorization|password|passwd|secret|api[_-]?key|session|uin|uid|euin|csrf|qm_keyst|music_u|__csrf)([\"'\\s:=]{1,4})([A-Za-z0-9._\\-+/=]{6,})",
        options: []
    )

    private let lock = NSLock()
    private let directoryURL: URL
    private let logURL: URL
    private let markerURL: URL
    private let timestampFormatter: ISO8601DateFormatter
    private var fd: Int32 = -1
    private var didStartSession = false
    private var pendingCrashNotice = false
    private var handlersInstalled = false

    private let maxLogSize: UInt64 = 2 * 1024 * 1024
    private let maxExportSize = 2 * 1024 * 1024
    private let maxPreviewSize = 120 * 1024

    private init() {
        let fm = FileManager.default
        let base: URL = (try? fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory

        let dir = base.appendingPathComponent("iMusicDiagnostics", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        directoryURL = dir
        logURL = dir.appendingPathComponent("session.log")
        markerURL = dir.appendingPathComponent("session.marker")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestampFormatter = formatter
    }

    // MARK: - Session lifecycle

    /// Install as early as possible (first line of didFinishLaunching).
    public func startSession() {
        lock.lock()
        if didStartSession {
            lock.unlock()
            return
        }
        didStartSession = true
        lock.unlock()

        rotateIfNeeded()
        openLogFile()
        installCrashHandlers()

        let previousMarker = readMarker()
        writeMarker("running")

        info("===== SESSION START =====", category: "launch")
        info(deviceHeader(), category: "device")
        if previousMarker == "running" {
            fatal(
                "上一次会话未正常结束（疑似闪退 / 被系统终止）。上方 SESSION START 之后最后一条日志，即崩溃前最后执行到的位置。",
                category: "crash"
            )
            lock.lock()
            pendingCrashNotice = true
            lock.unlock()
        }
    }

    /// Called whenever the app becomes active.
    public func markRunning() {
        writeMarker("running")
        info("application did become active", category: "lifecycle")
    }

    /// Called when the app moves to the background; a kill from background is
    /// not treated as an in-app crash.
    public func markBackground() {
        info("application did enter background", category: "lifecycle")
        writeMarker("background")
    }

    public func markWillTerminate() {
        info("application will terminate", category: "lifecycle")
        writeMarker("clean")
    }

    /// Returns true once if the previous session ended abnormally.
    public func consumePendingCrashNotice() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pendingCrashNotice else { return false }
        pendingCrashNotice = false
        return true
    }

    // MARK: - Logging

    public func info(_ message: @autoclosure () -> String, category: String = "app") {
        log(message(), level: .info, category: category)
    }

    public func warning(_ message: @autoclosure () -> String, category: String = "app") {
        log(message(), level: .warning, category: category)
    }

    public func error(_ message: @autoclosure () -> String, category: String = "app") {
        log(message(), level: .error, category: category)
    }

    public func fatal(_ message: @autoclosure () -> String, category: String = "app") {
        log(message(), level: .fatal, category: category)
    }

    public func log(_ message: @autoclosure () -> String, level: Level, category: String) {
        let raw = message()
        let cleaned = Self.redact(raw)
        let thread = Thread.isMainThread ? "main" : (Thread.current.name ?? "bg")

        lock.lock()
        defer { lock.unlock() }
        // ISO8601DateFormatter is not thread-safe; keep every use under `lock`.
        let stamp = timestampFormatter.string(from: Date())
        let line = "\(stamp) [\(level.rawValue)] [\(category)] [\(thread)] \(cleaned)\n"
        writeLocked(line)

        switch level {
        case .info: Self.osLogger.info("\(cleaned, privacy: .private)")
        case .warning: Self.osLogger.warning("\(cleaned, privacy: .private)")
        case .error: Self.osLogger.error("\(cleaned, privacy: .private)")
        case .fatal: Self.osLogger.fault("\(cleaned, privacy: .private)")
        }
    }

    // MARK: - Export

    /// Human-readable path shown in the UI.
    public var logDirectoryDescription: String {
        "文件 App → 我的 iPhone → iMusic → iMusicDiagnostics"
    }

    /// Tail of the current log, suitable for the in-app preview.
    public func previewText() -> String {
        let text = mergedLogText()
        guard text.utf8.count > maxPreviewSize else { return text }
        return "…（前面已截断，只显示最后 \(maxPreviewSize / 1024) KB；导出文件包含完整日志）\n" + text.suffix(maxPreviewSize)
    }

    /// Builds a single shareable .txt containing device info and every log
    /// file we kept. Returns nil only if the file could not be written.
    public func exportURL() -> URL? {
        let stamp = fileStamp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iMusic-Diagnostics-\(stamp).txt")
        var text = "iMusic 诊断日志 / Diagnostic log\n"
        text += "导出时间: \(timestampFormatter.string(from: Date()))\n"
        text += deviceHeader() + "\n"
        text += "日志目录: \(logDirectoryDescription)\n"
        text += "说明: 崩溃前最后一条 [INFO]/[WARN]/[ERROR] 行即为最后执行到的操作；[FATAL] [crash] 为捕获到的信号或异常。\n\n"
        text += mergedLogText()

        guard let data = text.data(using: .utf8) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            Self.osLogger.error("Failed to write diagnostic export: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    public func clearLogs() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
            imusicCrashFD = -1
        }
        let fm = FileManager.default
        for file in allLogFiles() {
            try? fm.removeItem(at: file)
        }
        if !fm.fileExists(atPath: logURL.path) {
            _ = fm.createFile(atPath: logURL.path, contents: nil)
        }
        fd = logURL.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        imusicCrashFD = fd
        writeMarker("running")
        let stamp = timestampFormatter.string(from: Date())
        writeLocked("\(stamp) [INFO] [diagnostics] [main] 日志已清空\n")
    }

    // MARK: - Private

    private func installCrashHandlers() {
        lock.lock()
        if handlersInstalled {
            lock.unlock()
            return
        }
        handlersInstalled = true
        lock.unlock()

        NSSetUncaughtExceptionHandler(imusicExceptionHandler)
        for signalNumber in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP, SIGPIPE] {
            Darwin.signal(signalNumber, imusicSignalHandler)
        }
        info("崩溃捕获已安装 (NSException + 7 signals)", category: "diagnostics")
    }

    private func openLogFile() {
        lock.lock()
        defer { lock.unlock() }
        guard fd < 0 else { return }
        fd = logURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        }
        imusicCrashFD = fd
        if fd < 0 {
            Self.osLogger.fault("Unable to open diagnostic log file")
        }
    }

    private func writeLocked(_ line: String) {
        guard fd >= 0 else { return }
        let bytes = Array(line.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, UnsafeRawPointer(base.advanced(by: offset)), buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value > maxLogSize else { return }

        let archive = directoryURL.appendingPathComponent("session-\(fileStamp()).log")
        try? fm.moveItem(at: logURL, to: archive)

        // Keep only the three most recent archives.
        let archives = archivedLogFiles()
        if archives.count > 3 {
            for stale in archives.suffix(archives.count - 3) {
                try? fm.removeItem(at: stale)
            }
        }
    }

    private func allLogFiles() -> [URL] {
        var files = archivedLogFiles()
        if FileManager.default.fileExists(atPath: logURL.path) {
            files.append(logURL)
        }
        return files
    }

    private func archivedLogFiles() -> [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func mergedLogText() -> String {
        var result = ""
        for file in allLogFiles() {
            result += "\n===== \(file.lastPathComponent) =====\n"
            result += (try? String(contentsOf: file, encoding: .utf8)) ?? "(无法读取该日志文件)\n"
        }
        if result.utf8.count > maxExportSize {
            result = "…（较早的日志已截断）\n" + result.suffix(maxExportSize)
        }
        return result
    }

    private func readMarker() -> String? {
        guard let value = try? String(contentsOf: markerURL, encoding: .utf8) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeMarker(_ value: String) {
        try? value.write(to: markerURL, atomically: true, encoding: .utf8)
    }

    private func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func deviceHeader() -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let bundleID = bundle.bundleIdentifier ?? "?"
        let minimumOS = bundle.object(forInfoDictionaryKey: "MinimumOSVersion") as? String ?? "?"

        var parts = [
            "app=\(version)(\(build))",
            "bundle_id=\(bundleID)",
            "minimum_os=\(minimumOS)"
        ]
        #if os(iOS)
        let device = UIDevice.current
        parts.append("system=\(device.systemName) \(device.systemVersion)")
        parts.append("model=\(device.model)")
        #endif
        parts.append("embedded_mobileprovision=\(bundle.path(forResource: "embedded", ofType: "mobileprovision") == nil ? "absent" : "present")")
        if let free = freeDiskSpaceBytes() {
            parts.append("free_disk=\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))")
        }
        return parts.joined(separator: " | ")
    }

    private func freeDiskSpaceBytes() -> Int64? {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    private static func redact(_ text: String) -> String {
        var result = String(text.prefix(4000))
        guard let regex = sensitivePattern else { return result }
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(
            in: result,
            options: [],
            range: range,
            withTemplate: "$1$2<redacted>"
        )
        return result
    }
}
