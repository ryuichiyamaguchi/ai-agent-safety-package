#!/usr/bin/env bash
set -u
AI_SAFE_MODE="post-output"
. "$(dirname "$0")/lib/safety_policy.sh"
read_hook_input
. "$(dirname "$0")/lib/explainer.sh"
explain
has_sensitive_text && block "sensitive pattern in tool or AI output"
allow "output passed policy"
