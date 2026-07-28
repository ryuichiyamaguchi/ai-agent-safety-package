from __future__ import annotations

import hashlib
import json
import re
from collections.abc import Iterator
from dataclasses import dataclass
from typing import Any

from .types import Finding, Severity


@dataclass(frozen=True)
class Rule:
    """A rule evaluated against the whole reviewed text."""

    code: str
    category: str
    severity: Severity
    summary: str
    regex: re.Pattern[str]
    directions: frozenset[str]


@dataclass(frozen=True)
class ToolRule:
    """A rule evaluated against a single tool call rather than the raw text.

    ``tool_names`` of ``None`` matches any tool. Every pattern in ``patterns``
    must match the same tool call payload for the rule to fire.
    """

    code: str
    category: str
    severity: Severity
    summary: str
    tool_names: frozenset[str] | None
    patterns: tuple[re.Pattern[str], ...]
    directions: frozenset[str]


_DOT_ENV_TARGET = re.compile(
    r'(?is)(?:^|[/\\\s"\'`:=])'
    + re.escape("." + "env")
    + r'(?:\.[A-Za-z0-9_-]+)?(?=$|[\s/\\"\'`:;,}\]])'
)
_PRIVATE_CREDENTIAL_TARGET = re.compile(
    r'(?is)(?:'
    + re.escape("." + "ssh")
    + r'[/\\](?:id_[A-Za-z0-9_-]+|[^\s/\\"\']*_(?:rsa|ed25519|ecdsa))'
    + r'|'
    + re.escape("." + "aws")
    + r'[/\\]credentials|'
    + re.escape("." + "config")
    + r'[/\\]gh[/\\](?:hosts\.yml|token))'
)

_BOUNCER_CORE_PATH = re.compile(
    r"(?is)[/\\]bouncer[/\\](?:"
    r"src[/\\]bouncer[/\\](?:rules|engine|http_server|config|local_ai)\.py"
    r"|scripts[/\\]run-local\.zsh)"
)
_SHELL_WRITE_COMMAND = re.compile(
    r"(?is)\b(?:tee|cp|mv|install|rsync|truncate)\b"
    r"|\bdd\s+if\b"
    r"|\bsed\s+-i\b"
    r"|(?:echo|printf)[^\n]{0,300}>{1,2}"
    r"|>{1,2}\s*[^\s|;&]*[/\\]bouncer[/\\]"
)
_BOUNCER_STOP_COMMAND = re.compile(
    r"(?is)\b(?:pkill|killall)\b[^\n]{0,180}\bbouncer\b"
    r"|\blsof\b[^\n]{0,180}(?::8787|TCP:8787)[^\n]{0,180}\b(?:kill|xargs)\b"
    r"|\blms\s+(?:server\s+stop|unload\s+bouncer-gemma)\b"
)
_BOUNCER_SAFETY_WEAKENING = re.compile(
    r"(?is)BOUNCER_AI_ENABLED\s*=\s*(?:0|false|off)\b"
    r"|BOUNCER_REVIEW_MODE\s*=\s*pass\b"
    r"|BOUNCER_AI_FAILURE_MODE\s*=\s*rules\b"
)
# A quoted JSON fragment gives no real line start, so treat the surrounding
# quote and the escaped newline as command separators as well.
_SUDO_IN_TOOL_CALL = re.compile(r"""(?i)(?:^|[\n;&|(`"']|\\n)\s*sudo\s+""")

_EDIT_TOOL_NAMES = frozenset(
    {
        "edit",
        "write",
        "multiedit",
        "apply_patch",
        "notebookedit",
        "create_file",
        "str_replace_editor",
        "str_replace_based_edit_tool",
    }
)
_SHELL_TOOL_NAMES = frozenset(
    {
        "bash",
        "shell",
        "sh",
        "zsh",
        "powershell",
        "terminal",
        "run_command",
        "execute_command",
    }
)

