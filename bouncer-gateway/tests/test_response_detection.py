"""Detection against the response shapes Anthropic actually sends.

The older tests only used a hand-written `{"type":"tool_use","name":...}`
shape. A real response puts `"id"` between those two keys, and a streamed
response delivers the tool input as `partial_json` fragments that may split
anywhere, so both are covered here.
"""

import json
import unittest

from bouncer.http_server import _extract_review_text
from bouncer.rules import evaluate_rules


DOT_ENV = "." + "env"
SSH_DIR = "." + "ssh"
PRIVATE_KEY_NAME = "id_" + "ed" + "25519"
REMOVE = "r" + "m"
ROOT_ADMIN = "su" + "do"
CORE_FILE = "/workspace/" + "bouncer" + "/src/bouncer/" + "rules.py"


def _codes(text: str) -> set[str]:
    return {item.code for item in evaluate_rules("inbound", text)}


def _dumps(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _real_response(*blocks: dict[str, object]) -> str:
    """A complete non-streaming response, with the real key order."""
    return _dumps(
        {
            "id": "msg_01XyZaBcDeFgHiJkLmNoPq",
            "type": "message",
            "role": "assistant",
            "model": "claude-sonnet-4-5",
            "content": list(blocks),
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 42, "output_tokens": 17},
        }
    )


def _tool_block(name: str, input_value: dict[str, object]) -> dict[str, object]:
    return {
        "type": "tool_use",
        "id": "toolu_01AbCdEfGhIjKlMnOpQrSt",
        "name": name,
        "input": input_value,
    }


def _text_block(text: str) -> dict[str, object]:
    return {"type": "text", "text": text}


def _sse(events: list[dict[str, object]]) -> str:
    lines = []
    for event in events:
        lines.append(f"event: {event['type']}")
        lines.append(f"data: {_dumps(event)}")
        lines.append("")
    return "\n".join(lines) + "\n"


