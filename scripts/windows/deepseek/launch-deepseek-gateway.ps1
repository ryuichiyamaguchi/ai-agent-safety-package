# launch-deepseek-gateway.ps1
# ds-gateway を起動し health 確認後に ANTHROPIC_BASE_URL をプロキシへ向け、
# ガード付き Claude Code を起動。終了時に gateway を確実停止（fail-closed）。
param([string]$Workspace = "$env:USERPROFILE\Documents\my-ai-workspace")

$ErrorActionPreference = 'Stop'
$hooks = Join-Path $Workspace '.ai-safety\hooks'
$gatewayJs = Join-Path $hooks 'common\ds-gateway.js'
$launchClaude = Join-Path $hooks 'windows\launch-claude-safe.ps1'
$port = if ($env:DS_GATEWAY_PORT) { $env:DS_GATEWAY_PORT } else { '8788' }

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
  Write-Host "送信検査 Gateway 稼働中 (127.0.0.1:$port)。DeepSeek へは検査後に転送されます。"
  & $launchClaude -Workspace $Workspace
} finally {
  if ($gw -and -not $gw.HasExited) { Stop-Process -Id $gw.Id -Force -ErrorAction SilentlyContinue }
}
