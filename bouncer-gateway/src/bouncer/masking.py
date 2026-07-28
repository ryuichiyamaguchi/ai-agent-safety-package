from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from typing import Any

from .types import Finding, Severity


@dataclass(frozen=True)
class PatternSpec:
    code: str
    category: str
    severity: Severity
    summary: str
    regex: re.Pattern[str]
    secret_group: int = 0
    # `SECRET_KEY = get_random_secret_key()` assigns a call, not a secret.
    skip_call_values: bool = False


# `\b` does not separate words at an underscore, so AWS_SECRET_ACCESS_KEY and
# MYSERVICE_API_KEY never reached the secret words. Instead of a word boundary,
# match the whole identifier: optional leading segments, the secret word, and
# optional trailing segments. A bare `key` or `token` needs a leading segment so
# that ordinary prose like `key: value` is left alone.
_SECRET_NAME = (
    r"(?<![A-Za-z0-9])(?:"
    r"(?:[A-Za-z0-9]+[_-])*"
    r"(?:password|passwd|pwd|secret|api[_-]?key|access[_-]?token|"
    r"auth[_-]?token|private[_-]?key|client[_-]?secret)"
    r"(?:[_-][A-Za-z0-9]+)*"
    r"|"
    r"(?:[A-Za-z0-9]+[_-])+(?:key|token)(?:[_-][A-Za-z0-9]+)*"
    r")"
)


PATTERNS: tuple[PatternSpec, ...] = (
    PatternSpec(
        "private_key",
        "credential",
        "critical",
        "秘密鍵をマスクしました",
        re.compile(
            r"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----.*?"
            r"-----END (?:[A-Z0-9 ]+ )?PRIVATE KEY-----",
            re.DOTALL,
        ),
    ),
    PatternSpec(
        "anthropic_key",
        "credential",
        "critical",
        "Anthropic APIキーらしき値をマスクしました",
        re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}\b"),
    ),
    PatternSpec(
        "openai_key",
        "credential",
        "critical",
        "OpenAI APIキーらしき値をマスクしました",
        re.compile(r"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}\b"),
    ),
    PatternSpec(
        "github_token",
        "credential",
        "critical",
        "GitHubトークンらしき値をマスクしました",
        re.compile(r"\bgh(?:p|o|u|s|r)_[A-Za-z0-9]{20,}\b"),
    ),
    PatternSpec(
        "aws_access_key",
        "credential",
        "critical",
        "AWSアクセスキーらしき値をマスクしました",
        re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    ),
    PatternSpec(
        "google_api_key",
        "credential",
        "critical",
        "Google APIキーらしき値をマスクしました",
        re.compile(r"\bAIza[A-Za-z0-9_-]{30,}\b"),
    ),
    PatternSpec(
        "slack_token",
        "credential",
        "critical",
        "Slackトークンらしき値をマスクしました",
        re.compile(r"\bxox(?:a|b|p|r|s)-[A-Za-z0-9-]{10,}\b"),
    ),
    PatternSpec(
        "jwt",
        "credential",
        "high",
        "JWTらしき値をマスクしました",
        re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"),
    ),
    PatternSpec(
        "bearer_token",
        "credential",
        "critical",
        "Bearerトークンらしき値をマスクしました",
        re.compile(r"(?i)\bBearer\s+([A-Za-z0-9._~+/=-]{20,})"),
        1,
    ),
    PatternSpec(
        "secret_assignment",
        "credential",
        "high",
        "秘密値の代入らしき箇所をマスクしました",
        # The closing quote of a JSON key sits between the name and the colon.
        re.compile(
            r"(?i)" + _SECRET_NAME + r"[\"']?\s*[:=]\s*[\"']?([^\s\"',;}{]{6,})"
        ),
        1,
        skip_call_values=True,
    ),
    PatternSpec(
        "mac_home_user",
        "local_path",
        "medium",
        "macOSホームディレクトリ名をマスクしました",
        re.compile(r"/Users/([^/\s\"'<>]+)"),
        1,
    ),
    PatternSpec(
        "windows_home_user",
        "local_path",
        "medium",
        "Windowsユーザーディレクトリ名をマスクしました",
        re.compile(r"(?i)[A-Z]:\\Users\\([^\\\s\"'<>]+)"),
        1,
    ),
    PatternSpec(
        "email",
        "personal_data",
        "medium",
        "メールアドレスをマスクしました",
        re.compile(r"\b[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\b"),
    ),
    PatternSpec(
        "japanese_phone",
        "personal_data",
        "medium",
        "電話番号らしき値をマスクしました",
        re.compile(r"(?<!\d)(?:\+81[- ]?|0)\d{1,4}[- ]?\d{1,4}[- ]?\d{3,4}(?!\d)"),
    ),
)


