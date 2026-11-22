"""Static guards for the sideload crash-diagnostics build.

These checks are portable (no macOS required) and protect the exact failure
modes that made the previous self-signed IPA crash on iOS 27.0.1.
"""
import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS_SHELL = ROOT / "platforms" / "ios" / "ios"
CONFIG = IOS_SHELL / "Config"
WORKFLOW = ROOT / ".github" / "workflows" / "ios-diagnostics.yml"
SOURCES = ROOT / "platforms" / "ios" / "Sources" / "Kumone"


class DiagnosticsBuildTests(unittest.TestCase):
    def test_info_plist_keeps_background_task_declaration(self):
        with (CONFIG / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        permitted = info.get("BGTaskSchedulerPermittedIdentifiers", [])
        self.assertIn("com.jiajia2222.imusic.provider-refresh", permitted)
        modes = info.get("UIBackgroundModes", [])
        self.assertIn("fetch", modes)
        self.assertIn("audio", modes)
        self.assertTrue(info.get("UIFileSharingEnabled"),
                        "日志必须能通过「文件」App 取出")

    def test_entitlements_contain_no_restricted_capability(self):
        with (CONFIG / "KumoneIOS.entitlements").open("rb") as handle:
            entitlements = plistlib.load(handle)
        self.assertEqual(entitlements, {},
                         "自签 IPA 不能声明个人证书拿不到的 entitlement")

    def test_deployment_target_matches_hosted_sdk(self):
        text = (CONFIG / "Shared.xcconfig").read_text(encoding="utf-8")
        match = re.search(r"^IPHONEOS_DEPLOYMENT_TARGET\s*=\s*(\S+)", text, re.M)
        self.assertIsNotNone(match)
        major = int(match.group(1).split(".")[0])
        self.assertLessEqual(major, 26,
                             "GitHub 托管 macOS runner 只提供 iOS 26 SDK")

    def test_workflow_uses_hosted_runner(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("runs-on: macos-26", text)
        self.assertNotIn("runs-on: xcode-27", text)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", text)

    def test_user_script_is_not_evaluated_during_launch(self):
        text = (SOURCES / "Features" / "IOSStartup.swift").read_text(encoding="utf-8")
        self.assertNotIn("await LXUserAPIService.shared.ensureSelectedSourceLoaded()", text)

    def test_source_loader_does_not_force_unwrap_bundle_module(self):
        text = (SOURCES / "Core" / "API" / "LXUserAPIService.swift").read_text(encoding="utf-8")
        self.assertNotIn('Bundle.module.url(forResource: "LXUserAPIPreload"', text)
        self.assertNotIn("installHostFunctions(in: js!)", text)

    def test_lx_bridge_never_serializes_a_scalar_top_level_value(self):
        """Regression for the SIGABRT captured in the device log.

        `__set_timeout__` passes an Int as the top-level JSON value.
        NSJSONSerialization raises an *NSException* (not a Swift error) for
        that, which `try?` cannot catch, so the process aborts. The safe
        encoder validates first and emits the integer as a JSON fragment.
        """
        service = (SOURCES / "Core" / "API" / "LXUserAPIService.swift").read_text(encoding="utf-8")
        self.assertIn("SafeJSON.encodedString(data)", service)
        self.assertNotIn("try? JSONSerialization.data(withJSONObject: data)", service)
        self.assertNotIn("encoded!", service)
        self.assertIn('callJS(action: "__set_timeout__", data: id)', service)

        encoder = (SOURCES / "Core" / "API" / "SafeJSONEncoding.swift").read_text(encoding="utf-8")
        self.assertIn("JSONSerialization.isValidJSONObject(normalized)", encoder)
        self.assertIn(".fragmentsAllowed", encoder)
        self.assertIn("mirror.displayStyle == .optional", encoder)

    def test_other_lx_json_writes_use_the_safe_encoder(self):
        for relative in ("Core/API/LXCommentsService.swift", "Core/Sync/LXSyncClient.swift"):
            with self.subTest(file=relative):
                text = (SOURCES / relative).read_text(encoding="utf-8")
                self.assertNotIn("try? JSONSerialization.data(withJSONObject:", text)
                self.assertIn("SafeJSON.encodedData(", text)

    def test_version_is_newer_than_the_crashing_diagnostics_build(self):
        text = (CONFIG / "Shared.xcconfig").read_text(encoding="utf-8")
        match = re.search(r"^MARKETING_VERSION\s*=\s*(\S+)", text, re.M)
        self.assertIsNotNone(match)
        parts = tuple(int(part) for part in match.group(1).split("."))
        self.assertGreater(parts, (2, 0, 0),
                           "修复版必须比闪退的 2.0 更晚，便于真机确认版本")
        build = re.search(r"^CURRENT_PROJECT_VERSION\s*=\s*(\d+)", text, re.M)
        self.assertIsNotNone(build)
        self.assertGreaterEqual(int(build.group(1)), 203)

    def test_musicfree_preload_is_packaged_and_verified(self):
        preload = SOURCES / "MusicFreePreload.js"
        self.assertTrue(preload.exists(), "MusicFree 插件运行时缺失")
        text = preload.read_text(encoding="utf-8")
        self.assertIn("globalThis.mf_setup", text)
        self.assertIn("globalThis.__lx_native__", text)
        self.assertIn("getMediaSource", text)
        self.assertIn("getLyric", text)
        package = (ROOT / "platforms" / "ios" / "Package.swift").read_text(encoding="utf-8")
        self.assertIn('.copy("MusicFreePreload.js")', package)
        self.assertIn("MusicFreePreload.js", WORKFLOW.read_text(encoding="utf-8"))

    def test_lx_sandbox_is_not_contaminated_by_plugin_runtime(self):
        """MusicFree needs eval/CommonJS; LX must keep its frozen sandbox."""
        lx = (SOURCES / "LXUserAPIPreload.js").read_text(encoding="utf-8")
        mf = (SOURCES / "MusicFreePreload.js").read_text(encoding="utf-8")
        self.assertNotIn("mf_setup", lx)
        self.assertNotIn("Object.freeze(globalThis)", mf)
        service = (SOURCES / "Core" / "API" / "LXUserAPIService.swift").read_text(encoding="utf-8")
        self.assertIn('isPlugin ? "MusicFreePreload" : "LXUserAPIPreload"', service)
        self.assertIn('isPlugin ? "mf_setup" : "lx_setup"', service)

    def test_plugin_search_uses_an_isolated_resolver(self):
        service = (SOURCES / "Core" / "API" / "LXUserAPIService.swift").read_text(encoding="utf-8")
        self.assertIn("pluginSearchResolver", service)
        catalog = (SOURCES / "Core" / "API" / "LXCatalogService.swift").read_text(encoding="utf-8")
        self.assertIn("musicFreeSearch(", catalog)
        self.assertIn("keyword: keyword, page: page, limit: limit", catalog)
        self.assertIn("group.addTask", catalog)

    def test_log_export_remains_available(self):
        diagnostics = (SOURCES / "Core" / "Diagnostics" / "DiagnosticsView.swift").read_text(encoding="utf-8")
        self.assertIn("ShareLink(item: shareURL)", diagnostics)
        self.assertIn("iMusicDiagnostics", diagnostics)

    def test_crash_marker_follows_scene_phase(self):
        """Scene-based apps never receive applicationDidBecomeActive /
        applicationDidEnterBackground on the app delegate. If the marker is
        only written there it stays "running" until the process dies, so every
        background kill is misreported as a crash on the next launch — which is
        exactly the "上次运行异常退出 appears on every open" bug."""
        main_window = (SOURCES / "Features" / "IOSMainWindow.swift").read_text(encoding="utf-8")
        self.assertIn("DiagnosticLogger.shared.markRunning()", main_window,
                      "scenePhase .active 必须把标记写回 running")
        self.assertIn("DiagnosticLogger.shared.markBackground()", main_window,
                      "scenePhase .background 必须把标记写成 background")
        tracker = (SOURCES / "Core" / "Diagnostics" / "AppLifecycleTracker.swift")
        self.assertTrue(tracker.exists(),
                        "后台挂起会撑爆墙钟超时，需要生命周期跟踪器")

    def test_suspended_probe_is_retried_not_failed(self):
        """A probe interrupted by an iOS suspension must not count as a slow
        failure: the process was frozen, so the provider never answered."""
        service = (SOURCES / "Core" / "API" / "LXUserAPIService.swift").read_text(encoding="utf-8")
        self.assertIn("suspensionOverlap(since: attemptStartedAt)", service)
        self.assertIn("isSuspendRetry: true", service,
                      "挂起打断的探测必须原地重试一次")
        self.assertIn("rebaseAfterSuspension(&startedAt)", service,
                      "恢复前台后寻源预算必须重新起算")

    def test_aggregate_search_is_time_bounded(self):
        """Aggregate search used to await every imported plugin in sequence
        (74 s with ~66 plugins), so the page looked empty. It must stay within
        a budget and each plugin request must have its own short timeout."""
        service = (SOURCES / "Core" / "API" / "LXUserAPIService.swift").read_text(encoding="utf-8")
        self.assertIn("budget: TimeInterval = 6", service)
        self.assertIn("插件搜索预算用尽", service)
        self.assertIn("timeout: max(1.5, min(4, remaining))", service,
                      "单个插件的搜索超时必须远小于 20 秒")
        self.assertIn("func requestPlugin(method: String, args: [Any],", service)
        self.assertIn("timeout: TimeInterval = 20", service,
                      "播放等其它插件调用仍保留默认 20 秒")
        catalog = (SOURCES / "Core" / "API" / "LXCatalogService.swift").read_text(encoding="utf-8")
        self.assertIn("musicFreeSearch(", catalog)

    def test_lyric_lookup_is_capped(self):
        """Walking all imported sources for lyrics burned the full 15 s budget
        on tracks that simply have no lyrics."""
        service = (SOURCES / "Core" / "API" / "LXUserAPIService.swift").read_text(encoding="utf-8")
        self.assertIn("lyricSourceLimit = 12", service)
        self.assertIn("lyricCandidateSources(playbackSources)", service)
        self.assertIn("…等 \\(missed.count) 条", service,
                      "失败明细必须截断，几十个音源时会写出几千字")

    def test_watchdog_covers_foreground_hangs(self):
        """A watchdog kill (0x8badf00d) writes nothing on its own; the monitor
        must report it and stay quiet while the app is backgrounded."""
        watchdog = (SOURCES / "Core" / "Diagnostics" / "MainThreadWatchdog.swift").read_text(encoding="utf-8")
        self.assertIn("主线程无响应", watchdog)
        self.assertIn("AppLifecycleTracker.shared.isForeground", watchdog)
        logger = (SOURCES / "Core" / "Diagnostics" / "DiagnosticLogger.swift").read_text(encoding="utf-8")
        self.assertIn("MainThreadWatchdog.shared.start()", logger)
        self.assertIn("previousLastLogLine", logger)

    def test_workflow_stamps_the_configured_build_number(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("CURRENT_PROJECT_VERSION: ${{ steps.version.outputs.build }}", text)
        self.assertIn("iMusic-iOS-diagnostics-${RELEASE_VERSION}-${BUILD_NUMBER}.ipa", text)


if __name__ == "__main__":
    unittest.main()
