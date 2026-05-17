#!/usr/bin/env bash
set -u
AI_SAFE_MODE="write"
. "$(dirname "$0")/lib/safety_policy.sh"
read_hook_input
. "$(dirname "$0")/lib/explainer.sh"
explain
has_sensitive_text && block "sensitive pattern in generated file"
has_protected_path && block "protected path referenced in generated file"
has_generated_code_risk && block "generated code contains blocked read or exfil pattern"
has_dangerous_command && block "generated content embeds dangerous command"
printf '%s' "$RAW_INPUT" | grep -E -q '"file_path"[[:space:]]*:[[:space:]]*"[.][.]' && block "write outside workspace"
allow "write passed policy"
