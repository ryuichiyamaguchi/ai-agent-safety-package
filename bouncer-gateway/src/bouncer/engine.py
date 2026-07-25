from __future__ import annotations

from typing import Any

from .local_ai import LocalAiClient
from .masking import MaskingSession
from .rules import evaluate_rules
from .types import AiAssessment, Finding, InspectionResult


SEVERITY_SCORE = {
    "low": 0.15,
    "medium": 0.35,
    "high": 0.7,
    "critical": 1.0,
}


class BouncerEngine:
    def __init__(self, ai_client: LocalAiClient, fail_closed: bool = True) -> None:
        self.ai_client = ai_client
        self.fail_closed = fail_closed

    def inspect(
        self,
        direction: str,
        text: str,
        context: Any | None = None,
    ) -> tuple[InspectionResult, MaskingSession]:
        if direction not in {"outbound", "inbound"}:
            raise ValueError("direction must be outbound or inbound")
        session = MaskingSession()
        masked_text = session.mask_text(text)
        masked_context = session.mask_value(context)
        result = self.inspect_prepared(
            direction=direction,
            masked_text=masked_text,
            mask_findings=list(session.findings),
            masked_count=session.masked_count,
            context=masked_context,
        )
        return result, session

    def inspect_prepared(
        self,
        direction: str,
        masked_text: str,
        mask_findings: list[Finding],
        masked_count: int,
        context: Any | None = None,
        use_ai: bool = True,
    ) -> InspectionResult:
        rule_findings = evaluate_rules(direction, masked_text)
        findings = mask_findings + rule_findings
        ai = (
            self.ai_client.assess(direction, masked_text, context)
            if use_ai
            else AiAssessment(
                available=False,
                categories=["balanced_rules_only"],
                reasons=["semantic outbound scan was not needed"],
            )
        )
        return self._decide(
            direction,
            masked_text,
            masked_count,
            findings,
            ai,
            ai_required=use_ai,
        )

    def _decide(
        self,
        direction: str,
        masked_text: str,
        masked_count: int,
        findings: list[Finding],
        ai: AiAssessment,
        ai_required: bool,
    ) -> InspectionResult:
        max_rule_score = max(
            (SEVERITY_SCORE[item.severity] for item in findings), default=0.0
        )
        risk_score = max(max_rule_score, ai.risk_score if ai.available else 0.0)

        action_findings = [
            item
            for item in findings
            if item.category not in {"credential", "personal_data", "local_path"}
        ]
        critical_action = any(item.severity == "critical" for item in action_findings)
        high_action = any(item.severity == "high" for item in action_findings)

        if critical_action:
            decision = "block"
        elif ai_required and not ai.available and self.fail_closed:
            decision = "review"
        elif ai.available and ai.decision == "block" and ai.risk_score >= 0.7:
            decision = "block"
        elif ai.available and ai.decision == "block":
            decision = "review"
        elif high_action:
            decision = "review"
        elif ai.available and ai.decision == "review":
            decision = "review"
        elif direction == "outbound" and masked_count:
            decision = "allow_masked"
        else:
            decision = "allow"

        if decision == "block":
            summary = "危険度の高い挙動を検出したため遮断しました"
            next_actions = ["検出理由と直前の依頼を人が確認してください"]
        elif decision == "review":
            summary = "自動通過させず、人の確認が必要です"
            next_actions = ["内容を確認してから再実行または明示的に許可してください"]
        elif decision == "allow_masked":
            summary = f"機密候補を{masked_count}件マスクして通過可能です"
            next_actions = []
        else:
            summary = "通過可能です"
            next_actions = []

        status = "success" if ai.available or not ai_required else "warning"
        if ai_required and not ai.available:
            summary += "（ローカルAI判定は利用できず、ルール判定のみ）"
            next_actions.append("LM StudioとGemmaの起動状態を確認してください")

        return InspectionResult(
            status=status,
            summary=summary,
            next_actions=next_actions,
            artifacts=[],
            decision=decision,  # type: ignore[arg-type]
            risk_score=risk_score,
            findings=findings,
            masked_text=masked_text,
            masked_count=masked_count,
            ai=ai,
        )
