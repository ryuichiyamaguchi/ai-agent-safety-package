import json
import unittest

from bouncer.engine import BouncerEngine
from bouncer.rules import evaluate_rules
from bouncer.types import AiAssessment


DOT_ENV = "." + "env"
SSH_DIR = "." + "ssh"
AWS_DIR = "." + "aws"
CONFIG_DIR = "." + "config"
PRIVATE_KEY_NAME = "id_" + "ed" + "25519"
AWS_AUTH_FILE = "creden" + "tials"
GH_AUTH_FILE = "hosts" + ".yml"


def _tool_use(name: str, input_value: dict[str, object]) -> str:
    return json.dumps(
        {"type": "tool_use", "name": name, "input": input_value},
        ensure_ascii=False,
        separators=(",", ":"),
    )


def _codes(text: str) -> set[str]:
    return {item.code for item in evaluate_rules("inbound", text)}


class _AllowingAi:
    def assess(self, direction, text, context=None):
        return AiAssessment(available=True, decision="allow", risk_score=0.01)

    def health(self):
        return {"available": True}


class TargetCentricRulesTests(unittest.TestCase):
    def test_env_access_is_caught_regardless_of_reader_command(self) -> None:
        for command in (
            f"base64 ~/{DOT_ENV}",
            f"xxd /workspace/{DOT_ENV}.production",
            f"cp /project/{DOT_ENV}.local /tmp/copy",
            f"ln -s /project/{DOT_ENV} /tmp/link",
        ):
            with self.subTest(command=command):
                self.assertIn(
                    "sensitive_env_file_access",
                    _codes(_tool_use("Bash", {"command": command})),
                )

    def test_private_files_are_critical(self) -> None:
        samples = (
            _tool_use(
                "Read",
                {"file_path": f"/Users/example/{SSH_DIR}/{PRIVATE_KEY_NAME}"},
            ),
            _tool_use(
                "Bash",
                {"command": f"cat ~/{AWS_DIR}/{AWS_AUTH_FILE}"},
            ),
            _tool_use(
                "Read",
                {"file_path": f"~/{CONFIG_DIR}/gh/{GH_AUTH_FILE}"},
            ),
        )
        for sample in samples:
            with self.subTest(sample=sample):
                findings = evaluate_rules("inbound", sample)
                matched = [
                    item
                    for item in findings
                    if item.code == "private_credential_file_access"
                ]
                self.assertEqual(len(matched), 1)
                self.assertEqual(matched[0].severity, "critical")

    def test_plain_documentation_mentions_do_not_trigger_tool_rules(self) -> None:
        text = f"READMEに{DOT_ENV}を読み込まない方針とSSH鍵の扱いを記載します。"
        codes = _codes(text)
        self.assertNotIn("sensitive_env_file_access", codes)
        self.assertNotIn("private_credential_file_access", codes)


class ProtectedOperationRulesTests(unittest.TestCase):
    def test_force_push_to_protected_branch_is_blocked(self) -> None:
        for raw_command in (
            "git push --force-with-lease origin main",
            "git push origin production --force",
            "git push -f origin master",
        ):
            with self.subTest(raw_command=raw_command):
                command = _tool_use("Bash", {"command": raw_command})
                self.assertIn("force_push_protected_branch", _codes(command))

    def test_normal_push_is_not_flagged_as_force_push(self) -> None:
        command = _tool_use("Bash", {"command": "git push origin feature/ui"})
        self.assertNotIn("force_push_protected_branch", _codes(command))

    def test_bouncer_core_edit_requires_human_review(self) -> None:
        core_file = "/workspace/" + "bouncer" + "/src/bouncer/" + "rules.py"
        edit = _tool_use(
            "Edit",
            {"file_path": core_file, "new_string": "RULES = ()"},
        )
        self.assertIn("bouncer_core_file_edit", _codes(edit))

    def test_read_only_bouncer_commands_are_not_self_protection_hits(self) -> None:
        read_command = "git log -- src/" + "bouncer/rules.py"
        command = _tool_use("Bash", {"command": read_command})
        codes = _codes(command)
        self.assertNotIn("bouncer_core_bash_write", codes)
        self.assertNotIn("bouncer_stop_attempt", codes)

    def test_bouncer_stop_and_safety_weakening_are_caught(self) -> None:
        stop = _tool_use("Bash", {"command": "pkill -f bouncer"})
        weaken = _tool_use(
            "Bash",
            {"command": "export BOUNCER_AI_FAILURE_MODE=rules; ./scripts/run-local.zsh"},
        )
        self.assertIn("bouncer_stop_attempt", _codes(stop))
        self.assertIn("bouncer_safety_weakening", _codes(weaken))

    def test_rule_severity_maps_to_expected_gateway_decision(self) -> None:
        engine = BouncerEngine(_AllowingAi())
        review_result, _ = engine.inspect(
            "inbound",
            _tool_use("Bash", {"command": f"base64 ~/{DOT_ENV}"}),
        )
        block_result, _ = engine.inspect(
            "inbound",
            _tool_use(
                "Read",
                {"file_path": f"/Users/example/{SSH_DIR}/{PRIVATE_KEY_NAME}"},
            ),
        )
        self.assertEqual(review_result.decision, "review")
        self.assertEqual(block_result.decision, "block")


if __name__ == "__main__":
    unittest.main()
