param(
  [string]$InstallDir = (Join-Path $env:USERPROFILE "bin"),
  [switch]$NoPath,
  [switch]$Force,
  [switch]$SkipDeps,
  [switch]$NoWarmup
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = $PSScriptRoot
$src = Join-Path $repoRoot "src\aipack.ps1"
if (-not (Test-Path $src)) { throw "Missing $src. Run install.ps1 from a cloned aipack repo." }

function Is-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Refresh-Path {
  $m = [Environment]::GetEnvironmentVariable("Path","Machine")
  $u = [Environment]::GetEnvironmentVariable("Path","User")
  $joined = @()
  if ($m) { $joined += $m }
  if ($u) { $joined += $u }
  $env:Path = ($joined -join ";").Trim(";")
}

function Cmd-Exists([string]$name) {
  return $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

function Ensure-FromCommonPaths([string]$exeName, [string[]]$dirs) {
  if (Cmd-Exists $exeName) { return $true }
  foreach ($d in $dirs) {
    $p = Join-Path $d $exeName
    if (Test-Path $p) {
      $env:Path = "$d;$env:Path"
      return $true
    }
  }
  return $false
}

function Add-ToUserPath([string]$dir) {
  $dirNorm = $dir.TrimEnd("\")
  $userPath = [Environment]::GetEnvironmentVariable("Path","User")
  $parts = @()
  if ($userPath) { $parts = $userPath.Split(";") | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
  foreach ($p in $parts) {
    if ($p.TrimEnd("\") -ieq $dirNorm) { return }
  }
  $newPath = (($parts + $dirNorm) -join ";").Trim(";")
  [Environment]::SetEnvironmentVariable("Path",$newPath,"User")
}

function Winget-Exists {
  return $null -ne (Get-Command winget.exe -ErrorAction SilentlyContinue) -or $null -ne (Get-Command winget -ErrorAction SilentlyContinue)
}

function Winget-Install([string]$id) {
  if (-not (Winget-Exists)) { return $false }
  Write-Host "Installing via winget: $id"
  $args = @("install","-e","--id",$id,"--source","winget","--accept-package-agreements","--accept-source-agreements","--silent")
  & winget @args | Out-Host
  Refresh-Path
  return $LASTEXITCODE -eq 0
}

function Winget-Upgrade([string]$id) {
  if (-not (Winget-Exists)) { return $false }
  Write-Host "Upgrading via winget: $id"
  $args = @("upgrade","-e","--id",$id,"--source","winget","--accept-package-agreements","--accept-source-agreements","--silent")
  & winget @args | Out-Host
  Refresh-Path
  return $LASTEXITCODE -eq 0
}

function Download-File([string]$url, [string]$outPath) {
  Write-Host "Downloading: $url"
  Invoke-WebRequest -Uri $url -OutFile $outPath
}

function Install-Git-Direct {
  if (-not (Cmd-Exists "powershell")) { throw "PowerShell is required." }
  Write-Host "Installing Git for Windows from official release feed"
  $headers = @{ "User-Agent" = "aipack-installer" }
  $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -Headers $headers
  $asset = $rel.assets | Where-Object { $_.name -match 'Git-.*-64-bit\.exe$' -and $_.name -notmatch 'Portable' } | Select-Object -First 1
  if (-not $asset) { throw "Could not find Git-*-64-bit.exe in latest Git for Windows release." }
  $exe = Join-Path $env:TEMP $asset.name
  Download-File $asset.browser_download_url $exe
  Write-Host "Running Git installer silently"
  $args = @("/VERYSILENT","/NORESTART","/NOCANCEL","/SP-")
  Start-Process -FilePath $exe -ArgumentList $args -Wait
  Refresh-Path
}

function Install-Node-LTS-Direct {
  Write-Host "Installing Node.js LTS from nodejs.org"
  $index = Invoke-RestMethod -Uri "https://nodejs.org/dist/index.json"
  $lts = $index | Where-Object { $_.lts -and $_.lts -ne $false }
  if (-not $lts) { throw "Could not find LTS releases in nodejs index." }
  $latest = $lts | Sort-Object { [version]($_.version.TrimStart("v")) } -Descending | Select-Object -First 1
  $ver = $latest.version
  $arch = "x64"
  $msiName = "node-$ver-$arch.msi"
  $msiUrl = "https://nodejs.org/dist/$ver/$msiName"
  $msi = Join-Path $env:TEMP $msiName
  Download-File $msiUrl $msi
  Write-Host "Running Node installer silently"
  Start-Process -FilePath "msiexec.exe" -ArgumentList @("/i",$msi,"/qn","/norestart") -Wait
  Refresh-Path
}

function Ensure-Git {
  Refresh-Path
  $found = Ensure-FromCommonPaths "git.exe" @(
    "C:\Program Files\Git\cmd",
    "C:\Program Files (x86)\Git\cmd"
  )
  if ($found) { return }

  if (-not $SkipDeps) {
    $ok = (Winget-Upgrade "Git.Git")
    if (-not $ok) { $ok = (Winget-Install "Git.Git") }
    if (-not $ok) { Install-Git-Direct }
  }

  Refresh-Path
  if (-not (Cmd-Exists "git")) {
    $msg = "Git install failed or git is not on PATH."
    if (-not (Is-Admin)) { $msg += " Try rerunning in an elevated terminal or install Git manually, or use -SkipDeps." }
    throw $msg
  }
}

function Get-NodeMajor {
  if (-not (Cmd-Exists "node")) { return 0 }
  $v = (& node -v).Trim()
  $v = $v.TrimStart("v")
  $major = [int]($v.Split(".")[0])
  return $major
}

function Ensure-Node {
  Refresh-Path
  $found = Ensure-FromCommonPaths "node.exe" @(
    "C:\Program Files\nodejs",
    "C:\Program Files (x86)\nodejs"
  )
  if (-not $found) {
    $found = Ensure-FromCommonPaths "npx.cmd" @(
      "C:\Program Files\nodejs",
      "C:\Program Files (x86)\nodejs"
    )
  }

  $major = Get-NodeMajor
  $need = ($major -lt 18)

  if ($need -and (-not $SkipDeps)) {
    $ok = (Winget-Upgrade "OpenJS.NodeJS.LTS")
    if (-not $ok) { $ok = (Winget-Install "OpenJS.NodeJS.LTS") }
    if (-not $ok) { $ok = (Winget-Upgrade "OpenJS.NodeJS") }
    if (-not $ok) { $ok = (Winget-Install "OpenJS.NodeJS") }
    if (-not $ok) { Install-Node-LTS-Direct }
  }

  Refresh-Path
  $hint = ""
  if (-not (Is-Admin)) { $hint = " Try rerunning in an elevated terminal or install Node.js manually, or use -SkipDeps." }
  if (-not (Cmd-Exists "node")) { throw "Node install failed or node is not on PATH.$hint" }
  if (-not (Cmd-Exists "npm")) { throw "npm is missing (Node install incomplete).$hint" }
  if (-not (Cmd-Exists "npx.cmd")) { throw "npx.cmd is missing (Node install incomplete).$hint" }

  $major2 = Get-NodeMajor
  if ($major2 -lt 18) { throw "Node is too old (need >= 18). Found: $(& node -v)" }
}

function Warmup-Repomix {
  if ($NoWarmup) { return }
  if (-not (Cmd-Exists "npx.cmd")) { return }
  Write-Host "Warming up repomix (downloads once via npx, cached afterwards)"
  try {
    & npx.cmd --yes repomix@latest --version | Out-Host
  } catch {
    try { & npx.cmd repomix@latest --version | Out-Host } catch { }
  }
}

if (-not $SkipDeps) {
  if (-not (Is-Admin)) {
    Write-Host "Note: dependency installs may require an elevated terminal on some machines."
  }
  Ensure-Git
  Ensure-Node
  Warmup-Repomix
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$dstPs1 = Join-Path $InstallDir "aipack.ps1"
$dstCmd = Join-Path $InstallDir "aipack.cmd"

$alreadyInstalled = (Test-Path $dstPs1) -or (Test-Path $dstCmd)
if ($alreadyInstalled -and (-not $Force)) {
  throw "aipack already installed in $InstallDir. Re run with -Force to overwrite."
}

Copy-Item -Force $src $dstPs1

@"
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0aipack.ps1" %*
"@ | Set-Content -Encoding ASCII -Path $dstCmd

if (-not $NoPath) {
  Add-ToUserPath $InstallDir
  Refresh-Path
}

$homeFile = Join-Path $InstallDir "aipack.home"
[Environment]::SetEnvironmentVariable("AIPACK_HOME", $repoRoot, "User")
$repoRoot | Set-Content -Encoding ASCII -Path $homeFile

Write-Host ""
Write-Host "Installed aipack to: $InstallDir"
Write-Host "Try: aipack help"
Write-Host ""
