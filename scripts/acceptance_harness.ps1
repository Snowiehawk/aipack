$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot
$aipackScript = Join-Path $repoRoot "src\aipack.ps1"
if (-not (Test-Path -LiteralPath $aipackScript)) {
  throw "Could not find aipack script at $aipackScript"
}

function Run-Exe([string]$Exe, [string[]]$CmdArgs, [string]$WorkDir) {
  Push-Location $WorkDir
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out = & $Exe @CmdArgs 2>&1
    $code = $LASTEXITCODE
    if ($null -eq $out) { $outText = "" }
    elseif ($out -is [System.Array]) { $outText = ($out -join "`n") }
    else { $outText = [string]$out }
    return [pscustomobject]@{
      Code = $code
      Out = $outText
    }
  } finally {
    $ErrorActionPreference = $prevEap
    Pop-Location
  }
}

function Require-Zero([object]$Result, [string]$Context) {
  if ($Result.Code -ne 0) {
    throw "$Context failed with exit code $($Result.Code)`n$($Result.Out)"
  }
}

function Require-NonZero([object]$Result, [string]$Context) {
  if ($Result.Code -eq 0) {
    throw "$Context unexpectedly succeeded.`n$($Result.Out)"
  }
}

function Write-RepoFile([string]$Repo, [string]$RelPath, [string]$Content) {
  $full = Join-Path $Repo ($RelPath -replace '/','\')
  $dir = Split-Path -Parent $full
  if (-not [string]::IsNullOrWhiteSpace($dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  [System.IO.File]::WriteAllText($full, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function New-TestRepo([string]$Root, [string]$Name) {
  $repo = Join-Path $Root $Name
  New-Item -ItemType Directory -Force -Path $repo | Out-Null
  Require-Zero (Run-Exe "git" @("init","-q") $repo) "git init ($Name)"
  Require-Zero (Run-Exe "git" @("config","user.email","aipack-harness@example.com") $repo) "git config user.email ($Name)"
  Require-Zero (Run-Exe "git" @("config","user.name","AIPACK Harness") $repo) "git config user.name ($Name)"
  return $repo
}

function Commit-All([string]$Repo, [string]$Message = "initial") {
  Require-Zero (Run-Exe "git" @("add","-A") $Repo) "git add ($Message)"
  Require-Zero (Run-Exe "git" @("commit","-m",$Message) $Repo) "git commit ($Message)"
}

function Invoke-Aipack([string]$Repo, [string]$OutName, [string[]]$ExtraArgs, [string]$WorkDir = "") {
  $wd = $(if ([string]::IsNullOrWhiteSpace($WorkDir)) { $Repo } else { $WorkDir })
  $psArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$aipackScript,"-NoZip",$OutName)
  if ($ExtraArgs) { $psArgs += $ExtraArgs }
  return (Run-Exe "powershell" $psArgs $wd)
}

function Assert-Contains([string]$Path, [string]$Needle, [string]$Context) {
  if (-not (Test-Path -LiteralPath $Path)) { throw "${Context}: missing file $Path" }
  $text = Get-Content -LiteralPath $Path -Raw
  if ($null -eq $text) { $text = "" }
  if (-not $text.Contains($Needle)) {
    throw "${Context}: expected '$Needle' in $Path"
  }
}

function Assert-NotContains([string]$Path, [string]$Needle, [string]$Context) {
  if (-not (Test-Path -LiteralPath $Path)) { throw "${Context}: missing file $Path" }
  $text = Get-Content -LiteralPath $Path -Raw
  if ($null -eq $text) { $text = "" }
  if ($text.Contains($Needle)) {
    throw "${Context}: unexpected '$Needle' in $Path"
  }
}

function Assert-EmptyFile([string]$Path, [string]$Context) {
  if (-not (Test-Path -LiteralPath $Path)) { throw "${Context}: missing file $Path" }
  $raw = Get-Content -LiteralPath $Path -Raw
  if ($null -eq $raw) { $raw = "" }
  $text = $raw.Trim()
  if ($text.Length -ne 0) {
    throw "${Context}: expected empty file $Path, got:`n$text"
  }
}

function Assert-NonEmptyFile([string]$Path, [string]$Context) {
  if (-not (Test-Path -LiteralPath $Path)) { throw "${Context}: missing file $Path" }
  $raw = Get-Content -LiteralPath $Path -Raw
  if ($null -eq $raw) { $raw = "" }
  $text = $raw.Trim()
  if ($text.Length -eq 0) {
    throw "${Context}: expected non-empty file $Path"
  }
}

function OutDir([string]$Repo, [string]$OutName) {
  return (Join-Path $Repo $OutName)
}

$harnessRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("aipack-acceptance-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $harnessRoot | Out-Null

$results = New-Object System.Collections.Generic.List[object]

function Run-Scenario([string]$Name, [scriptblock]$Body) {
  try {
    & $Body
    Write-Host ("[PASS] " + $Name)
    $results.Add([pscustomobject]@{ Name = $Name; Pass = $true; Error = "" }) | Out-Null
  } catch {
    Write-Host ("[FAIL] " + $Name)
    Write-Host ("       " + $_.Exception.Message)
    $results.Add([pscustomobject]@{ Name = $Name; Pass = $false; Error = $_.Exception.Message }) | Out-Null
  }
}

Run-Scenario "Tracked lockfile included in full snapshot" {
  $repo = New-TestRepo $harnessRoot "lockfile-full"
  Write-RepoFile $repo "README.md" "lockfile full snapshot"
  Write-RepoFile $repo "package-lock.json" "{`"name`":`"demo`"}"
  Commit-All $repo "seed"

  $res = Invoke-Aipack $repo "out_full" @()
  Require-Zero $res "aipack full lockfile"

  $out = OutDir $repo "out_full"
  Assert-Contains (Join-Path $out "repomix-output.xml") "package-lock.json" "full lockfile"
  Assert-EmptyFile (Join-Path $out "aipack_missing_tracked.txt") "full lockfile missing tracked"
}

Run-Scenario "Tracked file excluded by .repomixignore is still included in full snapshot" {
  $repo = New-TestRepo $harnessRoot "repomixignore-full"
  Write-RepoFile $repo "README.md" "repomixignore full snapshot"
  Write-RepoFile $repo ".repomixignore" "filtered/**"
  Write-RepoFile $repo "filtered/tracked.txt" "should still be present"
  Commit-All $repo "seed"

  $res = Invoke-Aipack $repo "out_full" @()
  Require-Zero $res "aipack full repomixignore"

  $out = OutDir $repo "out_full"
  Assert-Contains (Join-Path $out "repomix-output.xml") "filtered/tracked.txt" "full repomixignore tracked file"
  Assert-Contains (Join-Path $out "repomix-output.xml") ".repomixignore" "full repomixignore file present"
  Assert-EmptyFile (Join-Path $out "aipack_missing_tracked.txt") "full repomixignore missing tracked"
}

Run-Scenario "Windows nested tracked paths are not dropped" {
  $repo = New-TestRepo $harnessRoot "nested-paths"
  Write-RepoFile $repo "README.md" "nested path test"
  Write-RepoFile $repo "deep/a/b/c/file.txt" "nested file"
  Commit-All $repo "seed"

  $res = Invoke-Aipack $repo "out_full" @()
  Require-Zero $res "aipack nested paths"

  $out = OutDir $repo "out_full"
  Assert-Contains (Join-Path $out "repomix-output.xml") "deep/a/b/c/file.txt" "nested tracked file"
  Assert-EmptyFile (Join-Path $out "aipack_missing_tracked.txt") "nested missing tracked"
}

Run-Scenario "CWD independence from repo root and nested folder" {
  $repo = New-TestRepo $harnessRoot "cwd-independence"
  Write-RepoFile $repo "README.md" "cwd independence"
  Write-RepoFile $repo "src/app.txt" "app"
  Commit-All $repo "seed"

  $rootRun = Invoke-Aipack $repo "out_root" @() $repo
  Require-Zero $rootRun "aipack cwd root run"

  $nestedWd = Join-Path $repo "src"
  $nestedRun = Invoke-Aipack $repo "out_nested" @() $nestedWd
  Require-Zero $nestedRun "aipack cwd nested run"

  $rootOut = OutDir $repo "out_root"
  $nestedOut = OutDir $repo "out_nested"
  if (-not (Test-Path -LiteralPath $rootOut)) { throw "root run output directory missing: $rootOut" }
  if (-not (Test-Path -LiteralPath $nestedOut)) { throw "nested run output directory missing: $nestedOut" }
  Assert-Contains (Join-Path $nestedOut "AIPACK_SUMMARY.txt") ("repo_root: " + ($repo -replace '\\','/')) "nested summary repo root"
}

Run-Scenario "Default includes untracked, TrackedOnly excludes untracked" {
  $repo = New-TestRepo $harnessRoot "tracked-only"
  Write-RepoFile $repo "README.md" "tracked only behavior"
  Write-RepoFile $repo "tracked.txt" "tracked file"
  Commit-All $repo "seed"
  Write-RepoFile $repo "scratch/untracked.txt" "untracked file"

  $defaultRun = Invoke-Aipack $repo "out_default" @()
  Require-Zero $defaultRun "aipack default includes untracked"
  $defaultOut = OutDir $repo "out_default"
  Assert-Contains (Join-Path $defaultOut "repomix-output.xml") "scratch/untracked.txt" "default includes untracked"

  $trackedRun = Invoke-Aipack $repo "out_tracked_only" @("-TrackedOnly")
  Require-Zero $trackedRun "aipack tracked only run"
  $trackedOut = OutDir $repo "out_tracked_only"
  Assert-NotContains (Join-Path $trackedOut "repomix-output.xml") "scratch/untracked.txt" "tracked-only excludes untracked"
  Assert-EmptyFile (Join-Path $trackedOut "aipack_missing_tracked.txt") "tracked-only missing tracked"
}

Run-Scenario "Legacy filtered non-fatal by default, strict fatal with TrackedOnly" {
  $repo = New-TestRepo $harnessRoot "legacy-enforcement"
  Write-RepoFile $repo "README.md" "legacy enforcement"
  Write-RepoFile $repo ".repomixignore" "filtered/**"
  Write-RepoFile $repo "filtered/tracked.txt" "legacy should filter this"
  Write-RepoFile $repo "package-lock.json" "{`"name`":`"legacy`"}"
  Commit-All $repo "seed"

  $legacyRun = Invoke-Aipack $repo "out_legacy" @("-LegacyFiltered")
  Require-Zero $legacyRun "legacy filtered default"
  $legacyOut = OutDir $repo "out_legacy"
  Assert-NonEmptyFile (Join-Path $legacyOut "aipack_missing_tracked.txt") "legacy filtered should report missing tracked"

  $strictRun = Invoke-Aipack $repo "out_legacy_strict" @("-LegacyFiltered","-TrackedOnly")
  Require-NonZero $strictRun "legacy strict should fail"

  $allowRun = Invoke-Aipack $repo "out_legacy_strict_allow" @("-LegacyFiltered","-TrackedOnly","-AllowMissingTracked")
  Require-Zero $allowRun "legacy strict allow missing tracked"
}

$failed = @($results | Where-Object { -not $_.Pass })
Write-Host ""
Write-Host "Scenario summary:"
foreach ($r in $results) {
  Write-Host ("- " + $r.Name + ": " + ($(if ($r.Pass) { "PASS" } else { "FAIL" })))
}

if ($failed.Count -gt 0) {
  Write-Host ""
  Write-Host ("Acceptance harness failed: " + $failed.Count + " scenario(s) failed.")
  exit 1
}

Write-Host ""
Write-Host "Acceptance harness passed."
exit 0
