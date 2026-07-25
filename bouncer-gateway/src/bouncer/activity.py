from __future__ import annotations

import threading
import time
from collections import Counter, deque
from dataclasses import dataclass
from typing import Any


_DECISIONS = {"allow", "allow_masked", "review", "block", "error"}


@dataclass
class _ActiveRequest:
    request_id: int
    kind: str
    stage: str
    started_at: float
    started_monotonic: float


class ActivityHandle:
    def __init__(self, monitor: "ActivityMonitor", request_id: int) -> None:
        self._monitor = monitor
        self._request_id = request_id
        self._completed = False

    def __enter__(self) -> "ActivityHandle":
        return self

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> bool:
        if not self._completed:
            summary = (
                "処理中にエラーが発生しました"
                if exc_type is not None
                else "処理は完了しませんでした"
            )
            self.complete("error", summary)
        return False

    def stage(self, value: str) -> None:
        if not self._completed:
            self._monitor._set_stage(self._request_id, value)

    def complete(
        self,
        decision: str,
        summary: str,
        *,
        masked_count: int = 0,
        finding_codes: list[str] | None = None,
        upstream_status: int | None = None,
    ) -> None:
        if self._completed:
            return
        self._completed = True
        self._monitor._finish(
            self._request_id,
            decision,
            summary,
            masked_count=masked_count,
            finding_codes=finding_codes or [],
            upstream_status=upstream_status,
        )


class ActivityMonitor:
    """In-memory, content-free activity for the local status dashboard."""

    def __init__(self, recent_limit: int = 24) -> None:
        self.started_at = time.time()
        self._lock = threading.Lock()
        self._next_id = 0
        self._active: dict[int, _ActiveRequest] = {}
        self._recent: deque[dict[str, Any]] = deque(maxlen=recent_limit)
        self._totals: Counter[str] = Counter()

    def track(self, kind: str, stage: str) -> ActivityHandle:
        with self._lock:
            self._next_id += 1
            request_id = self._next_id
            self._active[request_id] = _ActiveRequest(
                request_id=request_id,
                kind=kind,
                stage=stage,
                started_at=time.time(),
                started_monotonic=time.monotonic(),
            )
        return ActivityHandle(self, request_id)

    def _set_stage(self, request_id: int, stage: str) -> None:
        with self._lock:
            active = self._active.get(request_id)
            if active is not None:
                active.stage = stage

    def _finish(
        self,
        request_id: int,
        decision: str,
        summary: str,
        *,
        masked_count: int,
        finding_codes: list[str],
        upstream_status: int | None,
    ) -> None:
        normalized_decision = decision if decision in _DECISIONS else "error"
        finished_at = time.time()
        with self._lock:
            active = self._active.pop(request_id, None)
            if active is None:
                return
            elapsed_ms = round((time.monotonic() - active.started_monotonic) * 1000)
            self._totals["total"] += 1
            self._totals[normalized_decision] += 1
            self._totals["masked"] += max(0, masked_count)
            self._recent.appendleft(
                {
                    "id": request_id,
                    "kind": active.kind,
                    "decision": normalized_decision,
                    "summary": summary,
                    "finished_at": finished_at,
                    "elapsed_ms": elapsed_ms,
                    "masked_count": max(0, masked_count),
                    "finding_codes": list(finding_codes[:12]),
                    "upstream_status": upstream_status,
                }
            )

    def snapshot(self) -> dict[str, Any]:
        now_epoch = time.time()
        now_monotonic = time.monotonic()
        with self._lock:
            active = [
                {
                    "id": item.request_id,
                    "kind": item.kind,
                    "stage": item.stage,
                    "started_at": item.started_at,
                    "elapsed_ms": round(
                        (now_monotonic - item.started_monotonic) * 1000
                    ),
                }
                for item in sorted(
                    self._active.values(), key=lambda value: value.started_at
                )
            ]
            totals = {
                key: int(self._totals.get(key, 0))
                for key in (
                    "total",
                    "allow",
                    "allow_masked",
                    "review",
                    "block",
                    "error",
                    "masked",
                )
            }
            recent = [dict(item) for item in self._recent]
        return {
            "started_at": self.started_at,
            "uptime_seconds": max(0, round(now_epoch - self.started_at)),
            "active_requests": len(active),
            "active": active,
            "totals": totals,
            "recent": recent,
        }
