from __future__ import annotations

import argparse
import json
import sys

from .config import Config
from .engine import BouncerEngine
from .http_server import run_server
from .local_ai import LocalAiClient


def _build_engine(config: Config) -> BouncerEngine:
    return BouncerEngine(
        ai_client=LocalAiClient(
            base_url=config.lm_studio_base_url,
            model=config.lm_studio_model,
            timeout_seconds=config.ai_timeout_seconds,
            enabled=config.ai_enabled,
        ),
        fail_closed=config.ai_failure_mode == "block",
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Local-first LLM Bouncer")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("serve", help="start the local gateway")
    subparsers.add_parser("health", help="check LM Studio connectivity")
    inspect_parser = subparsers.add_parser("inspect", help="inspect text")
    inspect_parser.add_argument(
        "--direction", choices=["outbound", "inbound"], default="outbound"
    )
    inspect_parser.add_argument("--text", help="text to inspect; stdin when omitted")

    args = parser.parse_args()
    try:
        config = Config.from_env()
    except ValueError as exc:
        parser.error(str(exc))
    engine = _build_engine(config)

    if args.command == "serve":
        run_server(config, engine)
        return
    if args.command == "health":
        print(json.dumps(engine.ai_client.health(), ensure_ascii=False, indent=2))
        return
    if args.command == "inspect":
        text = args.text if args.text is not None else sys.stdin.read()
        result, _ = engine.inspect(args.direction, text)
        print(json.dumps(result.to_dict(), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
