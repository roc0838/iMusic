"""Guards for the next-track prefetch contract.

Prefetching is only safe because it warms exactly one track and always yields
to a real request. Both properties are easy to break by accident — a wider
lookahead reads like an obvious improvement, and it silently competes for the
single resolver lock — so they are pinned down here.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KUMONE = ROOT / "platforms" / "ios" / "Sources" / "Kumone"
PLAYER = KUMONE / "Core" / "Player" / "PlayerService.swift"
USER_API = KUMONE / "Core" / "API" / "LXUserAPIService.swift"


class PrefetchContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.player = PLAYER.read_text(encoding="utf-8")
        self.user_api = USER_API.read_text(encoding="utf-8")

    def test_prefetch_targets_only_the_next_queue_entry(self) -> None:
        self.assertIn(
            "guard let next = upcomingTracks.first else { return }",
            self.player,
            "prefetch must warm exactly the next queue entry",
        )

    def test_prefetch_never_widens_the_lookahead(self) -> None:
        # Any prefix/dropFirst/suffix on the queue inside the prefetch path would
        # warm more than one track, spending requests and lock time on songs
        # that are usually skipped.
        for pattern in (
            r"upcomingTracks\.prefix\(",
            r"upcomingTracks\.dropFirst\(",
            r"upcomingTracks\[.*\.\.\.",
        ):
            self.assertIsNone(
                re.search(pattern, self.player),
                f"prefetch must not widen lookahead: {pattern}",
            )

    def test_foreground_request_cancels_the_prefetch(self) -> None:
        self.assertIn("if !isPrefetch {", self.user_api)
        start = self.user_api.index("if !isPrefetch {")
        block = self.user_api[start : start + 400]
        self.assertIn(
            "cancelPrefetch()",
            block,
            "a real request must drop the prefetch before taking the lock",
        )

    def test_track_change_cancels_the_prefetch(self) -> None:
        self.assertIn("LXUserAPIService.shared.cancelPrefetch()", self.player)

    def test_cached_links_expire(self) -> None:
        match = re.search(
            r"resolutionCacheTTL: TimeInterval = (\d+) \* 60", self.user_api
        )
        self.assertIsNotNone(match, "cache needs a TTL")
        minutes = int(match.group(1))
        self.assertLessEqual(minutes, 30, "a provider link can expire; keep the TTL short")

    def test_expired_cache_reshapes_the_url_once(self) -> None:
        self.assertIn("cacheMissRetries < 1", self.player)
        self.assertIn("invalidateCachedResolution", self.player)
        self.assertIn("currentResolutionFromCache", self.player)

    def test_cache_is_dropped_when_the_source_configuration_changes(self) -> None:
        block = self.user_api[self.user_api.index("func invalidateSourceWork") :][:1200]
        self.assertIn("resolutionCache.removeAll()", block)
        self.assertIn("cancelPrefetch()", block)


if __name__ == "__main__":
    unittest.main()
