# launch-deepseek-gateway.ps1
# ds-gateway を起動し health 確認後に ANTHROPIC_BASE_URL をプロキシへ向け、
# ガード付き Claude Code を起動。終了時に gateway を確実停止（fail-closed）。
param([string]$Workspace = "$env:USERPROFILE\Documents\my-ai-workspace")

$ErrorActionPreference = 'Stop'
$hooks = Join-Path $Workspace '.ai-safety\hooks'
$gatewayJs = Join-Path $hooks 'common\ds-gateway.js'
$gatewayTokenJs = Join-Path $hooks 'common\gateway-token.js'
$launchClaude = Join-Path $hooks 'windows\launch-claude-safe.ps1'
$port = if ($env:DS_GATEWAY_PORT) { $env:DS_GATEWAY_PORT } else { '8788' }
$keyFile = Join-Path $env:USERPROFILE '.deepseek-claude\auth'
# AI コーチ(モニター)に d-claude セッションを伝える目印(別プロセスなのでファイル方式)。
$coachLogDir = if ($env:AI_SAFE_LOG_DIR) { $env:AI_SAFE_LOG_DIR } else { Join-Path $env:USERPROFILE '.ai-safety\logs' }
$coachMarker = Join-Path $coachLogDir 'coach-engine'
# 秘密の解決（順序は全箇所共通: 環境変数 → OS の金庫(DPAPI) → 旧平文）。
# DPAPI の復号は PowerShell 5.1 でも動く Marshal 経由で書く
# （ConvertFrom-SecureString -AsPlainText は PowerShell 7.0 以降なので使わない）。
# 金庫に入っている値は "v1:" + base64(UTF-8) の封筒に包んである。
function Read-AiSafeSecret {
  param([string]$DpapiName, [string]$EnvName, [string]$LegacyFile)
  if ($EnvName) {
    $v = [Environment]::GetEnvironmentVariable($EnvName)
    if ($v -and $v.Trim()) { return $v.Trim() }
  }
  $p = Join-Path $env:USERPROFILE (Join-Path '.ai-safety' $DpapiName)
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    try {
      $ss = ConvertTo-SecureString ((Get-Content -LiteralPath $p -Raw).Trim())
      $b = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
      if ($b.StartsWith('v1:')) { $b = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b.Substring(3))) }
      if ($b -and $b.Trim()) { return $b.Trim() }
    } catch { }
  }
  if ($LegacyFile -and (Test-Path -LiteralPath $LegacyFile -PathType Leaf)) {
    $t = ([System.IO.File]::ReadAllText($LegacyFile)).Trim()
    if ($t) { return $t }
  }
  return ''
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Host "[ERROR] node not found. Claude Code requires Node.js."; exit 1
}
if (-not (Test-Path $gatewayJs)) {
  Write-Host "[ERROR] ds-gateway.js not found: $gatewayJs"; exit 1
}
if (-not (Test-Path $gatewayTokenJs)) {
  Write-Host "[ERROR] gateway-token.js not found: $gatewayTokenJs"; exit 1
}
if (-not (Test-Path $launchClaude)) {
  Write-Host "[ERROR] launch-claude-safe.ps1 not found: $launchClaude"; exit 1
}
# 実キーは Gateway 子プロセスだけが読む (Claude Code 側には渡さない) ので、ここで解決して確かめる。
# 順序は「環境変数 → 金庫(deepseek.dpapi) → 旧平文 .deepseek-claude\auth」。
$dsKey = Read-AiSafeSecret -DpapiName 'deepseek.dpapi' -EnvName 'DEEPSEEK_API_KEY' -LegacyFile $keyFile
if (-not $dsKey) {
  Write-Host "【エラー】DeepSeek APIキーが未登録です。"
  Write-Host "  先に「登録-初回だけ」を実行してから、もう一度起動してください。"
  exit 1
}

# 呼び出し元認証の合言葉は、この PC の共有ファイル (実キーと同じ置き場) から取る。
# 127.0.0.1 で待つだけでは同一 PC の任意プロセスや DNS リバインディングを踏んだブラウザから
# 叩けてしまうため、合言葉自体は必須のまま。以前は起動ごとに採番していたが、それだと
# OpenCode と d-claude を併用したときに後発が先発の gateway を殺し、先に開いていた窓が
# 古い合言葉のまま 401 になっていたので、PC 単位の共有に変えた。
# コマンドライン引数には載せない (プロセス一覧に出るため)。標準出力で受け取る。
$gatewayToken = (& node $gatewayTokenJs '--ensure' '--gateway' $gatewayJs | Out-String).Trim()
if (-not $gatewayToken) {
  Write-Host "【エラー】Gateway の合言葉を用意できませんでした (fail-closed)。"; exit 1
}

