param(
    [switch]$SkipWarning = $false,
    # ConsentOnly: 赤枠警告 + yes/no 同意確認までで終了し、Web UI 用の
    # 推奨ワークフロー / safe-paste 案内は実行しない。起動-Claude-DeepSeek
    # （Claude Code on DeepSeek 文脈）から呼ぶ。未指定なら従来動作を完全維持。
    [switch]$ConsentOnly = $false
)

# launch-deepseek-safe.ps1
#
# 外部 LLM（DeepSeek 等の中国系・第三者 LLM）を使う前の「念押しゲート」と
# 機微情報スキャナのワンストップ ラッパー（v1.4.0 で新規追加）。

$ErrorActionPreference = "Stop"
# C-3: $PSScriptRoot で同ディレクトリのスクリプトを直接参照（二重階層パス不要）
$SecretScan = Join-Path $PSScriptRoot "secret-scan.ps1"
$SafePaste  = Join-Path $PSScriptRoot "clipboard-safe-paste.ps1"

if (-not $SkipWarning) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║  ⚠  DEEPSEEK / 外部 LLM SAFETY GATE  ⚠                          ║" -ForegroundColor Red
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Host "これから DeepSeek（または他の外部 / 中国系 LLM）にデータを" -ForegroundColor Red
    Write-Host "送信しようとしています。送信内容は" -ForegroundColor Red
    Write-Host ""
    Write-Host "  - 中国管轄のサーバーに保存される可能性があります" -ForegroundColor Yellow
    Write-Host "  - 中国のサイバーセキュリティ法 / PIPL 下で政府要請に従い" -ForegroundColor Yellow
    Write-Host "    開示される可能性があります" -ForegroundColor Yellow
    Write-Host "  - Anthropic / OpenAI のプライバシーポリシー対象外です" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "ルール:" -ForegroundColor Red
    Write-Host "  ✓ 絶対に流出しても問題ない情報だけ扱う" -ForegroundColor Green
    Write-Host "  ✓ 本物の API キー・パスワードを書かない" -ForegroundColor Green
    Write-Host "  ✓ 顧客名・社外秘・個人情報を書かない" -ForegroundColor Green
    Write-Host "  ✓ 機微情報は secret-scan でマスキングしてから貼り付ける" -ForegroundColor Green
    Write-Host ""
    $answer = Read-Host "上記を理解した上で続行しますか？ (yes/no)"
    if ($answer -ne "yes") {
        Write-Host ""
        Write-Host "キャンセルしました。" -ForegroundColor Green
        exit 1
    }
}

# ConsentOnly: 同意確認だけ取って終了（Claude Code on DeepSeek 文脈では
# クリップボード貼り付けが発生しないため、以降の Web UI 用案内は出さない）。
if ($ConsentOnly) {
    exit 0
}

Write-Host ""
Write-Host "===== 推奨ワークフロー =====" -ForegroundColor Green
Write-Host ""
Write-Host "  1. DeepSeek の Web UI（chat.deepseek.com）または公式 CLI を別画面で開く"
Write-Host "  2. プロンプトを書き終わったらコピー（Ctrl+C）"
Write-Host "  3. 以下のコマンドでクリップボードをスキャン＋マスキング:"
Write-Host "     safe-paste" -ForegroundColor Yellow
Write-Host "  4. DeepSeek に貼り付け（Ctrl+V）"
Write-Host ""
Write-Host "===== コマンドリファレンス =====" -ForegroundColor Green
Write-Host ""
Write-Host "  Get-Content prompt.txt | .\secret-scan.ps1   # ファイルをスキャン＋マスキング"
Write-Host "  Get-Clipboard | .\secret-scan.ps1 -Check     # 検出件数だけ確認"
Write-Host "  safe-paste                                     # クリップボードを scan + mask（推奨）"
Write-Host ""
Write-Host "===== 監査ログ =====" -ForegroundColor Green
Write-Host ""
Write-Host "  $HOME\.ai-safety\logs\secret-scan-events.jsonl"
Write-Host "  （マスキング件数のみ記録、本物の値は記録されません）"
Write-Host ""

# その場で safe-paste を実行するか
if ((Test-Path -LiteralPath $SafePaste) -and ([Console]::IsInputRedirected -eq $false)) {
    $runNow = Read-Host "今すぐクリップボードをスキャンしますか？ (y/N)"
    if ($runNow -eq "y" -or $runNow -eq "Y") {
        Write-Host ""
        & powershell -ExecutionPolicy Bypass -File $SafePaste
    }
}

Write-Host ""
Write-Host "DeepSeek セッションが終わったら、機微情報を貼り付けていないか" -ForegroundColor Green
Write-Host "監査ログをセルフチェックしてください。" -ForegroundColor Green
Write-Host ""
exit 0
