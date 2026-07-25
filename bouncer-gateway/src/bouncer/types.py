from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Literal


Severity = Literal["low", "medium", "high", "critical"]
Decision = Literal["allow", "allow_masked", "review", "block"]


@dataclass(frozen=True)
class Finding:
    code: str
    category: str
    severity: Severity
    summary: str
    fingerprint: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class AiAssessment:
    available: bool
    decision: Literal["allow", "review", "block"] = "allow"
    risk_score: float = 0.0
    categories: list[str] = field(default_factory=list)
    reasons: list[str] = field(default_factory=list)
    error: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class InspectionResult:
    status: Literal["success", "warning", "error"]
    summary: str
    next_actions: list[str]
    artifacts: list[str]
    decision: Decision
    risk_score: float
    findings: list[Finding]
    masked_text: str
    masked_count: int
    ai: AiAssessment

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "summary": self.summary,
            "next_actions": self.next_actions,
            "artifacts": self.artifacts,
            "decision": self.decision,
            "risk_score": round(self.risk_score, 3),
            "findings": [item.to_dict() for item in self.findings],
            "masked_text": self.masked_text,
            "masked_count": self.masked_count,
            "ai": self.ai.to_dict(),
        }
