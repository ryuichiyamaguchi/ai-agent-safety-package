# hook-trust.test.ps1 — launch-codex-safe.ps1 が codex 0.135+ の「未信頼フックは
# 黙ってスキップ」仕様に対し、同梱 guard フックの trusted_hash を safe.config.toml の
# [hooks.state] に自動注入することを検証する (mac hook-trust.test.sh のミラー)。
# 注: trusted_hash のキー内パス区切り (\ か /) は実機 codex の書式に依存するため、
#     ここでは「5 エントリ注入・既知ハッシュ含む・hooks.json 無しなら注入しない」を検証する。
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$launch = Join-Path $here '..\launch-codex-safe.ps1'
$script:pass = 0; $script:fail = 0
function Ok($m){ Write-Host "PASS $m"; $script:pass++ }
function Ng($m){ Write-Host "FAIL $m"; $script:fail++ }

$ws = Join-Path ([System.IO.Path]::GetTempPath()) ("ws-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $ws '.ai-safety\policy') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $ws '.codex') -Force | Out-Null
'{}' | Set-Content (Join-Path $ws '.ai-safety\policy\safety-policy.json')
'sandbox_mode = "workspace-write"' | Set-Content (Join-Path $ws '.codex\config.toml')
'sandbox_mode = "workspace-write"' | Set-Content (Join-Path $ws '.codex\safe.config.toml')
'{}' | Set-Content (Join-Path $ws '.codex\hooks.json')

$tmphome = Join-Path ([System.IO.Path]::GetTempPath()) ("home-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmphome -Force | Out-Null
$env:HOME = $tmphome; $env:USERPROFILE = $tmphome; $env:AI_SAFE_DRY_RUN = '1'

& pwsh -NoProfile -File $launch -Workspace $ws *> $null 2>$null
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $launch -Workspace $ws *> $null 2>$null
}
$sp = Join-Path $tmphome '.codex-safe\safe.config.toml'

if (Test-Path $sp) {
    $c = Get-Content $sp -Raw
    $n = ([regex]::Matches($c, 'trusted_hash')).Count
    if ($n -eq 5) { Ok "5 hook trust entries injected" } else { Ng "5 hook trust entries injected (got $n)" }
    if ($c -match '7cd5817d3031a107271994456a15b400232360984668dd261559283b75bb9780') { Ok 'guard-bash trusted_hash present' } else { Ng 'guard-bash trusted_hash present' }
    if ($c -match 'a254ae6612f7de19f6342536d0cc57699d2e345e6f0ad01bc899811caf951407') { Ok 'user_prompt_submit trusted_hash present' } else { Ng 'user_prompt_submit trusted_hash present' }
    if ($c -match 'hooks\.json:pre_tool_use:0:0') { Ok 'key uses hooks.json path' } else { Ng 'key uses hooks.json path' }
} else { Ng "safe.config.toml not produced at $sp" }

# 回帰: hooks.json が無ければ注入しない
Remove-Item (Join-Path $ws '.codex\hooks.json') -Force
Remove-Item $sp -Force -ErrorAction SilentlyContinue
& pwsh -NoProfile -File $launch -Workspace $ws *> $null 2>$null
if (Test-Path $sp) {
    $c2 = Get-Content $sp -Raw
    $n2 = ([regex]::Matches($c2, 'trusted_hash')).Count
    if ($n2 -eq 0) { Ok 'no injection without hooks.json' } else { Ng "no injection without hooks.json (got $n2)" }
} else { Ok 'no injection without hooks.json' }

Remove-Item Env:\AI_SAFE_DRY_RUN -ErrorAction SilentlyContinue
Remove-Item $tmphome, $ws -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "hook-trust.test summary: pass=$script:pass fail=$script:fail"
if ($script:fail -ne 0) { exit 1 } else { exit 0 }
