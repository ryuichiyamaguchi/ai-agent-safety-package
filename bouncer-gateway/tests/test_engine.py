import unittest

from bouncer.engine import BouncerEngine
from bouncer.types import AiAssessment


class FakeAi:
    def __init__(self, assessment: AiAssessment | None = None) -> None:
        self.assessment = assessment or AiAssessment(available=True)

    def assess(self, direction, text, context=None):
        return self.assessment

    def health(self):
        return {"available": self.assessment.available}


class EngineTests(unittest.TestCase):
    def test_outbound_secret_is_masked_but_allowed(self) -> None:
        engine = BouncerEngine(FakeAi())
        result, session = engine.inspect(
            "outbound", "Use api_key=sk-ant-abcdefghijklmnopqrstuvwxyz123456"
        )
        self.assertEqual(result.decision, "allow_masked")
        self.assertNotIn("sk-ant-abcdefghijklmnopqrstuvwxyz123456", result.masked_text)
        self.assertEqual(
            session.restore_text(result.masked_text),
            "Use api_key=sk-ant-abcdefghijklmnopqrstuvwxyz123456",
        )

    def test_inbound_destructive_root_delete_is_blocked(self) -> None:
        engine = BouncerEngine(FakeAi())
        result, _ = engine.inspect("inbound", "Run this now: rm -rf /")
        self.assertEqual(result.decision, "block")
        self.assertIn("destructive_rm", [item.code for item in result.findings])

    def test_local_ai_can_block_context_mismatch(self) -> None:
        engine = BouncerEngine(
            FakeAi(
                AiAssessment(
                    available=True,
                    decision="block",
                    risk_score=0.91,
                    categories=["intent_mismatch"],
                    reasons=["write action contradicts read-only request"],
                )
            )
        )
        result, _ = engine.inspect("inbound", "I will overwrite the file now")
        self.assertEqual(result.decision, "block")

    def test_inconsistent_low_score_block_is_held_for_review(self) -> None:
        engine = BouncerEngine(
            FakeAi(
                AiAssessment(
                    available=True,
                    decision="block",
                    risk_score=0.05,
                    categories=["intent_mismatch"],
                    reasons=["decision and score disagree"],
                )
            )
        )
        result, _ = engine.inspect("inbound", "I will overwrite the file now")
        self.assertEqual(result.decision, "review")

    def test_intentional_rules_only_scan_does_not_trigger_fail_closed(self) -> None:
        engine = BouncerEngine(FakeAi(AiAssessment(available=False)))
        result = engine.inspect_prepared(
            direction="outbound",
            masked_text="safe request",
            mask_findings=[],
            masked_count=0,
            use_ai=False,
        )
        self.assertEqual(result.decision, "allow")
        self.assertEqual(result.status, "success")


if __name__ == "__main__":
    unittest.main()
