param(
  [string]$InstallDir = (Join-Path $env:USERPROFILE "bin"),
  [switch]$KeepPath
)

$ErrorActionPreference = "Stop"

$dstPs1 = Join-Path $InstallDir "aipack.ps1"
$dstCmd = Join-Path $InstallDir "aipack.cmd"
$homeFile = Join-Path $InstallDir "aipack.home"

Remove-Item -Force -ErrorAction SilentlyContinue $dstPs1, $dstCmd, $homeFile

[Environment]::SetEnvironmentVariable("AIPACK_HOME", $null, "User")

if (-not $KeepPath) {
  $userPath = [Environment]::GetEnvironmentVariable("Path","User")
  if ($userPath) {
    $parts = $userPath.Split(";") | Where-Object { $_ -and $_.Trim() }
    $kept = @()
    foreach ($p in $parts) {
      if ($p.TrimEnd("\") -ine $InstallDir.TrimEnd("\")) { $kept += $p }
    }
    [Environment]::SetEnvironmentVariable("Path", ($kept -join ";"), "User")
  }
}

Write-Host "Uninstalled aipack from: $InstallDir"
