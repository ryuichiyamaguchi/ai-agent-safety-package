#!/usr/bin/env bash
set -u
AI_SAFE_MODE="prompt"
. "$(dirname "$0")/lib/safety_policy.sh"
read_hook_input
. "$(dirname "$0")/lib/explainer.sh"
explain
has_sensitive_text && block "sensitive pattern in user input"
has_protected_path && block "user input asks for or contains protected path"
has_dangerous_command && block "user input contains a blocked command pattern"
allow "prompt passed policy"