def _streamed_tool_use(name: str, input_value: dict[str, object], splits: tuple[int, ...]) -> str:
    """One streamed tool call whose input is cut at the given offsets."""
    raw = _dumps(input_value)
    bounds = (0,) + splits + (len(raw),)
    chunks = [raw[bounds[i] : bounds[i + 1]] for i in range(len(bounds) - 1)]
    events: list[dict[str, object]] = [
        {
            "type": "message_start",
            "message": {
                "id": "msg_01XyZaBcDeFgHiJkLmNoPq",
                "type": "message",
                "role": "assistant",
                "model": "claude-sonnet-4-5",
                "content": [],
            },
        },
        {
            "type": "content_block_start",
            "index": 0,
            "content_block": {
                "type": "tool_use",
                "id": "toolu_01AbCdEfGhIjKlMnOpQrSt",
                "name": name,
                "input": {},
            },
        },
    ]
    for chunk in chunks:
        events.append(
            {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "input_json_delta", "partial_json": chunk},
            }
        )
    events.append({"type": "content_block_stop", "index": 0})
    events.append(
        {"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 9}}
    )
    return _sse(events)


def _streamed_review_text(name: str, input_value: dict[str, object], splits: tuple[int, ...]) -> str:
    return _extract_review_text(
        _streamed_tool_use(name, input_value, splits), "text/event-stream"
    )


class RealResponseShapeTests(unittest.TestCase):
    """The four self-protection rules never fired because of the `"id"` key."""

    def test_core_file_edit_is_caught_with_id_between_type_and_name(self) -> None:
        response = _real_response(
            _tool_block("Edit", {"file_path": CORE_FILE, "new_string": "RULES = ()"})
        )
        self.assertIn('"type":"tool_use","id":', response)
        self.assertIn("bouncer_core_file_edit", _codes(response))

    def test_core_bash_write_is_caught_with_id_between_type_and_name(self) -> None:
        response = _real_response(
            _tool_block("Bash", {"command": f"cp /tmp/patched.py {CORE_FILE}"})
        )
        self.assertIn("bouncer_core_bash_write", _codes(response))

    def test_stop_attempt_is_caught_with_id_between_type_and_name(self) -> None:
        response = _real_response(_tool_block("Bash", {"command": "pkill -f bouncer"}))
        self.assertIn("bouncer_stop_attempt", _codes(response))

    def test_safety_weakening_is_caught_with_id_between_type_and_name(self) -> None:
        response = _real_response(
            _tool_block("Bash", {"command": "export BOUNCER_REVIEW_MODE=pass"})
        )
        self.assertIn("bouncer_safety_weakening", _codes(response))

    def test_admin_privilege_is_caught_inside_a_json_string(self) -> None:
        response = _real_response(
            _tool_block("Bash", {"command": f"{ROOT_ADMIN} chmod -R 777 /Library"})
        )
        self.assertIn("unbounded_sudo", _codes(response))

    def test_credential_targets_survive_the_real_shape(self) -> None:
        env_response = _real_response(
            _tool_block("Bash", {"command": f"base64 ~/{DOT_ENV}"})
        )
        key_response = _real_response(
            _tool_block("Read", {"file_path": f"/Users/example/{SSH_DIR}/{PRIVATE_KEY_NAME}"})
        )
        self.assertIn("sensitive_env_file_access", _codes(env_response))
        self.assertIn("private_credential_file_access", _codes(key_response))

    def test_a_tool_name_the_gateway_cannot_read_is_still_inspected(self) -> None:
        """Fail-closed: an unreadable name must not turn a rule off."""
        response = _dumps(
            {
                "type": "message",
                "content": [
                    {
                        "type": "tool_use",
                        "id": "toolu_01AbCdEfGhIjKlMnOpQrSt",
                        "input": {"command": "pkill -f bouncer"},
                    }
                ],
            }
        )
        self.assertIn("bouncer_stop_attempt", _codes(response))


class StreamSplitTests(unittest.TestCase):
    """`partial_json` fragments were joined with a newline, which broke any
    command whose split landed inside it."""

    def test_fragments_are_joined_without_a_separator(self) -> None:
        review = _streamed_review_text("Bash", {"command": f"{REMOVE} -rf /"}, (13, 17))
        self.assertIn(f"{REMOVE} -rf /", review)

    def test_destructive_delete_is_caught_at_every_split_point(self) -> None:
        payload = {"command": f"{REMOVE} -rf /"}
        raw = _dumps(payload)
        missed = []
        for cut in range(1, len(raw)):
            review = _streamed_review_text("Bash", payload, (cut,))
            if "destructive_rm" not in _codes(review):
                missed.append(cut)
        self.assertEqual(missed, [], f"split positions that were not detected: {missed}")

    def test_destructive_delete_is_caught_at_every_pair_of_split_points(self) -> None:
        payload = {"command": f"{REMOVE} -rf /"}
        raw = _dumps(payload)
        missed = []
        for first in range(1, len(raw)):
            for second in range(first + 1, len(raw)):
                review = _streamed_review_text("Bash", payload, (first, second))
                if "destructive_rm" not in _codes(review):
                    missed.append((first, second))
        self.assertEqual(missed, [], f"split positions that were not detected: {missed}")

    def test_self_protection_survives_every_split_point(self) -> None:
        payload = {"command": "pkill -f bouncer"}
        raw = _dumps(payload)
        missed = []
        for cut in range(1, len(raw)):
            review = _streamed_review_text("Bash", payload, (cut,))
            if "bouncer_stop_attempt" not in _codes(review):
                missed.append(cut)
        self.assertEqual(missed, [], f"split positions that were not detected: {missed}")

    def test_streamed_tool_input_is_rebuilt_into_a_real_object(self) -> None:
        review = _streamed_review_text("Edit", {"file_path": CORE_FILE}, (9, 20))
        rebuilt = json.loads(review.splitlines()[-1])
        self.assertEqual(rebuilt["type"], "tool_use")
        self.assertEqual(rebuilt["name"], "Edit")
        self.assertEqual(rebuilt["input"], {"file_path": CORE_FILE})

    def test_streamed_text_deltas_are_still_joined_without_a_separator(self) -> None:
        stream = _sse(
            [
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "text", "text": ""},
                },
                {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": f"{REMOVE} -r"}},
                {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "f /"}},
                {"type": "content_block_stop", "index": 0},
            ]
        )
        review = _extract_review_text(stream, "text/event-stream")
        self.assertIn(f"{REMOVE} -rf /", review)
        self.assertIn("destructive_rm", _codes(review))

    def test_separate_blocks_are_not_glued_together(self) -> None:
        """Two blocks must stay apart, or a harmless pair could read as one
        dangerous command."""
        stream = _sse(
            [
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "text", "text": ""},
                },
                {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": f"{REMOVE} -rf"}},
                {"type": "content_block_stop", "index": 0},
                {
                    "type": "content_block_start",
                    "index": 1,
                    "content_block": {"type": "text", "text": ""},
                },
                {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": " /"}},
                {"type": "content_block_stop", "index": 1},
            ]
        )
        review = _extract_review_text(stream, "text/event-stream")
        self.assertNotIn(f"{REMOVE} -rf /", review)


