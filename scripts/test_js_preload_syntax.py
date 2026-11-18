#!/usr/bin/env python3
"""Guards the JavaScript preloads that ship inside the iOS app.

`node --check` is not a sufficient gate for this code: V8 accepts an
assignment to a call expression such as ``item.$(id) = value`` at parse time
and only fails when the line executes, while JavaScriptCore rejects it during
parsing whenever the surrounding code is strict. A single such line made the
whole MusicFree preload fail to parse on device, so the app reported every
plugin as "loaded" while nothing had been installed.

These checks run in CI without a JavaScriptCore host, so they look for the
constructs that strict-mode parsers reject outright.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

SOURCES = Path(__file__).resolve().parents[1] / "platforms" / "ios" / "Sources" / "Kumone"
PRELOADS = ["LXUserAPIPreload.js", "MusicFreePreload.js"]

CONTROL_KEYWORDS = re.compile(
    r"\b(if|for|while|switch|catch|function|return|typeof|delete|void|new|await|in|of)$"
)


def find_call_assignments(source: str) -> list[tuple[int, str]]:
    """Returns lines that assign to a function-call result."""
    hits: list[tuple[int, str]] = []
    for number, line in enumerate(source.split("\n"), 1):
        stripped = line.lstrip()
        if stripped.startswith(("//", "*", "/*")):
            continue
        for match in re.finditer(r"=", line):
            index = match.start()
            # Skip comparisons and arrow bodies.
            if index + 1 < len(line) and line[index + 1] in "=>":
                continue
            if index > 0 and line[index - 1] in "=!<>+-*/%&|^":
                continue
            left = line[:index].rstrip()
            if not left.endswith(")"):
                continue
            depth = 0
            cursor = len(left) - 1
            while cursor >= 0:
                if left[cursor] == ")":
                    depth += 1
                elif left[cursor] == "(":
                    depth -= 1
                    if depth == 0:
                        break
                cursor -= 1
            if cursor <= 0:
                continue
            callee = left[:cursor].rstrip()
            if not callee or CONTROL_KEYWORDS.search(callee):
                continue
            hits.append((number, line.strip()))
            break
    return hits


class PreloadSyntaxTests(unittest.TestCase):
    def test_preloads_avoid_assignment_to_call_expressions(self):
        for name in PRELOADS:
            source = (SOURCES / name).read_text(encoding="utf-8")
            hits = find_call_assignments(source)
            self.assertEqual(
                hits,
                [],
                f"{name} assigns to a call result at {hits}; JavaScriptCore "
                "rejects this while parsing under strict mode",
            )

    def test_musicfree_item_does_not_use_dollar_as_a_function(self):
        source = (SOURCES / "MusicFreePreload.js").read_text(encoding="utf-8")
        self.assertNotIn("item.$(", source)
        self.assertIn("item.platform", source)

    def test_preloads_do_not_delete_bare_identifiers(self):
        # `delete name` is a strict-mode SyntaxError in JavaScriptCore.
        for name in PRELOADS:
            source = (SOURCES / name).read_text(encoding="utf-8")
            bare_delete = re.search(r"\bdelete\s+[A-Za-z_$][\w$]*\s*(?:;|,|$)", source, re.M)
            self.assertIsNone(bare_delete, f"{name} deletes a bare identifier")

    def test_preloads_do_not_use_octal_escapes(self):
        for name in PRELOADS:
            source = (SOURCES / name).read_text(encoding="utf-8")
            self.assertIsNone(
                re.search(r"\\[0-7]{1,3}(?![0-9])", source.replace("\\\\", "")),
                f"{name} contains an octal escape, which strict mode rejects",
            )

    def test_load_logs_capabilities_only_after_the_plugin_reports_them(self):
        service = (SOURCES / "Core" / "API" / "LXUserAPIService.swift").read_text(encoding="utf-8")
        self.assertNotIn("MusicFree 插件加载完成", service)
        self.assertIn("MusicFree 插件脚本已求值，等待上报接口", service)
        self.assertIn("就绪: ", service)


if __name__ == "__main__":
    unittest.main()
