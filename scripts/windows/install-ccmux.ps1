# install-ccmux.ps1 — 改造版 ccmux.exe を安全に導入する。
# npm で ccmux-cli を入れ、改造版 ccmux.exe で実体を上書きする。
# 実体 exe は「同フォルダ→Downloads→GitHub Release」の順で取得し、**必ず SHA-256 で照合**して
# から使う(Google Drive 等で破損したファイルを弾く)。MIT ライセンス本文も実体の隣に置く。
param(
    [string]$Workspace = (Join-Path $HOME "Documents\my-ai-workspace")
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 改造版 ccmux.exe の既知 SHA-256（この値と一致しない exe は破損/別物として拒否）。
$expect = "a756925c14835ef2dbcbc47922d036a888d4adeb13b33452f8c8991d94921026"
$relBase = "https://github.com/ryuichiyamaguchi/ai-agent-safety-package/releases/latest/download"

function Fail([string]$m){ Write-Host ""; Write-Host ("【中止】" + $m) -ForegroundColor Red; Write-Host "このウィンドウを閉じて、もう一度お試しください。"; exit 1 }
function Test-Ccmux([string]$p){
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { return $false }
    try { return ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() -eq $expect) } catch { return $false }
}

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Fail "npm が見つかりません。先に「0_AIツールをまとめて入れる」を実行してください。"
}

Write-Host "[1/4] ccmux-cli を導入中（少し時間がかかります）..."
& npm install -g ccmux-cli | Out-Host

Write-Host "[2/4] 改造版 ccmux.exe を用意＆SHA-256 照合中..."
$src = $null
foreach ($cand in @((Join-Path $PSScriptRoot "ccmux.exe"), (Join-Path $env:USERPROFILE "Downloads\ccmux.exe"))) {
    if (Test-Ccmux $cand) { $src = $cand; Write-Host ("  ローカルの正規 ccmux.exe を使用: " + $cand) -ForegroundColor Green; break }
}
if (-not $src) {
    Write-Host "  ローカルに正規ファイルが無い/壊れている → GitHub Release から取得します..."
    $tmp = Join-Path $env:TEMP "ccmux.exe"
    try { Invoke-WebRequest -Uri ("$relBase/ccmux.exe") -OutFile $tmp -UseBasicParsing } catch { Fail "ccmux.exe を取得できませんでした（ネットワークを確認）。" }
    if (Test-Ccmux $tmp) { $src = $tmp; Write-Host "  ダウンロード＆照合OK。" -ForegroundColor Green }
    else { Fail "ダウンロードした ccmux.exe が壊れています（SHA-256 不一致）。中止します。" }
}

Write-Host "[3/4] ccmux-cli の実体を改造版で上書き..."
$target = Join-Path $env:APPDATA "npm\node_modules\ccmux-cli\bin\ccmux.exe"
$targetDir = Split-Path -Parent $target
if (-not (Test-Path -LiteralPath $targetDir)) { Fail ("ccmux-cli の実体フォルダが見つかりません: " + $targetDir + "`n  npm の導入が完了していない可能性があります。") }
Copy-Item -LiteralPath $src -Destination $target -Force

Write-Host "[4/4] ライセンス本文（MIT・改造版明記）を実体の隣に配置..."
# MIT 遵守: 元著作権表示＋ライセンス本文を ccmux.exe の隣に置く。
$licDest = Join-Path $targetDir "ccmux-LICENSE.txt"
$licLocal = Join-Path $PSScriptRoot "..\..\THIRD_PARTY\ccmux-LICENSE.txt"
try {
    if (Test-Path -LiteralPath $licLocal) { Copy-Item -LiteralPath $licLocal -Destination $licDest -Force }
    else { Invoke-WebRequest -Uri ("$relBase/ccmux-LICENSE.txt") -OutFile $licDest -UseBasicParsing }
} catch { Write-Host "  （ライセンスファイルの配置はスキップしました）" -ForegroundColor Yellow }

Write-Host ""
Write-Host "インストール成功！ 新しい PowerShell で ccmux と打つと起動します。" -ForegroundColor Green
Write-Host "（これは Shin-sibainu/ccmux の改造版です・MIT）"
