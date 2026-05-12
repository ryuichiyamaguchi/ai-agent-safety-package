#!/usr/bin/env bash
set -u
AI_SAFE_MODE="bash"
. "$(dirname "$0")/lib/safety_policy.sh"
read_hook_input
has_sensitive_text && block "sensitive pattern in shell command"
has_protected_path && block "protected path referenced in shell command"
has_dangerous_command && block "dangerous shell command matched"
allow "command passed policy"
