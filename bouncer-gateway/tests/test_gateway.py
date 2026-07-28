import json
import threading
import unittest
import urllib.error
import urllib.request
from dataclasses import replace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from bouncer.config import Config
from bouncer.engine import BouncerEngine
from bouncer.http_server import make_server
from bouncer.types import AiAssessment


class FakeAi:
    def assess(self, direction, text, context=None):
        return AiAssessment(available=True, decision="allow", risk_score=0.01)

    def health(self):
        return {"available": True}


class EchoUpstreamHandler(BaseHTTPRequestHandler):
    received_body = b""
    response_text = ""
    response_stream = ""

    def log_message(self, fmt, *args):
        return

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        type(self).received_body = self.rfile.read(length)
        if type(self).response_stream:
            body = type(self).response_stream.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        payload = json.loads(type(self).received_body.decode("utf-8"))
        content = payload["messages"][0]["content"]
        text = type(self).response_text or f"Echo: {content}"
        body = json.dumps(
            {
                "id": "msg_test",
                "type": "message",
                "role": "assistant",
                "content": [{"type": "text", "text": text}],
                "model": "test",
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 1, "output_tokens": 1},
            }
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class GatewayTests(unittest.TestCase):
    def setUp(self) -> None:
        EchoUpstreamHandler.received_body = b""
        EchoUpstreamHandler.response_text = ""
        EchoUpstreamHandler.response_stream = ""
        self.upstream = ThreadingHTTPServer(("127.0.0.1", 0), EchoUpstreamHandler)
        self.upstream_thread = threading.Thread(
            target=self.upstream.serve_forever, daemon=True
        )
        self.upstream_thread.start()

        base_config = Config()
        self.config = replace(
            base_config,
            port=0,
            anthropic_upstream=(
                f"http://127.0.0.1:{self.upstream.server_address[1]}"
            ),
            allow_custom_upstream=True,
        )
        self.gateway = make_server(self.config, BouncerEngine(FakeAi()))
        self.gateway_thread = threading.Thread(
            target=self.gateway.serve_forever, daemon=True
        )
        self.gateway_thread.start()
        self.gateway_url = f"http://127.0.0.1:{self.gateway.server_address[1]}"

    def tearDown(self) -> None:
        self.gateway.shutdown()
        self.gateway.server_close()
        self.upstream.shutdown()
        self.upstream.server_close()

    def _post(self, payload):
        request = urllib.request.Request(
            self.gateway_url + "/v1/messages",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        return urllib.request.urlopen(request, timeout=5)

    def test_dashboard_and_status_are_available(self) -> None:
        with urllib.request.urlopen(self.gateway_url + "/", timeout=5) as response:
            html = response.read().decode("utf-8")
            self.assertEqual(response.status, 200)
            self.assertIn("text/html", response.headers["Content-Type"])
            self.assertIn("default-src 'none'", response.headers["Content-Security-Policy"])
        self.assertIn("通信の前後を", html)
        self.assertIn("/bouncer/status", html)

        with urllib.request.urlopen(
            self.gateway_url + "/bouncer/status", timeout=5
        ) as response:
            status = json.loads(response.read().decode("utf-8"))
        self.assertEqual(status["server"]["state"], "running")
        self.assertEqual(status["activity"]["totals"]["total"], 0)
        self.assertFalse(status["privacy"]["request_bodies_stored"])

    def test_status_records_result_without_secret_content(self) -> None:
        secret = "sk-ant-abcdefghijklmnopqrstuvwxyz123456"
        request = urllib.request.Request(
            self.gateway_url + "/bouncer/inspect",
            data=json.dumps(
                {"direction": "outbound", "text": f"Use {secret}"}
            ).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            self.assertEqual(response.status, 200)

        with urllib.request.urlopen(
            self.gateway_url + "/bouncer/status", timeout=5
        ) as response:
            raw_status = response.read().decode("utf-8")
            status = json.loads(raw_status)
        self.assertNotIn(secret, raw_status)
        self.assertEqual(status["activity"]["totals"]["total"], 1)
        self.assertEqual(status["activity"]["totals"]["allow_masked"], 1)
        self.assertEqual(status["activity"]["recent"][0]["masked_count"], 1)

    def test_secret_is_masked_upstream_and_restored_downstream(self) -> None:
        secret = "sk-ant-abcdefghijklmnopqrstuvwxyz123456"
        payload = {
            "model": "test",
            "max_tokens": 10,
            "messages": [{"role": "user", "content": f"Use {secret}"}],
        }

        with self._post(payload) as response:
            result = json.loads(response.read().decode("utf-8"))

        self.assertNotIn(secret.encode("utf-8"), EchoUpstreamHandler.received_body)
        self.assertIn("BNC_CREDENTIAL", EchoUpstreamHandler.received_body.decode("utf-8"))
        self.assertIn(secret, result["content"][0]["text"])

    def test_dangerous_inbound_response_is_blocked_before_client(self) -> None:
        EchoUpstreamHandler.response_text = "Run immediately: rm -rf /"
        payload = {
            "model": "test",
            "max_tokens": 10,
            "messages": [{"role": "user", "content": "Please inspect only"}],
        }

        with self.assertRaises(urllib.error.HTTPError) as raised:
            self._post(payload)

        try:
            self.assertEqual(raised.exception.code, 451)
            error = json.loads(raised.exception.read().decode("utf-8"))
            self.assertEqual(error["error"]["type"], "bouncer_blocked")
        finally:
            raised.exception.close()

    def test_dangerous_streamed_tool_call_is_blocked_before_client(self) -> None:
        """The whole streaming path: the tool input arrives in fragments that
        split the command, and the response still must not reach the client."""
        tool_input = '{"command":"' + "r" + "m" + ' -rf /"}'
        # The cut lands inside the flag, so a separator between the fragments
        # would hide the command from the rules.
        cut = tool_input.index("-rf") + 2
        events = [
            {
                "type": "content_block_start",
                "index": 0,
                "content_block": {
                    "type": "tool_use",
                    "id": "toolu_01AbCdEfGhIjKlMnOpQrSt",
                    "name": "Bash",
                    "input": {},
                },
            },
        ]
        for chunk in (tool_input[:cut], tool_input[cut:]):
            events.append(
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "input_json_delta", "partial_json": chunk},
                }
            )
        events.append({"type": "content_block_stop", "index": 0})
        EchoUpstreamHandler.response_stream = "".join(
            f"event: {event['type']}\ndata: {json.dumps(event, ensure_ascii=False)}\n\n"
            for event in events
        )

        payload = {
            "model": "test",
            "max_tokens": 10,
            "stream": True,
            "messages": [{"role": "user", "content": "整理してください"}],
        }
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self._post(payload)
        try:
            self.assertEqual(raised.exception.code, 451)
            error = json.loads(raised.exception.read().decode("utf-8"))
            codes = [item["code"] for item in error["error"]["findings"]]
            self.assertIn("destructive_rm", codes)
        finally:
            raised.exception.close()

    def test_ordinary_streamed_response_passes_through(self) -> None:
        events = [
            {
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "text", "text": ""},
            },
            {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": "設定を確認"},
            },
            {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": "しました。"},
            },
            {"type": "content_block_stop", "index": 0},
        ]
        EchoUpstreamHandler.response_stream = "".join(
            f"event: {event['type']}\ndata: {json.dumps(event, ensure_ascii=False)}\n\n"
            for event in events
        )
        payload = {
            "model": "test",
            "max_tokens": 10,
            "stream": True,
            "messages": [{"role": "user", "content": "確認して"}],
        }
        with self._post(payload) as response:
            body = response.read().decode("utf-8")
            self.assertEqual(response.status, 200)
        self.assertIn("text/event-stream", response.headers["Content-Type"])
        self.assertIn("設定を確認", body)

    def _request_with_host(self, host):
        request = urllib.request.Request(
            self.gateway_url + "/bouncer/status",
            headers={"Host": host},
            method="GET",
        )
        return urllib.request.urlopen(request, timeout=5)

    def test_rejects_a_host_header_that_is_not_loopback(self) -> None:
        """A name that resolves elsewhere is how DNS rebinding reaches a
        loopback-only server from a browser."""
        port = self.gateway.server_address[1]
        for host in ("evil.example.com", f"attacker.test:{port}", "192.168.1.20"):
            with self.subTest(host=host):
                with self.assertRaises(urllib.error.HTTPError) as raised:
                    self._request_with_host(host)
                try:
                    self.assertEqual(raised.exception.code, 403)
                finally:
                    raised.exception.close()

    def test_accepts_loopback_host_headers(self) -> None:
        port = self.gateway.server_address[1]
        for host in (f"127.0.0.1:{port}", f"localhost:{port}", "localhost", "[::1]"):
            with self.subTest(host=host):
                with self._request_with_host(host) as response:
                    self.assertEqual(response.status, 200)

    def test_blocked_host_does_not_reach_the_upstream(self) -> None:
        request = urllib.request.Request(
            self.gateway_url + "/v1/messages",
            data=json.dumps(
                {
                    "model": "test",
                    "max_tokens": 10,
                    "messages": [{"role": "user", "content": "hello"}],
                }
            ).encode("utf-8"),
            headers={"Content-Type": "application/json", "Host": "evil.example.com"},
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(request, timeout=5)
        try:
            self.assertEqual(raised.exception.code, 403)
        finally:
            raised.exception.close()
        self.assertEqual(EchoUpstreamHandler.received_body, b"")

    def test_rejects_non_json_content_type(self) -> None:
        request = urllib.request.Request(
            self.gateway_url + "/bouncer/inspect",
            data=b'{"direction":"outbound","text":"safe"}',
            headers={"Content-Type": "text/plain"},
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(request, timeout=5)
        try:
            self.assertEqual(raised.exception.code, 415)
        finally:
            raised.exception.close()


if __name__ == "__main__":
    unittest.main()
