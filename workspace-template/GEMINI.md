# Gemini CLI Safety Rules

Use `.gemini/settings.json` and `.gemini/policies/safety.toml`.

Do not use YOLO mode for learner work. Use `--approval-mode default` with the safety policy loaded.

The local hooks log prompts, tool requests, and blocked events to the local AI safety log folder.