class MaskingSession:
    """Request-scoped reversible mapping. The original values are never persisted."""

    def __init__(self) -> None:
        self._token_to_original: dict[str, str] = {}
        self._original_to_token: dict[str, str] = {}
        self._counter = 0
        self.findings: list[Finding] = []
        self._finding_keys: set[tuple[str, str]] = set()

    @property
    def masked_count(self) -> int:
        return len(self._token_to_original)

    def _token_for(self, category: str, original: str) -> str:
        existing = self._original_to_token.get(original)
        if existing is not None:
            return existing
        self._counter += 1
        label = re.sub(r"[^A-Z0-9]+", "_", category.upper()).strip("_")
        token = f"⟪BNC_{label}_{self._counter:04d}⟫"
        self._original_to_token[original] = token
        self._token_to_original[token] = original
        return token

    def _record(self, spec: PatternSpec, original: str) -> None:
        fingerprint = hashlib.sha256(original.encode("utf-8")).hexdigest()[:12]
        key = (spec.code, fingerprint)
        if key in self._finding_keys:
            return
        self._finding_keys.add(key)
        self.findings.append(
            Finding(
                code=spec.code,
                category=spec.category,
                severity=spec.severity,
                summary=spec.summary,
                fingerprint=fingerprint,
            )
        )

    def mask_text(self, text: str) -> str:
        masked = text
        for spec in PATTERNS:
            def replace(match: re.Match[str], current: PatternSpec = spec) -> str:
                original = match.group(current.secret_group)
                if original.startswith("⟪BNC_"):
                    return match.group(0)
                if current.skip_call_values and "(" in original:
                    return match.group(0)
                token = self._token_for(current.category, original)
                self._record(current, original)
                if current.secret_group == 0:
                    return token
                full = match.group(0)
                relative_start = match.start(current.secret_group) - match.start(0)
                relative_end = match.end(current.secret_group) - match.start(0)
                return full[:relative_start] + token + full[relative_end:]

            masked = spec.regex.sub(replace, masked)
        return masked

    def mask_value(self, value: Any) -> Any:
        if isinstance(value, str):
            return self.mask_text(value)
        if isinstance(value, list):
            return [self.mask_value(item) for item in value]
        if isinstance(value, dict):
            return {key: self.mask_value(item) for key, item in value.items()}
        return value

    def restore_text(self, text: str) -> str:
        restored = text
        for token, original in self._token_to_original.items():
            restored = restored.replace(token, original)
        return restored

    def normalize_serialized_placeholders(self, text: str) -> str:
        """Turn JSON-escaped placeholders back into literal placeholders."""
        normalized = text
        for token in self._token_to_original:
            escaped_token = json.dumps(token, ensure_ascii=True)[1:-1]
            normalized = normalized.replace(escaped_token, token)
        return normalized

    def restore_serialized_text(self, text: str) -> str:
        """Restore placeholders inside JSON or SSE without breaking string escaping."""
        restored = text
        for token, original in self._token_to_original.items():
            escaped_token = json.dumps(token, ensure_ascii=True)[1:-1]
            escaped_original = json.dumps(original, ensure_ascii=False)[1:-1]
            restored = restored.replace(escaped_token, escaped_original)
            restored = restored.replace(token, escaped_original)
        return restored

    def restore_value(self, value: Any) -> Any:
        if isinstance(value, str):
            return self.restore_text(value)
        if isinstance(value, list):
            return [self.restore_value(item) for item in value]
        if isinstance(value, dict):
            return {key: self.restore_value(item) for key, item in value.items()}
        return value
