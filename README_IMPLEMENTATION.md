# AI Agent Safety Package v1.0

Target: 13 learners can use Codex CLI, Claude Code, and Gemini CLI on real projects for three months with local detection, control, and logging.

This is a local gateway package, not a training-only demo. It uses four layers:

1. Safe launchers that force the correct working directory and config.
2. User/project hooks that fail closed.
3. Codex sandbox / Claude permissions / Gemini policy engine.
4. Doctor scripts that run attack drills.

## S1 Windows Claude Code Hooks

Files:

- `configs/claude/settings.windows.json`
- `scripts/windows/guard-bash.ps1`
- `scripts/windows/guard-write.ps1`
- `scripts/windows/guard-webfetch.ps1`
- `scripts/windows/guard-prompt.ps1`
- `scripts/windows/guard-post-output.ps1`

PowerShell 5.1 only. No jq. Every guard catches exceptions and exits `2`, which is the blocking exit path for Claude Code hook events. The settings file uses `powershell.exe` exec-form args, checks that the script exists, and exits `2` if it does not.

Guarantee: Bash tool requests, write/edit requests, WebFetch requests, user prompt submission, and output scans are blocked when they match policy. If Claude Code is launched without loading any settings, the launcher and optional global-settings install are the compensating controls.

3-day feasibility: yes.

v1.1: managed settings rollout for lab PCs if school policy allows it.

## S2 Codex CLI Sandbox

Files:

- `configs/codex/config.windows.toml`
- `configs/codex/config.mac.toml`
- `configs/codex/hooks.windows.json`
- `configs/codex/hooks.mac.json`
- `scripts/windows/launch-codex-safe.ps1`
- `scripts/macos/launch-codex-safe.sh`

Command shape:

```powershell
powershell -ExecutionPolicy Bypass -File .ai-safety\hooks\windows\launch-codex-safe.ps1 -Workspace C:\path\to\safe-workspace
```

The launcher uses `--sandbox workspace-write`, `--ask-for-approval never`, `--enable hooks`, and `windows.sandbox="unelevated"` for Admin-free school PCs. Network is disabled for shell commands. Doctor tests `codex sandbox windows` / `codex sandbox macos` directly.

Guarantee: model-generated shell commands run under Codex sandbox policy where supported. If a sandbox command does not block an attack, hook policy still blocks the same class before execution.

3-day feasibility: yes for local v1.0.

v1.1: add a version matrix per Codex release and a stricter managed config profile.

## S3 Local Central Gateway

Files:

- `policy/safety-policy.json`
- `scripts/windows/ai-gateway.ps1`
- `scripts/macos/ai-gateway.sh`
- all guard scripts

Chosen approach: B + A. Hooks are the primary gateway because they see interactive tool calls and prompt submissions. CLI wrappers add pre-filtering and correct launch settings.

Core functions:

- Logging: all allow/block decisions go to the local AI safety log folder.
- Masking: logs are redacted before write.
- Send-before block: user prompts, shell commands, write content, and WebFetch inputs are scanned before execution.
- Response scan: post-output hooks detect sensitive patterns in tool or AI output.

Guarantee: local detection, control, and records for CLI sessions launched with this package. It is not a network proxy for browser-only AI tools.

3-day feasibility: yes.

v1.1: local SQLite dashboard and teacher-side import.

## S4 User Input Filtering

Claude Code: `UserPromptSubmit` hook is used.

Codex CLI: `UserPromptSubmit` hook file is provided and the wrapper pre-filters non-interactive prompts.

Gemini CLI: `BeforeAgent`, `BeforeTool`, `AfterModel`, and `AfterAgent` hooks are used.

Guarantee: prompt text that flows through supported CLI hook events is scanned before the model sees it. Raw terminal paste into an unsupported future CLI mode is covered by the launcher preflight only if the CLI exposes stdin or hook events.

3-day feasibility: yes for current Claude/Codex/Gemini hook paths.

v1.1: terminal multiplexer capture for tools that do not expose prompt hooks.

## S5 Scope Enforcement

Files:

- `scripts/windows/install.ps1`
- `scripts/macos/install.sh`
- `workspace-template/AGENTS.md`
- `workspace-template/CLAUDE.md`
- `workspace-template/GEMINI.md`

The installer writes project configs under `.claude`, `.codex`, `.gemini`, plus `.ai-safety`. Launchers always set cwd/working root to the selected workspace.

Global Claude settings can be overwritten with backup using `-InstallGlobalClaudeSettings` on Windows or `--global-claude` on Mac.

Guarantee: launcher path enforces cwd. Project configs enforce workspace behavior. Optional global settings make basic defenses active outside the safe workspace too.

3-day feasibility: yes.

v1.1: signed marker file and startup banner that refuses unknown workspaces.

## S6 Update Tolerance

Files:

- `scripts/windows/update-safety.ps1`
- `scripts/macos/update-safety.sh`
- `scripts/windows/collect-status.ps1`
- `scripts/macos/collect-status.sh`

The update script backs up, reinstalls configs, and runs doctor. The status script records CLI versions and config presence for support.

Guarantee: config drift and hook breakage are detected by doctor. CLI schema changes are caught as doctor failures before real work continues.

3-day feasibility: yes.

v1.1: remote version catalog and automatic compatibility warnings.

## S7 macOS Seatbelt Compensation

Files:

- `configs/codex/config.mac.toml`
- `scripts/macos/launch-codex-safe.sh`
- `scripts/macos/guard-*.sh`
- `workspace-template/aiexclude.template`

Codex Seatbelt remains one layer. The package adds hooks, disabled shell network, excluded sensitive environment variables, a local AI exclude template, and `caffeinate` for stable long sessions.

Guarantee: common file exfiltration, shell network, forced delete, and generated protected-file read scripts are stopped before shell execution or file write.

3-day feasibility: yes.

v1.1: optional remote dev container or Codespaces profile for stronger isolation.

## S8 Attack Doctor

Files:

- `scripts/windows/doctor.ps1`
- `scripts/macos/doctor.sh`

Doctor drills:

1. Prompt and shell request to read protected local file.
2. Shell network command.
3. Scripted protected-file read.
4. Workspace-outside write.
5. Recursive forced delete.
6. Generated script with protected-file read.
7. Unauthorized WebFetch.

Guarantee: deterministic hook and sandbox drills run locally without depending on model behavior. Windows doctor also has `-LiveCodex` for a live Codex prompt drill.

3-day feasibility: yes.

v1.1: HTML report for learners and teacher import bundle.

## S9 Distribution And Operation

Files:

- `scripts/windows/install.ps1`
- `scripts/macos/install.sh`
- `scripts/windows/backup.ps1`
- `scripts/macos/backup.sh`
- `scripts/windows/restore.ps1`
- `scripts/macos/restore.sh`
- `scripts/windows/collect-status.ps1`
- `scripts/macos/collect-status.sh`

Install, update, backup, restore, diagnostics, and teacher status collection are included. Teacher remote check is intentionally file-based: learner runs `collect-status`, sends the generated text file, and no remote control agent is installed.

Guarantee: learners can self-diagnose and recover without Admin rights. Teacher can inspect versions, installed files, and recent log paths without collecting secrets.

3-day feasibility: yes.

v1.1: ZIP packager and one-click HTML launcher.
