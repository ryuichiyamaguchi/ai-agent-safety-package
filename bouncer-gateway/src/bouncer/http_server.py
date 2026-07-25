from __future__ import annotations

import http.client
import json
import ssl
import sys
import threading
import time
from collections import defaultdict, deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlsplit

from .activity import ActivityHandle, ActivityMonitor
from .config import Config
from .dashboard import dashboard_bytes
from .engine import BouncerEngine
from .masking import MaskingSession
from .rules import evaluate_rules


HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


class SlidingWindowRateLimiter:
    def __init__(self) -> None:
        self._events: dict[tuple[str, str], deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def allow(
        self,
        client: str,
        bucket: str,
        limit: int,
        window_seconds: float = 60.0,
    ) -> bool:
        now = time.monotonic()
        cutoff = now - window_seconds
        key = (client, bucket)
        with self._lock:
            events = self._events[key]
            while events and events[0] < cutoff:
                events.popleft()
            if len(events) >= limit:
                return False
            events.append(now)
            return True


def _json_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _extract_review_text(body: str, content_type: str) -> str:
    if "text/event-stream" not in content_type.lower():
        try:
            value = json.loads(body)
        except json.JSONDecodeError:
            return body
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

    fragments: list[str] = []
    for line in body.splitlines():
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            event = json.loads(payload)
        except json.JSONDecodeError:
            fragments.append(payload)
            continue
        if not isinstance(event, dict):
            continue
        delta = event.get("delta")
        if isinstance(delta, dict):
            for key in ("text", "partial_json", "thinking"):
                if isinstance(delta.get(key), str):
                    fragments.append(delta[key])
        block = event.get("content_block")
        if isinstance(block, dict):
            fragments.append(json.dumps(block, ensure_ascii=False, separators=(",", ":")))
        message = event.get("message")
        if isinstance(message, dict):
            fragments.append(json.dumps(message, ensure_ascii=False, separators=(",", ":")))
        error = event.get("error")
        if isinstance(error, dict):
            fragments.append(json.dumps(error, ensure_ascii=False, separators=(",", ":")))
    return "\n".join(fragments) if fragments else body


def _content_for_review(content: Any) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return json.dumps(content, ensure_ascii=False, separators=(",", ":"))
    fragments: list[str] = []
    for item in content:
        if not isinstance(item, dict):
            continue
        item_type = item.get("type")
        if item_type in {"text", "thinking"} and isinstance(item.get("text"), str):
            fragments.append(item["text"])
        elif item_type == "tool_use":
            fragments.append(
                json.dumps(
                    {
                        "type": "tool_use",
                        "name": item.get("name"),
                        "input": item.get("input"),
                    },
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
            )
        elif item_type == "tool_result":
            fragments.append(_content_for_review(item.get("content")))
    return "\n".join(fragments)


def _extract_anthropic_request_context(payload: dict[str, Any]) -> dict[str, Any]:
    messages: list[dict[str, str]] = []
    raw_messages = payload.get("messages")
    if isinstance(raw_messages, list):
        for message in raw_messages[-4:]:
            if not isinstance(message, dict):
                continue
            messages.append(
                {
                    "role": str(message.get("role", "unknown")),
                    "content": _content_for_review(message.get("content"))[-1500:],
                }
            )
    tool_names = [
        str(item.get("name"))
        for item in payload.get("tools", [])
        if isinstance(item, dict) and item.get("name")
    ][:80]
    return {
        "model": payload.get("model"),
        "messages": messages,
        "available_tools": tool_names,
    }


def _make_connection(upstream: str, timeout: float) -> tuple[http.client.HTTPConnection, str]:
    parsed = urlsplit(upstream)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("invalid upstream URL")
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    if parsed.scheme == "https":
        connection: http.client.HTTPConnection = http.client.HTTPSConnection(
            parsed.hostname,
            port,
            timeout=timeout,
            context=ssl.create_default_context(),
        )
    else:
        connection = http.client.HTTPConnection(parsed.hostname, port, timeout=timeout)
    return connection, parsed.path.rstrip("/")


class BouncerHttpServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        server_address: tuple[str, int],
        handler_class: type[BaseHTTPRequestHandler],
        config: Config,
        engine: BouncerEngine,
    ) -> None:
        super().__init__(server_address, handler_class)
        self.config = config
        self.engine = engine
        self.rate_limiter = SlidingWindowRateLimiter()
        self.activity = ActivityMonitor()
        self._health_lock = threading.Lock()
        self._health_checked_at = 0.0
        self._health_value: dict[str, Any] = {
            "available": False,
            "summary": "local AI status has not been checked",
        }

    def local_ai_health(self) -> dict[str, Any]:
        now = time.monotonic()
        with self._health_lock:
            if now - self._health_checked_at < 8.0:
                return dict(self._health_value)
            self._health_value = self.engine.ai_client.health()
            self._health_checked_at = time.monotonic()
            return dict(self._health_value)

    def status_payload(self) -> dict[str, Any]:
        activity = self.activity.snapshot()
        upstream = urlsplit(self.config.anthropic_upstream)
        return {
            "status": "success",
            "server": {
                "state": "running",
                "listen": f"{self.config.host}:{self.server_address[1]}",
            },
            "local_ai": self.local_ai_health(),
            "protection": {
                "ai_mode": self.config.ai_mode,
                "review_mode": self.config.review_mode,
                "ai_failure_mode": self.config.ai_failure_mode,
                "local_model": self.config.lm_studio_model,
                "upstream_host": upstream.hostname or "unknown",
            },
            "privacy": {
                "request_bodies_stored": False,
                "secret_values_stored": False,
                "mask_mapping_persisted": False,
            },
            "activity": activity,
        }


class BouncerHandler(BaseHTTPRequestHandler):
    server_version = "LocalBouncer/0.1"
    sys_version = ""

    @property
    def app(self) -> BouncerHttpServer:
        return self.server  # type: ignore[return-value]

    def log_message(self, fmt: str, *args: Any) -> None:
        # Never include request bodies or credentials in logs.
        event = {
            "event": "http",
            "client": self.client_address[0],
            "method": self.command,
            "path": urlsplit(self.path).path,
            "message": fmt % args,
        }
        print(json.dumps(event, ensure_ascii=False), file=sys.stderr, flush=True)

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0"))
        if length < 0 or length > self.app.config.max_request_bytes:
            raise ValueError("request body is too large")
        return self.rfile.read(length)

    def _send_bytes(
        self,
        status: int,
        body: bytes,
        content_type: str,
        headers: list[tuple[str, str]] | None = None,
    ) -> None:
        self.send_response(status)
        if headers:
            for key, value in headers:
                lower = key.lower()
                if lower in HOP_BY_HOP or lower in {
                    "content-length",
                    "content-encoding",
                    "server",
                    "date",
                }:
                    continue
                self.send_header(key, value)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Permissions-Policy",
            "camera=(), microphone=(), geolocation=(), payment=()",
        )
        if content_type.startswith("text/html"):
            self.send_header(
                "Content-Security-Policy",
                "default-src 'none'; style-src 'unsafe-inline'; "
                "script-src 'unsafe-inline'; connect-src 'self'; "
                "img-src data:; base-uri 'none'; frame-ancestors 'none'",
            )
        try:
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            # Clients such as coding agents can cancel a retried request while
            # the buffered local review is still running.
            return

    def _send_json(self, status: int, value: Any) -> None:
        self._send_bytes(status, _json_bytes(value), "application/json; charset=utf-8")

    def _blocked(self, result: Any) -> None:
        self._send_json(
            451,
            {
                "type": "error",
                "error": {
                    "type": "bouncer_blocked",
                    "message": result.summary,
                    "decision": result.decision,
                    "risk_score": round(result.risk_score, 3),
                    "findings": [
                        {
                            "code": item.code,
                            "severity": item.severity,
                            "summary": item.summary,
                        }
                        for item in result.findings
                    ],
                    "local_ai": {
                        "available": result.ai.available,
                        "error": (
                            "local_ai_unavailable" if result.ai.error else None
                        ),
                    },
                },
            },
        )

    def _must_stop(self, decision: str) -> bool:
        return decision == "block" or (
            decision == "review" and self.app.config.review_mode == "block"
        )

    def do_GET(self) -> None:  # noqa: N802
        path = urlsplit(self.path).path
        if path == "/":
            self._send_bytes(
                200,
                dashboard_bytes(),
                "text/html; charset=utf-8",
            )
            return
        if path == "/bouncer/status":
            self._send_json(200, self.app.status_payload())
            return
        if path == "/bouncer/health":
            self._send_json(
                200,
                {
                    "status": "success",
                    "summary": "Bouncer is running",
                    "next_actions": [],
                    "artifacts": [],
                    "local_ai": self.app.local_ai_health(),
                },
            )
            return
        if path == "/v1/models":
            self._proxy_anthropic(None)
            return
        self._send_json(404, {"status": "error", "summary": "not found"})

    def do_HEAD(self) -> None:  # noqa: N802
        if urlsplit(self.path).path == "/":
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self) -> None:  # noqa: N802
        path = urlsplit(self.path).path
        if path in {"/bouncer/inspect", "/v1/messages", "/v1/messages/count_tokens"}:
            content_type = self.headers.get("Content-Type", "").lower()
            if not content_type.startswith("application/json"):
                self.close_connection = True
                self._send_json(
                    415,
                    {"status": "error", "summary": "application/json is required"},
                )
                return
            limit = 30 if path == "/bouncer/inspect" else 120
            if not self.app.rate_limiter.allow(
                self.client_address[0], path, limit=limit
            ):
                self.close_connection = True
                self._send_json(
                    429,
                    {"status": "error", "summary": "local rate limit exceeded"},
                )
                return
        try:
            body = self._read_body()
        except (ValueError, OSError) as exc:
            self._send_json(413, {"status": "error", "summary": str(exc)})
            return

        if path == "/bouncer/inspect":
            self._inspect_endpoint(body)
            return
        if path in {"/v1/messages", "/v1/messages/count_tokens"}:
            self._proxy_anthropic(body)
            return
        self._send_json(404, {"status": "error", "summary": "not found"})

    def _inspect_endpoint(self, body: bytes) -> None:
        with self.app.activity.track(
            "inspect", "単独の検査リクエストを読み取り中"
        ) as activity:
            try:
                payload = json.loads(body.decode("utf-8"))
                if not isinstance(payload, dict):
                    raise ValueError("JSON body must be an object")
                direction = str(payload.get("direction", "outbound"))
                text = str(payload.get("text", ""))
                activity.stage("ルール・機密候補・危険な指示を検査中")
                result, _ = self.app.engine.inspect(
                    direction, text, payload.get("context")
                )
            except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
                activity.complete("error", "検査リクエストを読み取れませんでした")
                self._send_json(400, {"status": "error", "summary": str(exc)})
                return
            activity.complete(
                result.decision,
                result.summary,
                masked_count=result.masked_count,
                finding_codes=[item.code for item in result.findings],
            )
            self._send_json(200, result.to_dict())

    def _proxy_anthropic(self, body: bytes | None) -> None:
        kind = "models" if body is None else "gateway"
        stage = (
            "上流のモデル情報を確認中"
            if body is None
            else "送信前の検査を準備中"
        )
        with self.app.activity.track(kind, stage) as activity:
            self._proxy_anthropic_tracked(body, activity)

    def _proxy_anthropic_tracked(
        self,
        body: bytes | None,
        activity: ActivityHandle,
    ) -> None:
        started = time.monotonic()
        session = MaskingSession()
        outbound_result = None
        outgoing_body = body

        if body is not None:
            try:
                payload = json.loads(body.decode("utf-8"))
                if not isinstance(payload, dict):
                    raise ValueError("request JSON must be an object")
            except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
                activity.complete("error", "Gatewayリクエストを読み取れませんでした")
                self._send_json(400, {"status": "error", "summary": str(exc)})
                return

            activity.stage("機密候補をマスクし、送信内容を検査中")
            masked_payload = session.mask_value(payload)
            request_context = _extract_anthropic_request_context(masked_payload)
            if urlsplit(self.path).path == "/v1/messages":
                review_text = json.dumps(
                    request_context, ensure_ascii=False, separators=(",", ":")
                )
                has_injection_signal = any(
                    item.category == "prompt_injection"
                    for item in evaluate_rules("outbound", review_text)
                )
                outbound_result = self.app.engine.inspect_prepared(
                    direction="outbound",
                    masked_text=review_text,
                    mask_findings=list(session.findings),
                    masked_count=session.masked_count,
                    context={
                        "protocol": "anthropic_messages",
                        "path": urlsplit(self.path).path,
                    },
                    use_ai=(
                        self.app.config.ai_mode == "strict" or has_injection_signal
                    ),
                )
                if self._must_stop(outbound_result.decision):
                    self._audit("outbound_block", outbound_result, started)
                    activity.complete(
                        outbound_result.decision,
                        outbound_result.summary,
                        masked_count=session.masked_count,
                        finding_codes=[
                            item.code for item in outbound_result.findings
                        ],
                    )
                    self._blocked(outbound_result)
                    return
            outgoing_body = _json_bytes(masked_payload)
        else:
            request_context = {}

        activity.stage("安全な内容をAnthropicへ転送中")
        try:
            connection, base_path = _make_connection(
                self.app.config.anthropic_upstream,
                self.app.config.upstream_timeout_seconds,
            )
            parsed_path = urlsplit(self.path)
            upstream_path = base_path + parsed_path.path
            if parsed_path.query:
                upstream_path += "?" + parsed_path.query

            headers: dict[str, str] = {}
            for key, value in self.headers.items():
                lower = key.lower()
                if lower in HOP_BY_HOP or lower in {
                    "host",
                    "content-length",
                    "accept-encoding",
                }:
                    continue
                headers[key] = value
            headers["Accept-Encoding"] = "identity"
            headers["Via"] = "Local-Bouncer/0.1"
            if outgoing_body is not None:
                headers["Content-Length"] = str(len(outgoing_body))

            connection.request(self.command, upstream_path, body=outgoing_body, headers=headers)
            response = connection.getresponse()
            response_body = response.read(self.app.config.max_response_bytes + 1)
            response_headers = response.getheaders()
            status = response.status
            content_type = response.getheader("Content-Type", "application/octet-stream")
            connection.close()
            if len(response_body) > self.app.config.max_response_bytes:
                raise ValueError("upstream response is too large")
        except Exception as exc:
            print(
                json.dumps(
                    {
                        "event": "upstream_error",
                        "path": urlsplit(self.path).path,
                        "error_type": type(exc).__name__,
                    },
                    ensure_ascii=False,
                ),
                file=sys.stderr,
                flush=True,
            )
            activity.complete(
                "error",
                "Anthropicへの接続に失敗しました",
                masked_count=session.masked_count,
            )
            self._send_json(
                502,
                {
                    "status": "error",
                    "summary": "upstream request failed",
                    "next_actions": ["ネットワークと上流URLを確認してください"],
                    "artifacts": [],
                },
            )
            return

        if status < 400 and urlsplit(self.path).path == "/v1/messages":
            activity.stage("応答をローカルで検査中")
            try:
                response_text = response_body.decode("utf-8")
            except UnicodeDecodeError:
                activity.complete(
                    "error",
                    "Anthropicの応答を読み取れませんでした",
                    masked_count=session.masked_count,
                    upstream_status=status,
                )
                self._send_json(
                    502,
                    {"status": "error", "summary": "upstream returned non-UTF-8 data"},
                )
                return
            finding_start = len(session.findings)
            is_event_stream = "text/event-stream" in content_type.lower()
            response_object: Any | None = None
            if is_event_stream:
                normalized_response = session.normalize_serialized_placeholders(
                    response_text
                )
                masked_response = session.mask_text(normalized_response)
            else:
                try:
                    response_object = json.loads(response_text)
                except json.JSONDecodeError:
                    masked_response = session.mask_text(response_text)
                else:
                    response_object = session.mask_value(response_object)
                    masked_response = json.dumps(
                        response_object,
                        ensure_ascii=False,
                        separators=(",", ":"),
                    )
            new_findings = list(session.findings[finding_start:])
            review_text = _extract_review_text(masked_response, content_type)
            inbound_result = self.app.engine.inspect_prepared(
                direction="inbound",
                masked_text=review_text,
                mask_findings=new_findings,
                masked_count=session.masked_count,
                context={
                    "protocol": "anthropic_messages",
                    "request": request_context,
                    "outbound_decision": (
                        outbound_result.decision if outbound_result is not None else "allow"
                    ),
                },
            )
            if self._must_stop(inbound_result.decision):
                self._audit("inbound_block", inbound_result, started)
                activity.complete(
                    inbound_result.decision,
                    inbound_result.summary,
                    masked_count=session.masked_count,
                    finding_codes=[item.code for item in inbound_result.findings],
                    upstream_status=status,
                )
                self._blocked(inbound_result)
                return
            if response_object is not None:
                response_body = _json_bytes(session.restore_value(response_object))
            elif is_event_stream:
                response_body = session.restore_serialized_text(masked_response).encode(
                    "utf-8"
                )
            else:
                response_body = session.restore_text(masked_response).encode("utf-8")
            self._audit("allow", inbound_result, started)
            activity.complete(
                inbound_result.decision,
                inbound_result.summary,
                masked_count=session.masked_count,
                finding_codes=[item.code for item in inbound_result.findings],
                upstream_status=status,
            )
        else:
            self._audit("upstream_response", outbound_result, started, status=status)
            if status >= 400:
                activity.complete(
                    "error",
                    f"AnthropicからHTTP {status}を受信しました",
                    masked_count=session.masked_count,
                    upstream_status=status,
                )
            else:
                decision = getattr(outbound_result, "decision", "allow")
                summary = getattr(
                    outbound_result,
                    "summary",
                    "上流の情報を安全に受信しました",
                )
                activity.complete(
                    decision,
                    summary,
                    masked_count=session.masked_count,
                    finding_codes=[
                        item.code for item in getattr(outbound_result, "findings", [])
                    ],
                    upstream_status=status,
                )

        self._send_bytes(status, response_body, content_type, response_headers)

    def _audit(
        self,
        event: str,
        result: Any,
        started: float,
        status: int | None = None,
    ) -> None:
        record = {
            "event": event,
            "path": urlsplit(self.path).path,
            "decision": getattr(result, "decision", None),
            "risk_score": getattr(result, "risk_score", None),
            "finding_codes": [item.code for item in getattr(result, "findings", [])],
            "local_ai_available": getattr(getattr(result, "ai", None), "available", None),
            "local_ai_error": (
                "local_ai_unavailable"
                if getattr(getattr(result, "ai", None), "error", None)
                else None
            ),
            "upstream_status": status,
            "elapsed_ms": round((time.monotonic() - started) * 1000),
        }
        print(json.dumps(record, ensure_ascii=False), file=sys.stderr, flush=True)


def make_server(config: Config, engine: BouncerEngine) -> BouncerHttpServer:
    config.validate()
    return BouncerHttpServer((config.host, config.port), BouncerHandler, config, engine)


def run_server(config: Config, engine: BouncerEngine) -> None:
    server = make_server(config, engine)
    print(
        f"Bouncer listening on http://{config.host}:{server.server_address[1]}",
        flush=True,
    )
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
