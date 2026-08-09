# oc-safe — OpenCode を Bouncer 監視下で起動する（どこからでも打てるコマンド）。
#
# 使い方 (cmd / PowerShell / ccmux / Zed のターミナル、どこからでも):
#   oc-safe                いま開いているフォルダで起動
#   oc-safe みつもり案件     作業フォルダの中のそのフォルダで起動
#   oc-safe -Resume        前回の続きから開く
#   oc-safe -WebSearch     Web 検索を確認制で有効にする
#
# なぜフォルダを指定して起動するのか:
#   OpenCode は「起動したフォルダ」が作業対象になり、動き出したあとで cd しても移らない
#   (OpenCode 本体の仕様)。プロジェクトごとに分けて作業するには、そのフォルダで起動する
#   必要がある。このコマンドはそれを 1 行で済ませるためのもの。
param(
    [string]$Workspace = "$env:USERPROFILE\Documents\my-ai-workspace",
    [Parameter(Position = 0)]
    [string]$Folder = "",
    [switch]$Resume,
    [switch]$WebSearch
)

$ErrorActionPreference = 'Stop'
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
# 統合ランチャーを経由する。ここが「見守りモニター (Bouncer の画面) ＋ AI」をまとめて
# 立ち上げる入口なので、OpenCode のランチャーを直接叩いてはいけない
# (直接叩くとモニターが起動せず、画面で見えないまま AI が動くことになる)。
$launcher = Join-Path $Workspace '.ai-safety\hooks\windows\launch-integrated.ps1'

if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    Write-Host "安全パッケージが見つかりません: $launcher"
    Write-Host "「1_安全パッケージを準備」を実行してから、もう一度お試しください。"
    exit 1
}

# フォルダ未指定なら「いま開いているフォルダ」。ccmux / Zed / ターミナルのどこから打っても、
# その場所でそのまま作業を始められるようにするため。
if (-not $Folder) { $Folder = (Get-Location).Path }

# 「フォルダ名だけ」で指定されたときは作業フォルダの中を探す (oc-safe みつもり案件)。
if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
    $inWorkspace = Join-Path $Workspace $Folder
    if (Test-Path -LiteralPath $inWorkspace -PathType Container) { $Folder = $inWorkspace }
}
if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
    Write-Host "フォルダが見つかりません: $Folder"
    Write-Host "作業フォルダ: $Workspace"
    exit 2
}
$Folder = [System.IO.Path]::GetFullPath($Folder)

# ワークスペースの外は断る (ガードとポリシーはワークスペース基準で配置されているため)。
$wsPrefix = $Workspace.TrimEnd('\') + '\'
if (-not ($Folder -eq $Workspace -or $Folder.StartsWith($wsPrefix, [System.StringComparison]::OrdinalIgnoreCase))) {
    Write-Host "作業フォルダ (my-ai-workspace) の中で使ってください。"
    Write-Host "  いまの場所: $Folder"
    Write-Host "  作業フォルダ: $Workspace"
    exit 2
}

& $launcher -Workspace $Workspace -Agent opencode -SafetyProfile standard -Project $Folder -Resume:$Resume -WebSearch:$WebSearch
exit $LASTEXITCODE