# `rm` is only dangerous here when both a recursive and a force flag are
# present, so each is required through its own lookahead over the flag run.
_RM_FLAG_RUN = r"(?:\s+-{1,2}[A-Za-z][A-Za-z-]*)"
_RM_RECURSIVE_FLAG = r"(?:\s+(?:-[A-Za-z]*r[A-Za-z]*|--recursive))\b"
_RM_FORCE_FLAG = r"(?:\s+(?:-[A-Za-z]*f[A-Za-z]*|--force))\b"
# The quote may arrive backslash-escaped because the command is inside JSON.
_RM_TARGET = r"(?:\\?[\"'])?(?:/|~|\$HOME|\$\{HOME\}|%USERPROFILE%|/Users)"
_RM_TARGET_END = r"(?=[\s/\\\"'`,;:}\]*]|$)"


RULES: tuple[Rule, ...] = (
    Rule(
        "prompt_injection_phrase",
        "prompt_injection",
        "medium",
        "プロンプトインジェクションで頻出する命令表現を検出しました",
        re.compile(
            r"(?i)(ignore|disregard|forget)\s+(all\s+)?(previous|prior|above)\s+"
            r"(instructions?|messages?|rules?)|system\s+prompt\s*(?:is|:)|developer\s+message\s*(?:is|:)"
        ),
        frozenset({"outbound", "inbound"}),
    ),
    Rule(
        "pipe_to_shell",
        "dangerous_action",
        "critical",
        "ダウンロード内容を直接シェル実行する提案を検出しました",
        re.compile(r"(?i)\b(?:curl|wget)\b[^\n|]{0,500}\|\s*(?:sudo\s+)?(?:sh|bash|zsh)\b"),
        frozenset({"inbound"}),
    ),
    Rule(
        "destructive_rm",
        "dangerous_action",
        "critical",
        "広範囲を削除し得るrmコマンドを検出しました",
        re.compile(
            r"(?i)\brm"
            r"(?=" + _RM_FLAG_RUN + r"*" + _RM_RECURSIVE_FLAG + r")"
            r"(?=" + _RM_FLAG_RUN + r"*" + _RM_FORCE_FLAG + r")"
            + _RM_FLAG_RUN + r"+\s+" + _RM_TARGET + _RM_TARGET_END
        ),
        frozenset({"inbound"}),
    ),
    Rule(
        "force_push_protected_branch",
        "dangerous_action",
        "critical",
        "保護対象ブランチへのforce pushを検出しました",
        re.compile(
            r"(?i)\bgit\s+push\b"
            r"(?=[^\n]{0,640}(?:--force(?:-with-lease)?|-f)\b)"
            r"(?=[^\n]{0,640}(?:\bmain\b|\bmaster\b|\bproduction\b))"
            r"[^\n]{0,640}"
        ),
        frozenset({"inbound"}),
    ),
    Rule(
        "git_hard_reset",
        "dangerous_action",
        "high",
        "復元困難なGitリセットを検出しました",
        re.compile(r"(?i)\bgit\s+reset\s+--hard\b"),
        frozenset({"inbound"}),
    ),
    Rule(
        "git_clean_force",
        "dangerous_action",
        "high",
        "未追跡ファイルを削除するGit cleanを検出しました",
        re.compile(r"(?i)\bgit\s+clean\s+-[a-z]*f[a-z]*\b"),
        frozenset({"inbound"}),
    ),
    Rule(
        "filesystem_format",
        "dangerous_action",
        "critical",
        "ファイルシステムを初期化し得るコマンドを検出しました",
        re.compile(r"(?i)\b(?:mkfs(?:\.[a-z0-9]+)?|diskutil\s+eraseDisk)\b"),
        frozenset({"inbound"}),
    ),
    Rule(
        "recursive_world_writable",
        "dangerous_action",
        "high",
        "再帰的な全権限付与を検出しました",
        re.compile(r"(?i)\bchmod\s+(?:-[a-z]*R[a-z]*\s+|--recursive\s+)?777\b"),
        frozenset({"inbound"}),
    ),
    Rule(
        "persistence_change",
        "persistence",
        "high",
        "自動起動や永続化に関わる変更を検出しました",
        re.compile(r"(?i)\b(?:launchctl\s+(?:load|bootstrap)|crontab\s+-|systemctl\s+enable)\b"),
        frozenset({"inbound"}),
    ),
    Rule(
        "unbounded_sudo",
        "privilege_escalation",
        "high",
        "管理者権限を使う操作を検出しました",
        re.compile(r"(?i)(?:^|[\n;&|])\s*sudo\s+"),
        frozenset({"inbound"}),
    ),
)


