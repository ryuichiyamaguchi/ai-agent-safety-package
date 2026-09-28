# ci-install-doctor.ps1 — 日本語名の作業フォルダへ導入し、そのまま診断まで流す「導入の通し確認」。
#
# 出荷条件 C（docs/_dev/RELEASE_GATE.md: Windows 代表環境で導入 → 診断）を自動で回すための足がかり。
# GitHub Actions の windows-latest（Windows PowerShell 5.1・日本語を含むパス）で実行する。
#
# ⚠️ install.ps1 は作業フォルダだけでなくホームフォルダ側（%USERPROFILE%\.ai-safety など）にも書き込む。
#    普段使いの PC では実行せず、使い捨ての環境（CI・検証用の仮想マシン）で使うこと。
#
# 使い方:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\test\ci-install-doctor.ps1
#   （-Workspace で導入先を変えられる。既定は %USERPROFILE%\Documents\AI作業フォルダ-CI）
param(
    [string]$Workspace = ''
)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here '..\..\..')).Path
if (-not $Workspace) { $Workspace = Join-Path $env:USERPROFILE 'Documents\AI作業フォルダ-CI' }
$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) { $psExe = 'powershell.exe' }

Write-Host ('PowerShell ' + $PSVersionTable.PSVersion + ' : ' + $psExe)
Write-Host ('パッケージ: ' + $repo)
Write-Host ('導入先    : ' + $Workspace)

Write-Host ''
Write-Host '===== 1/2 導入（install.ps1） ====='
& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\windows\install.ps1') -Workspace $Workspace
$rcInstall = $LASTEXITCODE
Write-Host ('install.ps1 exit=' + $rcInstall)
if ($rcInstall -ne 0) { exit $rcInstall }

$doctor = Join-Path $Workspace '.ai-safety\hooks\windows\doctor.ps1'
if (-not (Test-Path -LiteralPath $doctor)) {
    Write-Host ('FAIL 導入後に doctor.ps1 が見つかりません: ' + $doctor)
    exit 1
}

Write-Host ''
Write-Host '===== 2/2 診断（doctor.ps1） ====='
Push-Location -LiteralPath $Workspace
& $psExe -NoProfile -ExecutionPolicy Bypass -File $doctor -Workspace $Workspace
$rcDoctor = $LASTEXITCODE
Pop-Location
Write-Host ('doctor.ps1 exit=' + $rcDoctor)
exit $rcDoctor
