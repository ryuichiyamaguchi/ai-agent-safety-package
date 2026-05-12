# Claude Code Safety Rules

Use the project `.claude/settings.json` loaded by the safe launcher.

The hooks in `.ai-safety/hooks/` are part of the safety boundary. If a hook is missing, broken, or returns an error, treat the session as unsafe and stop.

Do not read protected dot files, private access folders, or files outside the workspace. Do not generate scripts that read protected local files or send local content to external endpoints.