# gateway の出力はログへ。listen 行の pid 照合に使うほか、受講者の画面を汚さない。
New-Item -ItemType Directory -Force -Path $coachLogDir | Out-Null
$gatewayLog = Join-Path $coachLogDir 'deepseek-gateway.log'

# そのポートを握っているのが「自分たちの ds-gateway.js」かを、実行中のコマンドラインで確かめる。
# 見つからなければ 0 を返す (＝再利用しない)。
function Get-OurGatewayPid {
  param([string]$Port, [string]$GatewayJs)

  $gatewayPath = (Resolve-Path -LiteralPath $GatewayJs).Path.Replace('/', '\').ToLowerInvariant()
  try {
    $listeners = @(Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort ([int]$Port) -State Listen -ErrorAction SilentlyContinue)
  } catch {
    $listeners = @()
  }
  foreach ($listener in $listeners) {
    $processId = $listener.OwningProcess
    if (-not $processId) { continue }
    try {
      $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop
    } catch {
      continue
    }
    $cmd = ([string]$proc.CommandLine).Replace('/', '\').ToLowerInvariant()
    if ($cmd.Contains($gatewayPath)) { return [int]$processId }
  }
  return 0
}

# 稼働中の gateway をそのまま使えるかを判定する (生きている＋中身が今と同じ)。
function Test-GatewayReusable {
  param([string]$Port, [string]$GatewayJs, [string]$GatewayTokenJs)
  if ((Get-OurGatewayPid -Port $Port -GatewayJs $GatewayJs) -le 0) { return $false }
  & node $GatewayTokenJs '--probe' '--gateway' $GatewayJs '--port' $Port 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
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

# 使うポートを決める。DS_GATEWAY_PORT で明示指定されたときはその 1 つだけを使い (利用者の
# 意図を尊重し、黙って別のポートへ逃げない)、未指定なら既定 8788 から順に空きを探す。
# 8788 が他のプログラム (別プロジェクトの常駐サービス等) に取られている PC があるため。
if ($env:DS_GATEWAY_PORT) { $portCandidates = @($env:DS_GATEWAY_PORT) } else { $portCandidates = @(8788..8797) }

# 既に動いている gateway が「自分たちのプロセス」かつ「中身が今と同じ」なら、そのまま使う。
# どのポートで動いているかは gateway 自身が合言葉ファイルへ記録しているのでそれを見る。
$gw = $null
$gatewayReused = $false
$port = $null
$recordedPort = (& node $gatewayTokenJs '--recorded-port' | Out-String).Trim()
if ($recordedPort -and (Test-GatewayReusable -Port $recordedPort -GatewayJs $gatewayJs -GatewayTokenJs $gatewayTokenJs)) {
  $port = $recordedPort
  $gatewayReused = $true
  Write-Host "稼働中の送信検査 Gateway をそのまま使います (127.0.0.1:$port)。"
}

# 再利用できないときは、候補ポートを順に試して自分で立てる。
if (-not $gatewayReused) {
  foreach ($candidate in $portCandidates) {
    # 自分たちの gateway が中身違い (更新後に古いものが居座っている) で居るなら止める。
    Stop-StaleGateway -Port $candidate -GatewayJs $gatewayJs
    $env:DS_GATEWAY_PORT = $candidate
    # 実キーと合言葉は gateway 子プロセスにだけ渡し、spawn 後は自分の環境から消す。
    $env:DS_GATEWAY_TOKEN = $gatewayToken
    # ファイルパスではなく値そのものを渡すので、金庫にしまった鍵でもそのまま動く。
    $env:DEEPSEEK_API_KEY = $dsKey
    $gw = Start-Process node -ArgumentList @($gatewayJs) -PassThru -WindowStyle Hidden -RedirectStandardOutput $gatewayLog -RedirectStandardError "$gatewayLog.err"
    Remove-Item Env:\DS_GATEWAY_TOKEN, Env:\DEEPSEEK_API_KEY -ErrorAction SilentlyContinue

    # healthz の応答だけで判断してはいけない。ポートが他に取られていた場合、自分の gateway は
    # bind に失敗して終了するが、その同じポートで「別の gateway」(例: 別ワークスペースから
    # 起動されたもの) が動いていると healthz は正常に応答する。それを自分のものと取り違えると、
    # 別の検査設定を通って通信することになる。gateway が listen 直後に出す
    #   listening on 127.0.0.1:<port> pid=<pid>
    # の pid を照合すれば、そのポートで listen しているのが自分の gateway だと確定できる。
    $ok = $false
    $listenMark = "listening on 127.0.0.1:$candidate pid=$($gw.Id)"
    for ($i = 0; $i -lt 50; $i++) {
      if ($gw -and $gw.HasExited) { break }
      $listened = $false
      try {
        foreach ($line in @(Get-Content -LiteralPath $gatewayLog -ErrorAction Stop)) {
          if ([string]$line -eq '') { continue }
          if (([string]$line).StartsWith($listenMark)) { $listened = $true; break }
        }
      } catch {}
      if ($listened) {
        try {
          $r = Invoke-WebRequest -Uri "http://127.0.0.1:$candidate/healthz" -UseBasicParsing -TimeoutSec 1
          if ($r.Content -match '"status":"ok"') { $ok = $true }
        } catch {}
        break
      }
      Start-Sleep -Milliseconds 100
    }
    if ($ok -and $gw -and -not $gw.HasExited) {
      $port = $candidate
      if ("$port" -ne '8788') {
        Write-Host "ポート 8788 は他のプログラムが使っていたため、送信検査 Gateway は 127.0.0.1:$port で動かします。"
      }
      break
    }
    # 窓を二つ同時に開いてポートを取り合い、こちらが負けた可能性がある。
    # 相手が正しい gateway なら、それをそのまま使って続行する。
    if (Test-GatewayReusable -Port $candidate -GatewayJs $gatewayJs -GatewayTokenJs $gatewayTokenJs) {
      if ($gw -and -not $gw.HasExited) { Stop-Process -Id $gw.Id -Force -ErrorAction SilentlyContinue }
      $gw = $null
      $port = $candidate
      $gatewayReused = $true
      break
    }
    if ($gw -and -not $gw.HasExited) { Stop-Process -Id $gw.Id -Force -ErrorAction SilentlyContinue }
    $gw = $null
  }
}
try {
  # ポートを 1 つも確保できなかった＝どの候補も他のプログラムに使われている。
  if (-not $port) {
    Write-Host "[ERROR] 送信検査 Gateway を起動できませんでした。送信検査なしでは起動しません (fail-closed)。"
    if ($env:DS_GATEWAY_PORT) {
      Write-Host "  指定されたポート $($env:DS_GATEWAY_PORT) を他のプログラムが使っている可能性があります。"
    } else {
      Write-Host "  ポート 8788〜8797 をすべて他のプログラムが使っている可能性があります。"
    }
    exit 1
  }
  # spawn した node が生存していれば、そのポートは確実に自プロセスのもの。
  # foreign process がポートを占有していれば自 node は bind 失敗で即終了している。
  # 共用時は、そのポートを握っているのが自分たちの gateway であることを直接確かめる。
  if ($gw -and $gw.HasExited) {
    Write-Host "[ERROR] Gateway process is not alive (port may be in use). Not launching without send-side inspection (fail-closed)."
    exit 1
  }
  if ($gatewayReused -and (Get-OurGatewayPid -Port $port -GatewayJs $gatewayJs) -le 0) {
    Write-Host "[ERROR] Gateway process is not alive (port may be in use). Not launching without send-side inspection (fail-closed)."
    exit 1
  }
  $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:$port"
  # Claude Code が gateway へ送る鍵を「実キー」から「この起動限りの合言葉」に差し替える。
  # 呼び出し元 (.bat / launch-integrated.ps1) が実キーを ANTHROPIC_AUTH_TOKEN に入れて
  # 渡してくるが、ここで上書きするので実キーは Claude Code のプロセスには残らない。
  $env:ANTHROPIC_AUTH_TOKEN = $gatewayToken
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
  # coach マーカーは d-claude と OpenCode が同じパスを共有する。並行起動時に片方の終了で
  # もう片方のバナーが消えないよう、「自分が書いた値のままのときだけ」消す。
  try {
    if ((Get-Content -LiteralPath $coachMarker -Raw -ErrorAction Stop).Trim() -eq 'd-claude') {
      Remove-Item -LiteralPath $coachMarker -Force -ErrorAction SilentlyContinue
    }
  } catch {}
  Remove-Item Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
}
