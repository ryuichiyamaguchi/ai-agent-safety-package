from __future__ import annotations

import ipaddress
import os
from dataclasses import dataclass
from urllib.parse import urlsplit


def _env_bool(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Config:
    host: str = "127.0.0.1"
    port: int = 8787
    lm_studio_base_url: str = "http://127.0.0.1:1234/v1"
    lm_studio_model: str = "bouncer-gemma"
    ai_enabled: bool = True
    ai_mode: str = "balanced"
    ai_timeout_seconds: float = 120.0
    upstream_timeout_seconds: float = 600.0
    max_request_bytes: int = 2 * 1024 * 1024
    max_response_bytes: int = 32 * 1024 * 1024
    anthropic_upstream: str = "https://api.anthropic.com"
    allow_custom_upstream: bool = False
    review_mode: str = "block"
    ai_failure_mode: str = "block"

    @classmethod
    def from_env(cls) -> "Config":
        config = cls(
            host=os.environ.get("BOUNCER_HOST", "127.0.0.1"),
            port=int(os.environ.get("BOUNCER_PORT", "8787")),
            lm_studio_base_url=os.environ.get(
                "BOUNCER_LM_STUDIO_URL", "http://127.0.0.1:1234/v1"
            ).rstrip("/"),
            lm_studio_model=os.environ.get("BOUNCER_LOCAL_MODEL", "bouncer-gemma"),
            ai_enabled=_env_bool("BOUNCER_AI_ENABLED", True),
            ai_mode=os.environ.get("BOUNCER_AI_MODE", "balanced").lower(),
            ai_timeout_seconds=float(os.environ.get("BOUNCER_AI_TIMEOUT", "120")),
            upstream_timeout_seconds=float(
                os.environ.get("BOUNCER_UPSTREAM_TIMEOUT", "600")
            ),
            max_request_bytes=int(
                os.environ.get("BOUNCER_MAX_REQUEST_BYTES", str(2 * 1024 * 1024))
            ),
            max_response_bytes=int(
                os.environ.get("BOUNCER_MAX_RESPONSE_BYTES", str(32 * 1024 * 1024))
            ),
            anthropic_upstream=os.environ.get(
                "BOUNCER_ANTHROPIC_UPSTREAM", "https://api.anthropic.com"
            ).rstrip("/"),
            allow_custom_upstream=_env_bool("BOUNCER_ALLOW_CUSTOM_UPSTREAM", False),
            review_mode=os.environ.get("BOUNCER_REVIEW_MODE", "block").lower(),
            ai_failure_mode=os.environ.get(
                "BOUNCER_AI_FAILURE_MODE", "block"
            ).lower(),
        )
        config.validate()
        return config

    def validate(self) -> None:
        if self.review_mode not in {"block", "pass"}:
            raise ValueError("BOUNCER_REVIEW_MODE must be 'block' or 'pass'")
        if self.ai_failure_mode not in {"block", "rules"}:
            raise ValueError("BOUNCER_AI_FAILURE_MODE must be 'block' or 'rules'")
        if self.ai_mode not in {"balanced", "strict"}:
            raise ValueError("BOUNCER_AI_MODE must be 'balanced' or 'strict'")
        upstream = urlsplit(self.anthropic_upstream)
        if (
            upstream.scheme not in {"http", "https"}
            or not upstream.hostname
            or upstream.username
            or upstream.password
        ):
            raise ValueError("BOUNCER_ANTHROPIC_UPSTREAM is invalid")
        if not self.allow_custom_upstream:
            if (
                upstream.scheme != "https"
                or upstream.hostname != "api.anthropic.com"
                or upstream.port not in {None, 443}
                or upstream.path not in {"", "/"}
            ):
                raise ValueError(
                    "custom Anthropic upstream requires BOUNCER_ALLOW_CUSTOM_UPSTREAM=1"
                )
        elif upstream.scheme == "http":
            try:
                upstream_address = ipaddress.ip_address(upstream.hostname)
            except ValueError as exc:
                raise ValueError("plain HTTP custom upstream must be loopback") from exc
            if not upstream_address.is_loopback:
                raise ValueError("plain HTTP custom upstream must be loopback")
        try:
            address = ipaddress.ip_address(self.host)
        except ValueError as exc:
            raise ValueError("Bouncer must bind to a loopback IP") from exc
        if not address.is_loopback:
            raise ValueError("Bouncer must bind to a loopback IP")
