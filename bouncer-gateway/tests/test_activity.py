import unittest

from bouncer.activity import ActivityMonitor


class ActivityMonitorTests(unittest.TestCase):
    def test_tracks_stage_and_content_free_result(self) -> None:
        monitor = ActivityMonitor()

        with monitor.track("gateway", "準備中") as activity:
            activity.stage("応答を検査中")
            active = monitor.snapshot()
            self.assertEqual(active["active_requests"], 1)
            self.assertEqual(active["active"][0]["stage"], "応答を検査中")
            activity.complete(
                "allow_masked",
                "機密候補を1件マスクして通過可能です",
                masked_count=1,
                finding_codes=["anthropic_key"],
            )

        finished = monitor.snapshot()
        self.assertEqual(finished["active_requests"], 0)
        self.assertEqual(finished["totals"]["total"], 1)
        self.assertEqual(finished["totals"]["allow_masked"], 1)
        self.assertEqual(finished["totals"]["masked"], 1)
        self.assertEqual(finished["recent"][0]["finding_codes"], ["anthropic_key"])

    def test_unfinished_activity_becomes_error(self) -> None:
        monitor = ActivityMonitor()

        with monitor.track("inspect", "検査中"):
            pass

        snapshot = monitor.snapshot()
        self.assertEqual(snapshot["totals"]["error"], 1)
        self.assertEqual(snapshot["active_requests"], 0)


if __name__ == "__main__":
    unittest.main()
