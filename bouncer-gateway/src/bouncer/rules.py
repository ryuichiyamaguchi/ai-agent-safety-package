from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass

from .types import Finding, Severity


@dataclass(frozen=True)
class Rule:
    code: str
    category: str
    severity: Severity
    summary: str
    regex: re.Pattern[str]
    directions: frozenset[str]


_TOOL_USE_PREFIX = r'(?is)"type"\s*:\s*"tool_use"[\s\S]{0,2400}'
_DOT_ENV_TARGET = (
    r'(?:^|[/\\\s"\'`:=])'
    + re.escape("." + "env")
    + r'(?:\.[A-Za-z0-9_-]+)?(?=$|[\s/\\"\'`:;,}\]])'
)
_PRIVATE_CREDENTIAL_TARGET = (
    r'(?:'
    + re.escape("." + "ssh")
    + r'[/\\](?:id_[A-Za-z0-9_-]+|[^\s/\\"\']*_(?:rsa|ed25519|ecdsa))'
    + r'|'
    + re.escape("." + "aws")
    + r'[/\\]credentials|'
    + re.escape("." + "config")
    + r'[/\\]gh[/\\](?:hosts\.yml|token))'
)


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
        "sensitive_env_file_access",
        "credential_access",
        "high",
        "環境変数ファイルへのツールアクセスを検出しました",
        re.compile(_TOOL_USE_PREFIX + _DOT_ENV_TARGET),
        frozenset({"inbound"}),
    ),
    Rule(
        "private_credential_file_access",
        "credential_access",
        "critical",
        "秘密鍵または認証情報ファイルへのツールアクセスを検出しました",
        re.compile(_TOOL_USE_PREFIX + _PRIVATE_CREDENTIAL_TARGET),
        frozenset({"inbound"}),
    ),
    Rule(
        "destructive_rm",
        "dangerous_action",
        "critical",
        "広範囲を削除し得るrmコマンドを検出しました",
        re.compile(
            r"(?i)\brm\s+(?:-[a-z]*r[a-z]*f|-rf|-fr)\s+"
            r"(?:/|~|\$HOME|\$\{HOME\}|/Users)(?=[\s/\"'`,}\]]|$)"
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
        "bouncer_core_file_edit",
        "self_protection",
        "high",
        "Bouncerの中核ファイルを変更するツール操作を検出しました",
        re.compile(
            r"(?is)\"type\"\s*:\s*\"tool_use\"\s*,\s*"
            r"\"name\"\s*:\s*\"(?:edit|write|multiedit|apply_patch)\""
            r"[\s\S]{0,3200}[/\\]bouncer[/\\](?:"
            r"src[/\\]bouncer[/\\](?:rules|engine|http_server|config|local_ai)\.py"
            r"|scripts[/\\]run-local\.zsh)"
        ),
        frozenset({"inbound"}),
    ),
    Rule(
        "bouncer_core_bash_write",
        "self_protection",
        "high",
        "Bouncerの中核ファイルを書き換えるコマンドを検出しました",
        re.compile(
            r"(?is)\"type\"\s*:\s*\"tool_use\"\s*,\s*"
            r"\"name\"\s*:\s*\"bash\"[\s\S]{0,1600}"
            r"(?:tee|cp|mv|install|rsync|dd\s+if|sed\s+-i|truncate|"
            r"(?:echo|printf)[^\n]{0,300}>{1,2})[\s\S]{0,1000}"
            r"[/\\]bouncer[/\\](?:src[/\\]bouncer[/\\]"
            r"(?:rules|engine|http_server|config|local_ai)\.py"
            r"|scripts[/\\]run-local\.zsh)"
        ),
        frozenset({"inbound"}),
    ),
    Rule(
        "bouncer_stop_attempt",
        "self_protection",
        "high",
        "Bouncerを停止するコマンドを検出しました",
        re.compile(
            r"(?is)\"type\"\s*:\s*\"tool_use\"\s*,\s*"
            r"\"name\"\s*:\s*\"bash\"[\s\S]{0,2400}(?:"
            r"\b(?:pkill|killall)\b[^\n]{0,180}\bbouncer\b"
            r"|\blsof\b[^\n]{0,180}(?::8787|TCP:8787)[^\n]{0,180}\b(?:kill|xargs)\b"
            r"|\blms\s+(?:server\s+stop|unload\s+bouncer-gemma)\b)"
        ),
        frozenset({"inbound"}),
    ),
    Rule(
        "bouncer_safety_weakening",
        "self_protection",
        "high",
        "Bouncerの安全設定を弱めるコマンドを検出しました",
        re.compile(
            r"(?is)\"type\"\s*:\s*\"tool_use\"\s*,\s*"
            r"\"name\"\s*:\s*\"bash\"[\s\S]{0,2400}(?:"
            r"BOUNCER_AI_ENABLED\s*=\s*(?:0|false|off)\b"
            r"|BOUNCER_REVIEW_MODE\s*=\s*pass\b"
            r"|BOUNCER_AI_FAILURE_MODE\s*=\s*rules\b)"
        ),
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


def evaluate_rules(direction: str, text: str) -> list[Finding]:
    findings: list[Finding] = []
    for rule in RULES:
        if direction not in rule.directions:
            continue
        match = rule.regex.search(text)
        if match is None:
            continue
        fingerprint = hashlib.sha256(match.group(0).encode("utf-8")).hexdigest()[:12]
        findings.append(
            Finding(
                code=rule.code,
                category=rule.category,
                severity=rule.severity,
                summary=rule.summary,
                fingerprint=fingerprint,
            )
        )
    return findings
