import XCTest
@testable import KumoneCore

final class DiagnosticLoggerTests: XCTestCase {
    func testSessionLogIsWrittenImmediately() {
        let logger = DiagnosticLogger.shared
        logger.startSession()
        let marker = "diagnostic-unit-test-\(UUID().uuidString)"
        logger.info(marker, category: "test")

        let preview = logger.previewText()
        XCTAssertTrue(preview.contains(marker), "日志必须实时落盘，不能只留在内存缓冲里")
        XCTAssertTrue(preview.contains("===== SESSION START ====="))
    }

    func testExportRedactsCredentials() throws {
        let logger = DiagnosticLogger.shared
        logger.startSession()
        let secret = "ghp_UNITTESTSECRET0123456789"
        logger.info("cookie=MUSIC_U_UNITTESTSECRET012345 token=\(secret)", category: "test")

        let url = try XCTUnwrap(logger.exportURL())
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains(secret), "导出日志不得包含明文凭据")
        XCTAssertTrue(text.contains("<redacted>"))
        XCTAssertTrue(text.contains("bundle_id="), "导出文件应包含设备与构建信息")
    }

    func testCrashNoticeIsConsumedOnlyOnce() {
        // Whether a previous abnormal exit was detected depends on device
        // state; only the one-shot semantics are part of the contract.
        _ = DiagnosticLogger.shared.consumePendingCrashNotice()
        XCTAssertFalse(DiagnosticLogger.shared.consumePendingCrashNotice())
    }
}
