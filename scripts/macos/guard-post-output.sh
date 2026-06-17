#!/usr/bin/env bash
set -u
AI_SAFE_MODE="post-output"
. "$(dirname "$0")/lib/safety_policy.sh"
read_hook_input
. "$(dirname "$0")/lib/explainer.sh"
# 注: post-output はカードを書かない。書くと、ターン終了の Stop イベントで直前の
# コマンドカードを汎用カード(「AI の出力を確認しています」)で上書きし、シェルコマンドが
# モニターに残らなくなる。検査(下の block/allow)は維持。
# 出力側は outputSecretRegex（本物のキー書式のみ。Generic sensitive assignment は除外）で
# 検査する。汎用代入パターンで技術出力全体が誤ブロックされる over-blocking を回避する。
# 入力側(guard-bash/guard-write の has_sensitive_text)は secretRegex 全体のまま不変。
has_sensitive_output_text && block "sensitive pattern in tool or AI output"
allow "output passed policy"
