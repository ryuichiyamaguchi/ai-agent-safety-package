# launch-deepseek-gateway.ps1
# ds-gateway を起動し health 確認後に ANTHROPIC_BASE_URL をプロキシへ向け、
# ガード付き Claude Code を起動。終了時に gateway を確実停止（fail-closed）。
param([string]$Workspace = "$env:USERPROFILE\Documents\my-ai-workspace")

$ErrorActionPreference = 'Stop'
$hooks = Join-Path $Workspace '.ai-safety\hooks'
$gatewayJs = Join-Path $hooks 'common\ds-gateway.js'
$launchClaude = Join-Path $hooks 'windows\launch-claude-safe.ps1'
$port = if ($env:DS_GATEWAY_PORT) { $env:DS_GATEWAY_PORT } else { '8788' }
# AI コーチ(モニター)に d-claude セッションを伝える目印(別プロセスなのでファイル方式)。
$coachLogDir = if ($env:AI_SAFE_LOG_DIR) { $env:AI_SAFE_LOG_DIR } else { Join-Path $env:USERPROFILE '.ai-safety\logs' }
$coachMarker = Join-Path $coachLogDir 'coach-engine'

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Host "[ERROR] node not found. Claude Code requires Node.js."; exit 1
}
if (-not (Test-Path $gatewayJs)) {
  Write-Host "[ERROR] ds-gateway.js not found: $gatewayJs"; exit 1
}
if (-not (Test-Path $launchClaude)) {
  Write-Host "[ERROR] launch-claude-safe.ps1 not found: $launchClaude"; exit 1
}

function Stop-StaleGateway {
  param([string]$Port, [string]$GatewayJs)

  $gatewayPath = (Resolve-Path -LiteralPath $GatewayJs).Path.Replace('/', '\').ToLowerInvariant()
  try {
    $listeners = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort ([int]$Port) -State Listen -ErrorAction SilentlyContinue
  } catch {
    $listeners = @()
  }

  foreach ($listener in @($listeners)) {
    $processId = $listener.OwningProcess
    if (-not $processId) { continue }
    try {
      $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop
    } catch {
      continue
    }
    $cmd = ([string]$proc.CommandLine).Replace('/', '\').ToLowerInvariant()
    if ($cmd.Contains($gatewayPath)) {
      Write-Host "Stopping stale DeepSeek Gateway process (PID: $processId)."
      Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
      Start-Sleep -Milliseconds 300
    }
  }
}

Stop-StaleGateway -Port $port -GatewayJs $gatewayJs

$env:DS_GATEWAY_PORT = $port
$gw = Start-Process node -ArgumentList @($gatewayJs) -PassThru -WindowStyle Hidden
try {
  $ok = $false
  for ($i = 0; $i -lt 50; $i++) {
    try {
      $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/healthz" -UseBasicParsing -TimeoutSec 1
      if ($r.Content -match '"status":"ok"') { $ok = $true; break }
    } catch { Start-Sleep -Milliseconds 100 }
  }
  if (-not $ok) {
    Write-Host "[ERROR] Gateway health check failed. Not launching without send-side inspection (fail-closed)."
    exit 1
  }
  # health OK かつ spawn した node が生存していれば、そのポートは確実に自プロセスのもの。
  # foreign process がポートを占有していれば自 node は bind 失敗で即終了している。
  if ($gw.HasExited) {
    Write-Host "[ERROR] Gateway process is not alive (port may be in use). Not launching without send-side inspection (fail-closed)."
    exit 1
  }
  $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:$port"
  # d-claude 経路の目印。launch-claude-safe.ps1 はこのフラグがあるとき
  # DeepSeek ルーティング env の Remove をスキップする (消すと not logged in になる)。
  $env:DS_CLAUDE_MODE = "1"
  # d-claude ではグレーコマンドの危険判定を独立した Gemini(2鍵)に任せて自律的に回す（自己審査回避）。
  # 両鍵 approve のときだけ自動許可、怪しければ人間に確認(fail-closed)。決定的 deny の底は不変。
  # judge は無条件で ON。PowerShell では [bool]"0"=True のため以前の弱いガード `if (-not $env:...)`
  # は残存 setx の "0" を上書きできず judge が黙って OFF になり得た（opt-out 撤廃）。
  # 無効化は残存値では起きない別 env を明示指定したときだけ（既定は必ず judge ON）。
  if ($env:AI_SAFE_ASSISTED_APPROVAL_OPTOUT -eq "1") {
    $env:AI_SAFE_ASSISTED_APPROVAL = "0"
  } else {
    $env:AI_SAFE_ASSISTED_APPROVAL = "1"
  }
  # モニターへ d-claude 目印を置く（AI コーチが Gemini へコマンド本文を送らないように）。
  try { New-Item -ItemType Directory -Force -Path $coachLogDir | Out-Null; Set-Content -NoNewline -Encoding ascii -LiteralPath $coachMarker -Value 'd-claude' } catch {}
  Write-Host "送信検査 Gateway 稼働中 (127.0.0.1:$port)。DeepSeek へは検査後に転送されます。"
  & $launchClaude -Workspace $Workspace
} finally {
  if ($gw -and -not $gw.HasExited) { Stop-Process -Id $gw.Id -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $coachMarker -Force -ErrorAction SilentlyContinue
}