class DestructiveDeleteVariantTests(unittest.TestCase):
    def test_variants_that_used_to_slip_through(self) -> None:
        for command in (
            f"{REMOVE} -rf /*",
            f'{REMOVE} -rf "/Users/foo"',
            f"{REMOVE} -rf '/Users/foo'",
            f"{REMOVE} -r -f /",
            f"{REMOVE} -f -r ~",
            f"{REMOVE} --recursive --force /",
            f"{REMOVE} -rf --no-preserve-root /",
            f"{REMOVE} -rf $HOME",
            f"{REMOVE} -fr ~/",
        ):
            with self.subTest(command=command):
                response = _real_response(_tool_block("Bash", {"command": command}))
                self.assertIn("destructive_rm", _codes(response))

    def test_narrow_deletes_are_left_alone(self) -> None:
        for command in (
            f"{REMOVE} -rf ./build",
            f"{REMOVE} -rf node_modules",
            f"{REMOVE} -f /Users/example/project/tmp.log",
            f"{REMOVE} --force /",
            f"{REMOVE} -r ./cache",
        ):
            with self.subTest(command=command):
                response = _real_response(_tool_block("Bash", {"command": command}))
                self.assertNotIn("destructive_rm", _codes(response))


class NormalResponseTests(unittest.TestCase):
    """Responses that must keep passing, so the gateway stays usable."""

    def test_explaining_the_danger_in_prose_is_not_a_finding(self) -> None:
        response = _real_response(
            _text_block(
                f"{REMOVE} -rf は危険です、使わないでください。"
                f"{ROOT_ADMIN} も必要な場面以外では避けましょう。"
            )
        )
        self.assertEqual(_codes(response), set())

    def test_ordinary_tool_calls_are_not_findings(self) -> None:
        response = _real_response(
            _text_block("プロジェクトの構成を確認します。"),
            _tool_block("Bash", {"command": "ls -la src"}),
            _tool_block("Read", {"file_path": "/workspace/project/README.md"}),
            _tool_block("Edit", {"file_path": "/workspace/project/app.py", "new_string": "x = 1"}),
        )
        self.assertEqual(_codes(response), set())

    def test_reading_bouncer_source_is_not_a_write(self) -> None:
        response = _real_response(
            _tool_block("Bash", {"command": "git log --oneline -- src/bouncer/rules.py"})
        )
        codes = _codes(response)
        self.assertNotIn("bouncer_core_bash_write", codes)
        self.assertNotIn("bouncer_stop_attempt", codes)

    def test_a_path_mentioned_in_prose_is_not_a_tool_access(self) -> None:
        response = _real_response(
            _tool_block("Read", {"file_path": "/workspace/project/README.md"}),
            _text_block(f"設定は ~/{SSH_DIR}/{PRIVATE_KEY_NAME} と ~/{DOT_ENV} にあります。"),
        )
        codes = _codes(response)
        self.assertNotIn("private_credential_file_access", codes)
        self.assertNotIn("sensitive_env_file_access", codes)

    def test_a_normal_push_is_not_a_force_push(self) -> None:
        response = _real_response(
            _tool_block("Bash", {"command": "git push origin feature/ui"})
        )
        self.assertNotIn("force_push_protected_branch", _codes(response))

    def test_a_word_that_merely_contains_the_admin_command(self) -> None:
        response = _real_response(
            _tool_block("Bash", {"command": "python3 pseudosudoku.py --solve"})
        )
        self.assertNotIn("unbounded_sudo", _codes(response))


class MalformedInputTests(unittest.TestCase):
    def test_evaluation_survives_unparseable_text(self) -> None:
        for text in ("", "{", '{"type":"tool_use"', "{" * 500, '{"a":' * 200):
            with self.subTest(text=text[:20]):
                self.assertIsInstance(evaluate_rules("inbound", text), list)

    def test_a_truncated_stream_still_reaches_the_rules(self) -> None:
        stream = _streamed_tool_use("Bash", {"command": "pkill -f bouncer"}, (12,))
        truncated = stream[: stream.rindex("event: content_block_stop")]
        review = _extract_review_text(truncated, "text/event-stream")
        self.assertIn("bouncer_stop_attempt", _codes(review))


if __name__ == "__main__":
    unittest.main()