TOOL_RULES: tuple[ToolRule, ...] = (
    ToolRule(
        "sensitive_env_file_access",
        "credential_access",
        "high",
        "環境変数ファイルへのツールアクセスを検出しました",
        None,
        (_DOT_ENV_TARGET,),
        frozenset({"inbound"}),
    ),
    ToolRule(
        "private_credential_file_access",
        "credential_access",
        "critical",
        "秘密鍵または認証情報ファイルへのツールアクセスを検出しました",
        None,
        (_PRIVATE_CREDENTIAL_TARGET,),
        frozenset({"inbound"}),
    ),
    ToolRule(
        "bouncer_core_file_edit",
        "self_protection",
        "high",
        "Bouncerの中核ファイルを変更するツール操作を検出しました",
        _EDIT_TOOL_NAMES,
        (_BOUNCER_CORE_PATH,),
        frozenset({"inbound"}),
    ),
    ToolRule(
        "bouncer_core_bash_write",
        "self_protection",
        "high",
        "Bouncerの中核ファイルを書き換えるコマンドを検出しました",
        _SHELL_TOOL_NAMES,
        (_SHELL_WRITE_COMMAND, _BOUNCER_CORE_PATH),
        frozenset({"inbound"}),
    ),
    ToolRule(
        "bouncer_stop_attempt",
        "self_protection",
        "high",
        "Bouncerを停止するコマンドを検出しました",
        _SHELL_TOOL_NAMES,
        (_BOUNCER_STOP_COMMAND,),
        frozenset({"inbound"}),
    ),
    ToolRule(
        "bouncer_safety_weakening",
        "self_protection",
        "high",
        "Bouncerの安全設定を弱めるコマンドを検出しました",
        _SHELL_TOOL_NAMES,
        (_BOUNCER_SAFETY_WEAKENING,),
        frozenset({"inbound"}),
    ),
    ToolRule(
        "unbounded_sudo",
        "privilege_escalation",
        "high",
        "管理者権限を使う操作を検出しました",
        None,
        (_SUDO_IN_TOOL_CALL,),
        frozenset({"inbound"}),
    ),
)


_MAX_STRUCTURAL_SCAN = 400_000
_MAX_DECODE_ATTEMPTS = 4000
_MAX_WALK_DEPTH = 24
_TOOL_WINDOW_LIMIT = 4000

_TOOL_USE_MARKER = re.compile(r'(?is)"type"\s*:\s*"tool_use"')
_CONTENT_BLOCK_BOUNDARY = re.compile(
    r'(?is)"type"\s*:\s*"(?:text|thinking|redacted_thinking|tool_use|tool_result)"'
)
_NAME_FIELD = re.compile(r'(?is)"name"\s*:\s*"([A-Za-z0-9_.\-]+)"')


def _iter_embedded_objects(text: str) -> Iterator[Any]:
    """Yield every JSON object that can be decoded out of ``text``.

    The reviewed text is a concatenation of whole responses and streamed
    fragments, so it is rarely a single valid JSON document.
    """
    decoder = json.JSONDecoder()
    limit = min(len(text), _MAX_STRUCTURAL_SCAN)
    index = 0
    attempts = 0
    while index < limit and attempts < _MAX_DECODE_ATTEMPTS:
        start = text.find("{", index)
        if start < 0 or start >= limit:
            return
        attempts += 1
        try:
            value, end = decoder.raw_decode(text, start)
        except ValueError:
            index = start + 1
            continue
        yield value
        index = max(end, start + 1)


