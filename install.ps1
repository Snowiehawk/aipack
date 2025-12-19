param(
  [string]$InstallDir = (Join-Path $env:USERPROFILE "bin"),
  [switch]$NoPath,
  [switch]$Force
)

$ErrorActionPreference = "Stop"

$repoRoot = $PSScriptRoot
$src = Join-Path $repoRoot "src\aipack.ps1"
if (-not (Test-Path $src)) {
  throw "Missing $src. Run install.ps1 from a cloned aipack repo."
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$dstPs1 = Join-Path $InstallDir "aipack.ps1"
$dstCmd = Join-Path $InstallDir "aipack.cmd"

if ((Test-Path $dstPs1 -or Test-Path $dstCmd) -and (-not $Force)) {
  throw "aipack already installed in $InstallDir. Re run with -Force to overwrite."
}

Copy-Item -Force $src $dstPs1

@"
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0aipack.ps1" %*
"@ | Set-Content -Encoding ASCII -Path $dstCmd

if (-not $NoPath) {
  $userPath = [Environment]::GetEnvironmentVariable("Path","User")
  $parts = @()
  if ($userPath) { $parts = $userPath.Split(";") | Where-Object { $_ -and $_.Trim() } }

  $has = $false
  foreach ($p in $parts) {
    if ($p.TrimEnd("\") -ieq $InstallDir.TrimEnd("\")) { $has = $true; break }
  }

  if (-not $has) {
    $new = (($parts + $InstallDir) -join ";")
    [Environment]::SetEnvironmentVariable("Path", $new, "User")
  }
}

Write-Host ""
Write-Host "Installed aipack to: $InstallDir"
Write-Host "Open a NEW terminal, then run: aipack help"
Write-Host ""
