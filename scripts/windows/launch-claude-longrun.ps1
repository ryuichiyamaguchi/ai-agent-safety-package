# launch-claude-longrun.ps1 — 「長時間おまかせモード」の Windows 側。
#
# このモードは「OS の壁（サンドボックス）があるから承認を省ける」という考え方で作ってある。
# Claude Code の純正サンドボックスは公式に macOS / Linux / WSL2 のみ対応で、
# ネイティブ Windows は非対応（公式 https://code.claude.com/docs/en/sandboxing）。
# 壁が無い環境で承認を省くと本当に無防備になるため、Windows では **起動しない**。
# 黙って落とさず、理由と代わりの手段を日本語で出す。
$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '長時間おまかせモードは、いまは Mac でだけ使えます。'
Write-Host ''
Write-Host '理由:'
Write-Host '  このモードは「OS の壁（サンドボックス）が作業フォルダの外への書き込みと'
Write-Host '  許可外の通信を止めているから、確認を省いても大丈夫」という考え方で作っています。'
Write-Host '  Claude Code の純正サンドボックスは macOS / Linux / WSL2 だけの対応で、'
Write-Host '  Windows（そのまま使う場合）は公式に非対応です。'
Write-Host '  壁が無いまま確認だけ省くと、本当に無防備になります。'
Write-Host ''
Write-Host '代わりに:'
Write-Host '  ・いつもどおり「3_セーフClaudeを起動」を使ってください（見張りと記録は効きます）'
Write-Host '  ・どうしても長時間おまかせにしたい場合は、Mac か WSL2 の環境で行ってください'
Write-Host ''
Write-Host 'くわしくは docs/20_卒業後ガイド.md の「長時間おまかせモード」を読んでください。'
Write-Host ''
exit 2