def _collect_tool_uses(value: Any, found: list[dict[str, Any]], depth: int = 0) -> None:
    if depth > _MAX_WALK_DEPTH:
        return
    if isinstance(value, dict):
        if value.get("type") == "tool_use":
            found.append(value)
        for item in value.values():
            _collect_tool_uses(item, found, depth + 1)
    elif isinstance(value, list):
        for item in value:
            _collect_tool_uses(item, found, depth + 1)


def _collect_strings(value: Any, out: list[str], depth: int = 0) -> None:
    if depth > _MAX_WALK_DEPTH:
        return
    if isinstance(value, str):
        out.append(value)
    elif isinstance(value, list):
        for item in value:
            _collect_strings(item, out, depth + 1)
    elif isinstance(value, dict):
        for item in value.values():
            _collect_strings(item, out, depth + 1)


def _structural_tool_calls(text: str) -> list[tuple[str | None, str]]:
    """Tool calls recovered by really parsing JSON, not by matching its shape."""
    calls: list[tuple[str | None, str]] = []
    for value in _iter_embedded_objects(text):
        blocks: list[dict[str, Any]] = []
        _collect_tool_uses(value, blocks)
        for block in blocks:
            raw_name = block.get("name")
            name = raw_name.lower() if isinstance(raw_name, str) else None
            strings: list[str] = []
            _collect_strings(block.get("input"), strings)
            calls.append((name, "\n".join(strings)))
    return calls


def _fragment_tool_calls(text: str) -> list[tuple[str | None, str]]:
    """Fallback for streamed fragments that cannot be parsed as JSON.

    The window stops at the next content block so a later text block cannot be
    mistaken for the tool input, and no key ordering is assumed.
    """
    windows: list[tuple[str | None, str]] = []
    for marker in _TOOL_USE_MARKER.finditer(text):
        end = min(len(text), marker.start() + _TOOL_WINDOW_LIMIT)
        boundary = _CONTENT_BLOCK_BOUNDARY.search(text, marker.end())
        if boundary is not None:
            end = min(end, boundary.start())
        window = text[marker.start() : end]
        name_match = _NAME_FIELD.search(window)
        name = name_match.group(1).lower() if name_match is not None else None
        windows.append((name, window))
    return windows


def _tool_rule_evidence(rule: ToolRule, name: str | None, payload: str) -> str | None:
    # An unreadable tool name is treated as a possible match (fail-closed).
    if rule.tool_names is not None and name is not None and name not in rule.tool_names:
        return None
    evidence: str | None = None
    for pattern in rule.patterns:
        match = pattern.search(payload)
        if match is None:
            return None
        if evidence is None:
            evidence = match.group(0)
    return evidence


def evaluate_rules(direction: str, text: str) -> list[Finding]:
    findings: list[Finding] = []
    seen: set[str] = set()

    def add(
        code: str, category: str, severity: Severity, summary: str, evidence: str
    ) -> None:
        if code in seen:
            return
        seen.add(code)
        fingerprint = hashlib.sha256(evidence.encode("utf-8")).hexdigest()[:12]
        findings.append(
            Finding(
                code=code,
                category=category,
                severity=severity,
                summary=summary,
                fingerprint=fingerprint,
            )
        )

    for rule in RULES:
        if direction not in rule.directions:
            continue
        match = rule.regex.search(text)
        if match is None:
            continue
        add(rule.code, rule.category, rule.severity, rule.summary, match.group(0))

    tool_rules = [rule for rule in TOOL_RULES if direction in rule.directions]
    if not tool_rules:
        return findings

    calls = _structural_tool_calls(text) + _fragment_tool_calls(text)
    for rule in tool_rules:
        if rule.code in seen:
            continue
        for name, payload in calls:
            evidence = _tool_rule_evidence(rule, name, payload)
            if evidence is None:
                continue
            add(rule.code, rule.category, rule.severity, rule.summary, evidence)
            break
    return findings
