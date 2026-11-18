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


if __name__ == "__main__":
    unittest.main()
