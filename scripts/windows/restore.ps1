param(
    [Parameter(Mandatory=$true)]
    [string]$BackupZip,
    [string]$Workspace = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$Workspace = [System.IO.Path]::GetFullPath($Workspace)
if (-not (Test-Path -LiteralPath $BackupZip)) { throw "Backup not found: $BackupZip" }

# H7 Step 1: integrity check against companion .sha256 file (created by backup.ps1).
$sha256File = "$BackupZip.sha256"
if (Test-Path -LiteralPath $sha256File) {
    $expected = (Get-Content -LiteralPath $sha256File -Raw).Trim().Split()[0].ToLower()
    $actual = (Get-FileHash -LiteralPath $BackupZip -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
        Write-Error ("Backup zip SHA-256 mismatch. expected=" + $expected + " actual=" + $actual)
        exit 1
    }
} else {
    Write-Warning ("No companion .sha256 for " + $BackupZip + " (legacy backup?)")
}

# H7 Step 2: zip-slip detection. Inspect entry names before extraction.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($BackupZip)
try {
    foreach ($entry in $zip.Entries) {
        $name = $entry.FullName
        if ($name -match '(^|[\\/])\.\.([\\/]|$)' -or $name -match '^[\\/]' -or $name -match '^[A-Za-z]:[\\/]') {
            $zip.Dispose()
            Write-Error ("Backup contains path traversal or absolute-path entry: " + $name)
            exit 1
        }
    }
} finally {
    $zip.Dispose()
}

# H7 Step 3: extract only after validation.
Expand-Archive -LiteralPath $BackupZip -DestinationPath $Workspace -Force
Write-Host ("Restored to " + $Workspace)
