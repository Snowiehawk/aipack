[CmdletBinding(DefaultParameterSetName="Pack")]
param(
  [Parameter(ParameterSetName="Pack", Position=0)]
  [string]$Arg = "",
  [Parameter(ParameterSetName="Pack")]
  [Alias("Name")]
  [string]$OutName = "",
  [Parameter(ParameterSetName="Pack")]
  [string]$RepoName = "",
  [Parameter(ParameterSetName="Pack")]
  [switch]$Zip,
  [Parameter(ParameterSetName="Pack")]
  [switch]$NoZip,
  [Parameter(ParameterSetName="Pack")]
  [switch]$ZipOnly,
  [switch]$Yes,
  [Parameter(ParameterSetName="Pack")]
  [switch]$Staged,
  [Parameter(ParameterSetName="Pack")]
  [switch]$StrictTracked,
  [Parameter(ParameterSetName="Pack")]
  [switch]$PackUntracked,
  [Parameter(ParameterSetName="Pack")]
  [switch]$NoRemote,
  [Parameter(ParameterSetName="Pack")]
  [switch]$Lean,
  [Parameter(ParameterSetName="Pack")]
  [string]$OpenAPIUrl = "",
  [Parameter(ParameterSetName="Pack")]
  [switch]$Compress,
  [Parameter(ParameterSetName="Pack")]
  [string]$ExtraIgnore = "",
  [Parameter(ParameterSetName="Install", Mandatory=$true)]
  [switch]$Install,
  [Parameter(ParameterSetName="Reinstall", Mandatory=$true)]
  [switch]$Reinstall,
  [Parameter(ParameterSetName="Uninstall", Mandatory=$true)]
  [switch]$Uninstall,
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$RemainingArgs
)

$AIPACK_VERSION = "0.3.2"

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Try-Cmd([string]$Exe, [string[]]$CmdArgs) {
  try {
    $out = & $Exe @CmdArgs 2>&1
    $code = $LASTEXITCODE

    if ($null -eq $out) { $outText = "" }
    elseif ($out -is [System.Array]) { $outText = ($out -join "`n") }
    else { $outText = [string]$out }

    return [pscustomobject]@{ Out = $outText; Code = $code }
  } catch {
    return [pscustomobject]@{ Out = ($_ | Out-String); Code = 1 }
  }
}

function Join-CmdArgs([string[]]$ArgList) {
  if ($null -eq $ArgList -or $ArgList.Count -eq 0) { return "" }
  $parts = foreach ($a in $ArgList) {
    if ($null -eq $a) { continue }
    $s = [string]$a
    if ($s -eq "") { '""' }
    elseif ($s -match '[\s"]') { '"' + ($s -replace '"','\"') + '"' }
    else { $s }
  }
  return ($parts -join ' ')
}

function Try-CmdStdin([string]$Exe, [string[]]$CmdArgs, [string]$StdinText) {
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $isCmd = $false
    if ($Exe) {
      $ext = [System.IO.Path]::GetExtension($Exe)
      if ($ext -and ($ext.ToLowerInvariant() -in @(".cmd",".bat"))) { $isCmd = $true }
    }
    if ($isCmd) {
      $psi.FileName = "cmd.exe"
      $psi.Arguments = "/c " + (Join-CmdArgs (@($Exe) + $CmdArgs))
    } else {
      $psi.FileName = $Exe
      $psi.Arguments = (Join-CmdArgs $CmdArgs)
    }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi

    $null = $p.Start()
    if ($null -ne $StdinText) {
      $p.StandardInput.Write($StdinText)
    }
    $p.StandardInput.Close()

    $outText = $p.StandardOutput.ReadToEnd()
    $errText = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $combined = $outText
    if (-not [string]::IsNullOrWhiteSpace($errText)) {
      if ($combined -and -not $combined.EndsWith("`n")) { $combined += "`n" }
      $combined += $errText
    }
    return [pscustomobject]@{ Out = $combined; Code = $p.ExitCode }
  } catch {
    return [pscustomobject]@{ Out = ($_ | Out-String); Code = 1 }
  }
}

function Get-DirectoryStructureLinesFromXml([string]$XmlText) {
  $lines = @()
  if ([string]::IsNullOrWhiteSpace($XmlText)) { return $lines }
  $dirMatch = [regex]::Match($XmlText, "<directory_structure>(.*?)</directory_structure>", [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if ($dirMatch.Success) {
    $dirText = $dirMatch.Groups[1].Value
    $dirText = $dirText -replace "`r`n","`n"
    $dirText = $dirText -replace "`r","`n"
    $lines = $dirText -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -ne "" }
  }
  return @($lines)
}

function Find-ZipEntryBySuffix($Zip, [string]$Suffix) {
  if ($null -eq $Zip -or [string]::IsNullOrWhiteSpace($Suffix)) { return $null }
  foreach ($e in $Zip.Entries) {
    if ($e.FullName -ieq $Suffix) { return $e }
    if ($e.FullName -like "*/$Suffix") { return $e }
  }
  return $null
}

function Read-ZipEntryText($Entry) {
  if ($null -eq $Entry) { return $null }
  $sr = New-Object System.IO.StreamReader($Entry.Open())
  try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
}

function Get-RepoPathFromRepoInfoText([string]$InfoText) {
  if ([string]::IsNullOrWhiteSpace($InfoText)) { return "" }
  $m = [regex]::Match($InfoText, "^packed from:\s*(.+)$", [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return ""
}

function Get-PowerShellExePath {
  if ($PSVersionTable.PSEdition -eq "Core") {
    $exe = Join-Path $PSHOME "pwsh.exe"
  } else {
    $exe = Join-Path $PSHOME "powershell.exe"
  }
  if (-not (Test-Path $exe)) {
    if ($PSVersionTable.PSEdition -eq "Core") { return "pwsh.exe" }
    return "powershell.exe"
  }
  return $exe
}

function Get-AipackHomeFromFile {
  if ([string]::IsNullOrWhiteSpace($PSCommandPath)) { return "" }
  $scriptDir = Split-Path -Parent $PSCommandPath
  if ([string]::IsNullOrWhiteSpace($scriptDir)) { return "" }
  $homeFile = Join-Path $scriptDir "aipack.home"
  if (-not (Test-Path $homeFile)) { return "" }
  try {
    $line = Get-Content -Path $homeFile -TotalCount 1 -ErrorAction SilentlyContinue
    if ($null -eq $line) { return "" }
    return ([string]$line).Trim()
  } catch {
    return ""
  }
}

function Get-AipackHomeCandidate {
  $aipackHome = $env:AIPACK_HOME
  if ([string]::IsNullOrWhiteSpace($aipackHome)) {
    $aipackHome = [Environment]::GetEnvironmentVariable("AIPACK_HOME","User")
  }
  if ([string]::IsNullOrWhiteSpace($aipackHome)) {
    $aipackHome = Get-AipackHomeFromFile
  }
  return $aipackHome
}

function Resolve-AipackSourceRoot([string]$ScriptName) {
  $aipackHome = Get-AipackHomeCandidate
  if (-not [string]::IsNullOrWhiteSpace($aipackHome)) {
    $aipackHome = $aipackHome.Trim().Trim('"')
    $candidate = Join-Path $aipackHome $ScriptName
    if (Test-Path -LiteralPath $candidate) {
      try { return (Resolve-Path -LiteralPath $aipackHome).Path } catch { return $aipackHome }
    }
  }

  if (Get-Command git -ErrorAction SilentlyContinue) {
    $g = Try-Cmd "git" @("rev-parse","--show-toplevel")
    if ($g.Code -eq 0) {
      $root = $g.Out.Trim()
      if ($root) {
        $candidate = Join-Path $root $ScriptName
        if (Test-Path -LiteralPath $candidate) { return $root }
      }
    }
  }

  $dir = (Get-Location).Path
  for ($i = 0; $i -le 5; $i++) {
    $candidate = Join-Path $dir $ScriptName
    if (Test-Path -LiteralPath $candidate) { return $dir }
    $parent = Split-Path -Parent $dir
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) { break }
    $dir = $parent
  }

  throw "Could not find $ScriptName. Set AIPACK_HOME to your aipack repo root (example: `$env:AIPACK_HOME = 'D:\Projects\aipack'), or run this from inside the repo (git root or within 5 parent directories)."
}

function Get-InstallDirFromArgs([string[]]$Args, [string]$DefaultInstallDir) {
  if ($null -eq $Args) { return $DefaultInstallDir }
  for ($i = 0; $i -lt $Args.Count; $i++) {
    $a = $Args[$i]
    if ($null -eq $a) { continue }
    if ($a -match '^(?i)-InstallDir[:=](.+)$') { return $Matches[1].Trim('"') }
    if ($a -match '^(?i)-InstallDir$') {
      if ($i + 1 -lt $Args.Count) { return $Args[$i + 1].Trim('"') }
    }
  }
  return $DefaultInstallDir
}

function Invoke-AipackScript([string]$ScriptPath, [string[]]$ScriptArgs) {
  $psExe = Get-PowerShellExePath
  $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$ScriptPath)
  if ($ScriptArgs) { $args += $ScriptArgs }
  & $psExe @args
  return $LASTEXITCODE
}

function Write-Step([string]$Message) {
  $ts = (Get-Date).ToString("HH:mm:ss")
  Write-Host ("[$ts] " + $Message)
}

function New-AipackZip([string]$OutDir, [string]$ZipPath, [switch]$Force) {
  $parent = Split-Path -Parent $OutDir
  $leaf = Split-Path -Leaf $OutDir
  if ([string]::IsNullOrWhiteSpace($parent) -or [string]::IsNullOrWhiteSpace($leaf)) {
    throw "Invalid output directory for zip: $OutDir"
  }

  if ($Force -and (Test-Path $ZipPath)) { Remove-Item -Force $ZipPath }

  if (Get-Command Compress-Archive -ErrorAction SilentlyContinue) {
    Push-Location $parent
    try {
      Compress-Archive -Path $leaf -DestinationPath $ZipPath -Force
    } finally {
      Pop-Location
    }
  } else {
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
    if ($Force -and (Test-Path $ZipPath)) { Remove-Item -Force $ZipPath }
    try {
      [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $OutDir,
        $ZipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $true
      )
    } catch {
      [System.IO.Compression.ZipFile]::CreateFromDirectory($OutDir, $ZipPath)
    }
  }
}


function Sanitize-Remote([string]$Url) {
  if ([string]::IsNullOrWhiteSpace($Url)) { return "" }
  return ($Url -replace '://([^/@:]+):([^/@]+)@', '://***:***@')
}

function RelPathUnix([string]$Base, [string]$Full) {
  $rel = $Full.Substring($Base.Length).TrimStart('\','/')
  return ($rel -replace '\\','/')
}

function Show-Help {
  Write-Host ""
  Write-Host "aipack v$AIPACK_VERSION"
  Write-Host ""
  Write-Host "Usage:"
  Write-Host "  aipack                     (pack current repo)"
  Write-Host "  aipack <outFolderName>"
  Write-Host "  aipack -Install"
  Write-Host "  aipack -Reinstall"
  Write-Host "  aipack -Uninstall"
  Write-Host "  aipack help"
  Write-Host "  aipack list"
  Write-Host "  aipack doctor"
  Write-Host "  aipack validate <outDirOrZip>"
  Write-Host ""
  Write-Host "Management notes:"
  Write-Host "  -Reinstall locates the source repo via AIPACK_HOME (User)"
  Write-Host "  and falls back to git root or a 5-parent search when unset."
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  aipack"
  Write-Host "  aipack -Reinstall -SkipDeps -NoWarmup"
  Write-Host "  aipack -Uninstall -Yes"
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -NoZip             Disable zip generation"
  Write-Host "  -ZipOnly           Delete output folder after successful zip"
  Write-Host "  -Yes               Skip deletion prompt for -ZipOnly (still prints warning)"
  Write-Host "  -Zip               (deprecated) Create <outFolder>.zip next to the folder"
  Write-Host "  -Staged            Deprecated (patch.staged.diff is always written)"
  Write-Host "  -StrictTracked     Run repomix from git ls-files via --stdin (deterministic tracked-only pack)"
  Write-Host "  -PackUntracked     Additionally generate a repomix output for untracked files (see outputs)"
  Write-Host "  -NoRemote          Omit origin URL from REPO_INFO.md"
  Write-Host "  -Lean              Ignore common noisy outputs (preflight/mutations txt)"
  Write-Host "  -Compress          Pass --compress to repomix"
  Write-Host "  -OpenAPIUrl <url>  Fetch openapi.json (ex: http://127.0.0.1:8000/openapi.json)"
  Write-Host "  -ExtraIgnore <csv> Extra repomix ignore patterns, comma separated"
  Write-Host ""
  Write-Host "Outputs (inside the out folder):"
  Write-Host "  repomix-output.xml"
  Write-Host "  patch.unstaged.diff"
  Write-Host "  patch.staged.diff"
  Write-Host "  patch.diff (legacy alias of patch.unstaged.diff)"
  Write-Host "  REPO_INFO.md"
  Write-Host "  ASSET_MANIFEST.md"
  Write-Host "  AIPACK_NAV.md"
  Write-Host "  AIPACK_SUMMARY.txt"
  Write-Host "  aipack_included.txt"
  Write-Host "  git_tracked.txt"
  Write-Host "  aipack_missing_tracked.txt"
  Write-Host "  git_untracked.txt"
  Write-Host "  repomix-untracked.xml (only when -PackUntracked and untracked exist)"
  Write-Host ""
  Write-Host "Additional outputs (next to the out folder):"
  Write-Host "  <outFolder>.zip (unless -NoZip)"
  Write-Host ""
}

function Run-Doctor {
  Write-Host ""
  Write-Host "AIPACK doctor"
  Write-Host ("pwd: " + (Get-Location).Path)
  Write-Host ""
  $cmd = Get-Command aipack -ErrorAction SilentlyContinue
  if ($cmd) {
    $resolved = $(if ($cmd.Path) { $cmd.Path } else { $cmd.Definition })
    Write-Host ("aipack command: " + $resolved)
  } else {
    Write-Host "aipack command: (not found on PATH)"
  }

  $aipackHome = $env:AIPACK_HOME
  if ([string]::IsNullOrWhiteSpace($aipackHome)) {
    $aipackHome = [Environment]::GetEnvironmentVariable("AIPACK_HOME","User")
  }
  $homeLabel = $(if ([string]::IsNullOrWhiteSpace($aipackHome)) { "(not set)" } else { $aipackHome })
  Write-Host ("AIPACK_HOME: " + $homeLabel)
  if ([string]::IsNullOrWhiteSpace($aipackHome)) {
    Write-Host "AIPACK_HOME exists: n/a"
  } else {
    Write-Host ("AIPACK_HOME exists: " + ($(if (Test-Path -LiteralPath $aipackHome) {"yes"} else {"no"})))
  }

  $homeFile = ""
  if ($cmd -and $cmd.Path) {
    $homeFile = Join-Path (Split-Path -Parent $cmd.Path) "aipack.home"
  } else {
    $homeFile = Join-Path (Join-Path $env:USERPROFILE "bin") "aipack.home"
  }
  Write-Host ("aipack.home: " + $homeFile)
  Write-Host ("aipack.home exists: " + ($(if (Test-Path -LiteralPath $homeFile) {"yes"} else {"no"})))
  Write-Host ""
  Write-Host "where git:"; where.exe git
  Write-Host "where node:"; where.exe node
  Write-Host "where npm:"; where.exe npm
  Write-Host "where npx:"; where.exe npx
  Write-Host ""
  Write-Host "git version:"; git --version
  Write-Host "node version:"; node -v
  Write-Host "npm version:"; npm -v
  Write-Host "repomix version:"; npx.cmd --yes repomix@latest --version
  Write-Host ""
  $g = Try-Cmd "git" @("rev-parse","--is-inside-work-tree")
  Write-Host ("git repo: " + ($(if ($g.Code -eq 0) {"yes"} else {"no"})))
  if ($g.Code -eq 0) {
    Write-Host "git status -sb:"
    git status -sb
  }
  Write-Host ""
}

function Run-Validate([string]$TargetPath) {
  Write-Host ""
  Write-Host "AIPACK validate"
  if ([string]::IsNullOrWhiteSpace($TargetPath)) { throw "validate requires a path to an aipack output folder or zip." }
  $target = $TargetPath.Trim('"')

  $isDir = Test-Path -LiteralPath $target -PathType Container
  $isFile = Test-Path -LiteralPath $target -PathType Leaf
  if (-not $isDir -and -not $isFile) { throw "validate path not found: $target" }

  $repomixText = ""
  $repomixLabel = ""
  $repoInfoText = ""
  $missingFileText = $null
  $paths = @{
    included = "(missing)"
    tracked = "(missing)"
    missing = "(missing)"
    untracked = "(missing)"
  }

  if ($isDir) {
    $repomixPath = Join-Path $target "repomix-output.xml"
    if (-not (Test-Path -LiteralPath $repomixPath)) { throw "repomix-output.xml not found in $target" }
    $repomixText = Get-Content -Path $repomixPath -Raw -ErrorAction Stop
    $repomixLabel = $repomixPath

    $repoInfoPath = Join-Path $target "REPO_INFO.md"
    if (Test-Path -LiteralPath $repoInfoPath) { $repoInfoText = Get-Content -Path $repoInfoPath -Raw -ErrorAction SilentlyContinue }

    $includedPath = Join-Path $target "aipack_included.txt"
    $trackedPath = Join-Path $target "git_tracked.txt"
    $missingPath = Join-Path $target "aipack_missing_tracked.txt"
    $untrackedPath = Join-Path $target "git_untracked.txt"

    if (Test-Path -LiteralPath $includedPath) { $paths.included = $includedPath }
    if (Test-Path -LiteralPath $trackedPath) { $paths.tracked = $trackedPath }
    if (Test-Path -LiteralPath $missingPath) {
      $paths.missing = $missingPath
      $missingFileText = Get-Content -Path $missingPath -Raw -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $untrackedPath) { $paths.untracked = $untrackedPath }
  } else {
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue } catch { }
    $zip = [System.IO.Compression.ZipFile]::OpenRead($target)
    try {
      $repEntry = Find-ZipEntryBySuffix $zip "repomix-output.xml"
      if (-not $repEntry) { throw "repomix-output.xml not found in $target" }
      $repomixText = Read-ZipEntryText $repEntry
      $repomixLabel = "$target!$($repEntry.FullName)"

      $repoInfoEntry = Find-ZipEntryBySuffix $zip "REPO_INFO.md"
      if ($repoInfoEntry) { $repoInfoText = Read-ZipEntryText $repoInfoEntry }

      $includedEntry = Find-ZipEntryBySuffix $zip "aipack_included.txt"
      $trackedEntry = Find-ZipEntryBySuffix $zip "git_tracked.txt"
      $missingEntry = Find-ZipEntryBySuffix $zip "aipack_missing_tracked.txt"
      $untrackedEntry = Find-ZipEntryBySuffix $zip "git_untracked.txt"

      if ($includedEntry) { $paths.included = "$target!$($includedEntry.FullName)" }
      if ($trackedEntry) { $paths.tracked = "$target!$($trackedEntry.FullName)" }
      if ($missingEntry) {
        $paths.missing = "$target!$($missingEntry.FullName)"
        $missingFileText = Read-ZipEntryText $missingEntry
      }
      if ($untrackedEntry) { $paths.untracked = "$target!$($untrackedEntry.FullName)" }
    } finally {
      $zip.Dispose()
    }
  }

  $includedLines = Get-DirectoryStructureLinesFromXml $repomixText
  $includedCount = $includedLines.Count

  $trackedCountLabel = "tracked_count: (skipped)"
  $missingTrackedCountLabel = ""
  $repoPath = Get-RepoPathFromRepoInfoText $repoInfoText
  if (-not [string]::IsNullOrWhiteSpace($repoPath) -and (Test-Path -LiteralPath $repoPath)) {
    $g = Try-Cmd "git" @("-C",$repoPath,"rev-parse","--is-inside-work-tree")
    if ($g.Code -eq 0 -and $g.Out.Trim() -eq "true") {
      $tcmd = Try-Cmd "git" @("-C",$repoPath,"ls-files")
      if ($tcmd.Code -eq 0) {
        $trackedLines = $tcmd.Out -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -ne "" }
        $trackedLines = @($trackedLines | Sort-Object -Unique)
        $trackedCountLabel = "tracked_count: $($trackedLines.Count)"

        $includedLookup = @{}
        foreach ($line in $includedLines) { $includedLookup[$line] = $true }
        $missingLines = @()
        foreach ($line in $trackedLines) {
          if (-not $includedLookup.ContainsKey($line)) { $missingLines += $line }
        }
        $missingLines = @($missingLines | Sort-Object -Unique)
        $missingTrackedCountLabel = "missing_tracked_count: $($missingLines.Count)"
      }
    }
  }

  Write-Host ("target: " + $target)
  Write-Host ("repomix: " + $repomixLabel)
  Write-Host ("included_count: " + $includedCount)
  Write-Host $trackedCountLabel
  if ($missingTrackedCountLabel) { Write-Host $missingTrackedCountLabel }
  Write-Host ("aipack_included.txt: " + $paths.included)
  Write-Host ("git_tracked.txt: " + $paths.tracked)
  Write-Host ("aipack_missing_tracked.txt: " + $paths.missing)
  Write-Host ("git_untracked.txt: " + $paths.untracked)

  if ($null -ne $missingFileText) {
    $missingFileLines = $missingFileText -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -ne "" }
    $missingFileCount = $missingFileLines.Count
    Write-Host ("aipack_missing_tracked_count: " + $missingFileCount)
    if ($missingFileCount -gt 0) {
      Write-Host "aipack_missing_tracked_first20:"
      foreach ($line in ($missingFileLines | Select-Object -First 20)) {
        Write-Host ("- " + $line)
      }
    }
  }
}

if ($PSCmdlet.ParameterSetName -ne "Pack") {
  $defaultInstallDir = Join-Path $env:USERPROFILE "bin"
  $installDir = Get-InstallDirFromArgs $RemainingArgs $defaultInstallDir
  switch ($PSCmdlet.ParameterSetName) {
    "Install" {
      $root = Resolve-AipackSourceRoot "install.ps1"
      $scriptPath = Join-Path $root "install.ps1"
      Write-Host ""
      Write-Host "AIPACK install"
      Write-Host "from: $root"
      Write-Host "to:   $installDir"
      Write-Host ""
      $code = Invoke-AipackScript $scriptPath $RemainingArgs
      exit $code
    }
    "Reinstall" {
      $root = Resolve-AipackSourceRoot "install.ps1"
      $scriptPath = Join-Path $root "install.ps1"
      $dstPs1 = Join-Path $installDir "aipack.ps1"
      $dstCmd = Join-Path $installDir "aipack.cmd"
      $homeFile = Join-Path $installDir "aipack.home"
      Write-Host ""
      Write-Host "AIPACK reinstall"
      Write-Host "from: $root"
      Write-Host "to:   $installDir"
      Write-Host "will overwrite:"
      Write-Host "  $dstPs1"
      Write-Host "  $dstCmd"
      Write-Host "  $homeFile"
      Write-Host ""
      $childArgs = @("-Force","-SkipDeps","-NoWarmup")
      if ($RemainingArgs) { $childArgs += $RemainingArgs }
      $code = Invoke-AipackScript $scriptPath $childArgs
      exit $code
    }
    "Uninstall" {
      $root = Resolve-AipackSourceRoot "uninstall.ps1"
      $scriptPath = Join-Path $root "uninstall.ps1"
      $dstPs1 = Join-Path $installDir "aipack.ps1"
      $dstCmd = Join-Path $installDir "aipack.cmd"
      $homeFile = Join-Path $installDir "aipack.home"
      Write-Host ""
      Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      Write-Host "WARNING: AIPACK UNINSTALL"
      Write-Host "This will remove:"
      Write-Host "  $dstPs1"
      Write-Host "  $dstCmd"
      Write-Host "  $homeFile"
      Write-Host "And clear AIPACK_HOME (User environment variable)."
      Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      if (-not $Yes) {
        $confirm = Read-Host "Type DELETE to confirm uninstall"
        if ($confirm -ne "DELETE") {
          Write-Host "Uninstall canceled."
          exit 1
        }
      }
      Write-Host ""
      $code = Invoke-AipackScript $scriptPath $RemainingArgs
      exit $code
    }
  }
}

if ($PSCmdlet.ParameterSetName -eq "Pack") {
  $helpTokens = @("help","list","-h","--help","/?")
  $showHelp = $false
  if ($Arg -in $helpTokens) { $showHelp = $true }
  elseif ([string]::IsNullOrWhiteSpace($Arg) -and $RemainingArgs) {
    foreach ($t in $RemainingArgs) {
      if ($helpTokens -contains $t) { $showHelp = $true; break }
    }
  }
  if ($showHelp) { Show-Help; exit 0 }

  $showDoctor = $false
  if ($Arg -eq "doctor") { $showDoctor = $true }
  elseif ([string]::IsNullOrWhiteSpace($Arg) -and $RemainingArgs) {
    foreach ($t in $RemainingArgs) {
      if ($t -eq "doctor") { $showDoctor = $true; break }
    }
  }
  if ($showDoctor) { Run-Doctor; exit 0 }

  $showValidate = $false
  $validateTarget = ""
  if ($Arg -eq "validate") {
    $showValidate = $true
    if ($RemainingArgs -and $RemainingArgs.Count -gt 0) { $validateTarget = $RemainingArgs[0] }
  } elseif ([string]::IsNullOrWhiteSpace($Arg) -and $RemainingArgs) {
    for ($i = 0; $i -lt $RemainingArgs.Count; $i++) {
      if ($RemainingArgs[$i] -eq "validate") {
        $showValidate = $true
        if ($i + 1 -lt $RemainingArgs.Count) { $validateTarget = $RemainingArgs[$i + 1] }
        break
      }
    }
  }
  if ($showValidate) { Run-Validate $validateTarget; exit 0 }
}

if ($Arg -and [string]::IsNullOrWhiteSpace($OutName)) { $OutName = $Arg }

$invocationDir = (Get-Location).Path
$workDir = $invocationDir

if ([string]::IsNullOrWhiteSpace($RepoName)) { $RepoName = (Split-Path $workDir -Leaf) }

$tsUtc = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
if ([string]::IsNullOrWhiteSpace($OutName)) {
  $safeRepo = ($RepoName -replace '[^A-Za-z0-9._-]','_')
  $OutName = "_aipack_${safeRepo}_$tsUtc"
}

$outDir = Join-Path $invocationDir $OutName
$zipPath = "$outDir.zip"
$zipEnabled = -not $NoZip
if ($ZipOnly -and $NoZip) { throw "-ZipOnly cannot be used with -NoZip." }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Missing git in PATH." }
if (-not (Get-Command npx.cmd -ErrorAction SilentlyContinue)) { throw "Missing npx.cmd in PATH." }

Push-Location $workDir
try {
  Write-Step "aipack v$AIPACK_VERSION starting"
  Write-Step "Working dir: $workDir"
  Write-Step "Output dir: $outDir"
  Write-Step "Checking git repository"
  $inside = (Try-Cmd "git" @("rev-parse","--is-inside-work-tree")).Out.Trim()
  if ($inside -ne "true") { throw "Not a git repository: $workDir`n$inside" }

  Write-Step "Creating output dir"
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null

  Write-Step "Collecting git and environment metadata"
  $branch = (Try-Cmd "git" @("rev-parse","--abbrev-ref","HEAD")).Out.Trim()
  $sha = (Try-Cmd "git" @("rev-parse","HEAD")).Out.Trim()
  $statusShort = (Try-Cmd "git" @("status","-sb")).Out.TrimEnd()
  $porc = (Try-Cmd "git" @("status","--porcelain")).Out
  $dirty = -not [string]::IsNullOrWhiteSpace($porc)

  $origin = ""
  if (-not $NoRemote) {
    $o = Try-Cmd "git" @("remote","get-url","origin")
    if ($o.Code -eq 0) { $origin = Sanitize-Remote($o.Out.Trim()) }
  }

  $gitVer = (Try-Cmd "git" @("--version")).Out.Trim()
  $nodeVer = (Try-Cmd "node" @("-v")).Out.Trim()
  $npmVer = (Try-Cmd "npm" @("-v")).Out.Trim()
  $pyVer = ""
  if (Get-Command python -ErrorAction SilentlyContinue) { $pyVer = (Try-Cmd "python" @("--version")).Out.Trim() }
  elseif (Get-Command py -ErrorAction SilentlyContinue) { $pyVer = (Try-Cmd "py" @("-V")).Out.Trim() }
  $repomixVer = (Try-Cmd "npx.cmd" @("--yes","repomix@latest","--version")).Out.Trim()

  $startup = Join-Path $workDir "docs\STARTUP.md"
  $readme = Join-Path $workDir "README.md"

  $tracked = (Try-Cmd "git" @("ls-files")).Out -split "`n"
  $lockNeedles = @("package-lock.json","pnpm-lock.yaml","yarn.lock","bun.lockb","poetry.lock","Pipfile.lock","requirements.lock","requirements.txt")
  $lockHits = @()
  foreach ($n in $lockNeedles) {
    $m = $tracked | Where-Object { $_.Trim().ToLower().EndsWith($n.ToLower()) }
    if ($m) { $lockHits += $m }
  }
  $lockHits = $lockHits | Sort-Object -Unique

  $expected = @("LICENSE","LICENSE.md","LICENSE.txt","CHANGELOG.md","RELEASE_NOTES.md","CODE_OF_CONDUCT.md",".github/CODEOWNERS")
  $expectedStatus = foreach ($p in $expected) {
    $full = Join-Path $workDir ($p -replace '/','\')
    [pscustomobject]@{ Path = $p; Present = (Test-Path $full) }
  }

  $repoInfoLines = @()
  $repoInfoLines += "# REPO_INFO"
  $repoInfoLines += ""
  $repoInfoLines += "repo name: $RepoName"
  $repoInfoLines += "snapshot timestamp (UTC): $tsUtc"
  $repoInfoLines += "packed from: $workDir"
  $repoInfoLines += "aipack version: $AIPACK_VERSION"
  $repoInfoLines += "repomix: $repomixVer"
  if ($pyVer) { $repoInfoLines += "python: $pyVer" }
  $repoInfoLines += "node: $nodeVer"
  $repoInfoLines += "npm: $npmVer"
  $repoInfoLines += "git: $gitVer"
  $repoInfoLines += ""
  $repoInfoLines += "git branch: $branch"
  $repoInfoLines += "git commit: $sha"
  $repoInfoLines += ("working tree dirty: " + ($(if ($dirty) {"yes"} else {"no"})))
  if (-not $NoRemote) {
    $repoInfoLines += ("origin url: " + ($(if ($origin) {$origin} else {"(none)"})))
  } else {
    $repoInfoLines += "origin url: (omitted)"
  }
  $repoInfoLines += ""
  $repoInfoLines += "git status:"
  $repoInfoLines += '```'
  $repoInfoLines += $statusShort
  $repoInfoLines += '```'
  $repoInfoLines += ""
  $repoInfoLines += "recent commits:"
  $repoInfoLines += '```'
  $repoInfoLines += (Try-Cmd "git" @("log","-5","--oneline","--decorate")).Out.TrimEnd()
  $repoInfoLines += '```'
  $repoInfoLines += ""
  $repoInfoLines += "how to run pointers:"
  $repoInfoLines += ("- docs/STARTUP.md: " + ($(if (Test-Path $startup) {"present"} else {"missing"})))
  $repoInfoLines += ("- README.md: " + ($(if (Test-Path $readme) {"present"} else {"missing"})))
  $repoInfoLines += ""
  $repoInfoLines += "lockfiles tracked in git:"
  if ($lockHits.Count -gt 0) { foreach ($h in $lockHits) { $repoInfoLines += "- $h" } }
  else { $repoInfoLines += "- (none found)" }
  $repoInfoLines += ""
  $repoInfoLines += "common shareable files present:"
  foreach ($e in $expectedStatus) { $repoInfoLines += ("- " + $e.Path + ": " + ($(if ($e.Present) {"present"} else {"missing"}))) }

  $repoInfoPath = Join-Path $outDir "REPO_INFO.md"
  Write-Step "Writing REPO_INFO.md"
  Write-Utf8NoBom $repoInfoPath ($repoInfoLines -join "`n")

  $injectPath = Join-Path $outDir "AIPACK_INSTRUCTIONS.md"
  Write-Step "Writing AIPACK_INSTRUCTIONS.md"
  $injectLines = @()
  $injectLines += "AIPACK snapshot metadata"
  $injectLines += ""
  $injectLines += "repo: $RepoName"
  $injectLines += "utc: $tsUtc"
  $injectLines += "branch: $branch"
  $injectLines += "commit: $sha"
  $injectLines += ("dirty: " + ($(if ($dirty) {"yes"} else {"no"})))
  $injectLines += ""
  $injectLines += "Notes for AI:"
  $injectLines += "- Start with AIPACK_NAV.md. It is the first file to read for this snapshot."
  $injectLines += "- Check aipack_missing_tracked.txt first for tracked files missing from repomix."
  if ($zipEnabled) {
    $injectLines += "- Zip archive: $zipPath. Upload the zip to ChatGPT for best results."
  } else {
    $injectLines += "- Zip archive: $zipPath (disabled by -NoZip). Upload the zip to ChatGPT when available."
  }
  $injectLines += "- repomix-output.xml is the packed snapshot of this folder."
  $injectLines += "- patch.unstaged.diff contains unstaged changes; patch.staged.diff contains staged changes."
  $injectLines += "- patch.diff exists only for legacy compatibility (same as patch.unstaged.diff)."
  $injectLines += "- See REPO_INFO.md for full environment and repo metadata."
  Write-Utf8NoBom $injectPath ($injectLines -join "`n")

  $patchUnstagedPath = Join-Path $outDir "patch.unstaged.diff"
  $patchStagedPath = Join-Path $outDir "patch.staged.diff"
  $patchLegacyPath = Join-Path $outDir "patch.diff"

  Write-Step "Writing patch.unstaged.diff"
  $diff = Try-Cmd "git" @("diff","--no-color")
  if ($diff.Code -ne 0) { throw "git diff failed." }
  Write-Utf8NoBom $patchUnstagedPath $diff.Out

  Write-Step "Writing patch.staged.diff"
  $sdiff = Try-Cmd "git" @("diff","--staged","--no-color")
  if ($sdiff.Code -ne 0) { throw "git diff --staged failed." }
  Write-Utf8NoBom $patchStagedPath $sdiff.Out

  Write-Step "Writing patch.diff (legacy)"
  Write-Utf8NoBom $patchLegacyPath $diff.Out

  $patchPath = $patchUnstagedPath

  if (-not [string]::IsNullOrWhiteSpace($OpenAPIUrl)) {
    $openApiPath = Join-Path $outDir "openapi.json"
    Write-Step "Fetching OpenAPI: $OpenAPIUrl"
    try {
      $resp = Invoke-WebRequest -Uri $OpenAPIUrl -TimeoutSec 10
      if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
        Write-Utf8NoBom $openApiPath $resp.Content
      }
    } catch { }
  }

  $repomixOut = Join-Path $outDir "repomix-output.xml"

  $ignore = New-Object System.Collections.Generic.List[string]
  $ignore.Add("$OutName/**") | Out-Null
  $ignore.Add("_aipack_*/**") | Out-Null
  $ignore.Add("_ai_pack_*/**") | Out-Null
  if ($Lean) {
    $ignore.Add("preflight_output*.txt") | Out-Null
    $ignore.Add("**/preflight_output*.txt") | Out-Null
    $ignore.Add("mutations_output*.txt") | Out-Null
    $ignore.Add("**/mutations_output*.txt") | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($ExtraIgnore)) {
    foreach ($p in ($ExtraIgnore -split ",")) {
      $t = $p.Trim()
      if ($t) { $ignore.Add($t) | Out-Null }
    }
  }

  $repArgs = New-Object System.Collections.Generic.List[string]
  if ($Compress) { $repArgs.Add("--compress") | Out-Null }
  $repArgs.Add("-o") | Out-Null
  $repArgs.Add($repomixOut) | Out-Null
  $repArgs.Add("--instruction-file-path") | Out-Null
  $repArgs.Add($injectPath) | Out-Null
  $repArgs.Add("--ignore") | Out-Null
  $repArgs.Add(($ignore | Select-Object -Unique) -join ",") | Out-Null

  Write-Step "Running repomix (this can take a while)"
  if ($StrictTracked) {
    Write-Step "Collecting tracked files for strict pack"
    $trackedCmd = Try-Cmd "git" @("ls-files")
    if ($trackedCmd.Code -ne 0) { throw "git ls-files failed.`n$trackedCmd" }
    $trackedText = $trackedCmd.Out
    if ([string]::IsNullOrWhiteSpace($trackedText)) { throw "git ls-files returned no files." }
    $r = Try-CmdStdin "npx.cmd" (@("--yes","repomix@latest","--stdin") + $repArgs.ToArray()) $trackedText
  } else {
    $r = Try-Cmd "npx.cmd" (@("--yes","repomix@latest") + $repArgs.ToArray())
  }
  if ($r.Code -ne 0) { throw "repomix failed.`n$r" }

  Write-Step "Generating audit files"
  $includedLines = @()
  if (Test-Path $repomixOut) {
    try {
      $repomixText = Get-Content -Path $repomixOut -Raw -ErrorAction Stop
      $includedLines = Get-DirectoryStructureLinesFromXml $repomixText
    } catch { }
  }
  $includedLines = @($includedLines | Sort-Object -Unique)
  $includedPath = Join-Path $outDir "aipack_included.txt"
  Write-Utf8NoBom $includedPath ($includedLines -join "`n")

  $trackedAuditCmd = Try-Cmd "git" @("ls-files")
  if ($trackedAuditCmd.Code -ne 0) { throw "git ls-files failed.`n$trackedAuditCmd" }
  $trackedLines = $trackedAuditCmd.Out -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -ne "" }
  $trackedLines = @($trackedLines | Sort-Object -Unique)
  $trackedPath = Join-Path $outDir "git_tracked.txt"
  Write-Utf8NoBom $trackedPath ($trackedLines -join "`n")

  $includedLookup = @{}
  foreach ($line in $includedLines) { $includedLookup[$line] = $true }
  $missingLines = @()
  foreach ($line in $trackedLines) {
    if (-not $includedLookup.ContainsKey($line)) { $missingLines += $line }
  }
  $missingLines = @($missingLines | Sort-Object -Unique)
  $missingPath = Join-Path $outDir "aipack_missing_tracked.txt"
  Write-Utf8NoBom $missingPath ($missingLines -join "`n")

  $untrackedCmd = Try-Cmd "git" @("ls-files","--others","--exclude-standard")
  if ($untrackedCmd.Code -ne 0) { throw "git ls-files --others failed.`n$untrackedCmd" }
  $untrackedLines = $untrackedCmd.Out -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -ne "" }
  $untrackedLines = @($untrackedLines | Sort-Object -Unique)
  $untrackedPath = Join-Path $outDir "git_untracked.txt"
  Write-Utf8NoBom $untrackedPath ($untrackedLines -join "`n")

  $includedCount = $includedLines.Count
  $missingTrackedCount = $missingLines.Count
  $untrackedCount = $untrackedLines.Count
  $untrackedPackWritten = $false
  $untrackedPackStatus = "untracked_pack: disabled"

  if ($PackUntracked) {
    $untrackedPackStatus = "untracked_pack: skipped"
    $untrackedInput = @()
    foreach ($line in $untrackedLines) {
      $rel = $line.Trim()
      if (-not $rel) { continue }
      if ($rel -eq $OutName -or $rel.StartsWith("$OutName/") -or $rel.StartsWith("$OutName\")) { continue }
      $full = Join-Path $workDir ($rel -replace '/','\')
      if (Test-Path -LiteralPath $full) { $untrackedInput += $rel }
    }
    $untrackedInput = @($untrackedInput | Sort-Object -Unique)
    if ($untrackedInput.Count -eq 0) {
      $untrackedPackStatus = "untracked_pack: skipped (no untracked files)"
    } else {
      $untrackedPackPath = Join-Path $outDir "repomix-untracked.xml"
      $untrackedPackErrorPath = Join-Path $outDir "repomix-untracked.error.txt"
      Write-Step "Running repomix for untracked files"
      $stdinText = ($untrackedInput -join "`n")
      if (-not $stdinText.EndsWith("`n")) { $stdinText += "`n" }
      $repArgsUntracked = New-Object System.Collections.Generic.List[string]
      if ($Compress) { $repArgsUntracked.Add("--compress") | Out-Null }
      $repArgsUntracked.Add("-o") | Out-Null
      $repArgsUntracked.Add($untrackedPackPath) | Out-Null
      $repArgsUntracked.Add("--instruction-file-path") | Out-Null
      $repArgsUntracked.Add($injectPath) | Out-Null
      $repArgsUntracked.Add("--ignore") | Out-Null
      $repArgsUntracked.Add(($ignore | Select-Object -Unique) -join ",") | Out-Null
      $rUntracked = Try-CmdStdin "npx.cmd" (@("--yes","repomix@latest","--stdin") + $repArgsUntracked.ToArray()) $stdinText
      if ($rUntracked.Code -ne 0) {
        $errLines = @()
        $errLines += "repomix untracked pack failed"
        $errLines += "exit_code: $($rUntracked.Code)"
        if ($rUntracked.Out) {
          $errLines += ""
          $errLines += $rUntracked.Out.TrimEnd()
        }
        Write-Utf8NoBom $untrackedPackErrorPath ($errLines -join "`n")
        $untrackedPackStatus = "untracked_pack: failed (see repomix-untracked.error.txt)"
      } else {
        $untrackedPackWritten = $true
        $untrackedPackStatus = "untracked_pack: written"
      }
    }
  }

  $assetLines = @()
  $assetLines += "# ASSET_MANIFEST"
  $assetLines += ""
  $assetLines += "Common UI assets and whether they appear in repomix-output.xml."
  $assetLines += ""

  $assetPaths = New-Object System.Collections.Generic.List[string]
  $assetPaths.Add("web/static/favicon.ico") | Out-Null

  $staticDir = Join-Path $workDir "web\static"
  if (Test-Path $staticDir) {
    $cands = Get-ChildItem -Path $staticDir -Recurse -File -Include *.ico,*.svg -ErrorAction SilentlyContinue | Select-Object -First 50
    foreach ($f in $cands) { $assetPaths.Add((RelPathUnix $workDir $f.FullName)) | Out-Null }
  }

  $assetPaths = @($assetPaths | Sort-Object -Unique)
  $inPackLookup = @{}
  if ($assetPaths.Count -gt 0 -and (Test-Path $repomixOut)) {
    Write-Step "Scanning repomix output for assets"
    try {
      $pattern = ($assetPaths | ForEach-Object { [regex]::Escape($_) }) -join "|"
      if ($pattern) {
        $matches = Select-String -Path $repomixOut -Pattern $pattern -AllMatches -ErrorAction Stop
        foreach ($m in $matches) {
          foreach ($hit in $m.Matches) { $inPackLookup[$hit.Value] = $true }
        }
      }
    } catch { }
  }
  foreach ($ap in $assetPaths) {
    $exists = Test-Path (Join-Path $workDir ($ap -replace '/','\'))
    $inPack = $false
    if ($inPackLookup.ContainsKey($ap)) { $inPack = $true }
    $assetLines += ("- " + $ap + " | exists=" + ($(if ($exists) {"yes"} else {"no"})) + " | in-repomix=" + ($(if ($inPack) {"yes"} else {"no"})))
  }
  $assetLines += ""
  $assetLines += "## Output archive"
  if ($zipEnabled) {
    $assetLines += ("- zip: " + $zipPath)
  } else {
    $assetLines += ("- zip: " + $zipPath + " (disabled)")
  }

  $assetPath = Join-Path $outDir "ASSET_MANIFEST.md"
  Write-Step "Writing ASSET_MANIFEST.md"
  Write-Utf8NoBom $assetPath ($assetLines -join "`n")

  $navPath = Join-Path $outDir "AIPACK_NAV.md"
  Write-Step "Writing AIPACK_NAV.md"
  $navLines = @()
  $navLines += "# AIPACK_NAV.md"
  $navLines += "Start here. This file is the map for the snapshot."
  $navLines += ""
  $navLines += "## Snapshot metadata"
  $navLines += "repo: $RepoName"
  $navLines += "utc: $tsUtc"
  $navLines += "branch: $branch"
  $navLines += "commit: $sha"
  $navLines += ("dirty: " + ($(if ($dirty) {"yes"} else {"no"})))
  $navLines += "workdir: $workDir"
  $navLines += "outDir: $outDir"
  if ($zipEnabled) {
    $navLines += "zip: $zipPath"
  } else {
    $navLines += "zip: $zipPath (disabled)"
  }
  $navArtifacts = @("repomix-output.xml","patch.unstaged.diff","patch.staged.diff")
  $navArtifacts += "REPO_INFO.md"
  $navArtifacts += "ASSET_MANIFEST.md"
  $navArtifacts += "AIPACK_SUMMARY.txt"
  $navArtifacts += "AIPACK_INSTRUCTIONS.md"
  $navArtifacts += "aipack_included.txt"
  $navArtifacts += "git_tracked.txt"
  $navArtifacts += "aipack_missing_tracked.txt"
  $navArtifacts += "git_untracked.txt"
  if ($untrackedPackWritten) { $navArtifacts += "repomix-untracked.xml" }
  $navLines += ("artifacts: " + ($navArtifacts -join ", "))
  if ($zipEnabled) {
    $navLines += "note: this pack is best consumed via the zip archive next to outDir."
  } else {
    $navLines += "note: zip output was disabled for this run."
  }

  if ($dirty) {
    $navLines += ""
    $navLines += "## What changed"
    $porcLines = @()
    if (-not [string]::IsNullOrWhiteSpace($porc)) {
      $porcLines = $porc -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -ne "" }
    }
    $maxChanges = 50
    $truncated = $false
    if ($porcLines.Count -gt $maxChanges) {
      $porcLines = $porcLines | Select-Object -First $maxChanges
      $truncated = $true
    }
    foreach ($line in $porcLines) { $navLines += ("- " + $line) }
    if ($truncated) { $navLines += "- (truncated)" }
    $navLines += "Details: patch.unstaged.diff and patch.staged.diff."
  }

  $navLines += ""
  $navLines += "## Project type and how to run"
  $projCount = 0
  $hasNode = Test-Path (Join-Path $workDir "package.json")
  $hasPyProject = Test-Path (Join-Path $workDir "pyproject.toml")
  $hasReqs = Test-Path (Join-Path $workDir "requirements.txt")
  $hasDotnet = $false
  if (Get-ChildItem -Path $workDir -File -Filter "*.sln" -ErrorAction SilentlyContinue | Select-Object -First 1) { $hasDotnet = $true }
  elseif (Get-ChildItem -Path $workDir -File -Filter "*.csproj" -ErrorAction SilentlyContinue | Select-Object -First 1) { $hasDotnet = $true }
  $hasGo = Test-Path (Join-Path $workDir "go.mod")
  $hasRust = Test-Path (Join-Path $workDir "Cargo.toml")
  $hasMaven = Test-Path (Join-Path $workDir "pom.xml")
  $hasGradle = Test-Path (Join-Path $workDir "build.gradle")

  if ($hasNode) {
    if ($projCount -gt 0) { $navLines += "" }
    $navLines += "### Node"
    $navLines += "Suggested commands:"
    $navLines += "~~~sh"
    $navLines += "npm install"
    $navLines += "npm test"
    $navLines += "npm run build"
    $navLines += "~~~"
    $projCount++
  }

  if ($hasPyProject -or $hasReqs) {
    if ($projCount -gt 0) { $navLines += "" }
    $navLines += "### Python"
    $navLines += "Suggested commands:"
    $navLines += "~~~sh"
    $navLines += "python -m venv .venv"
    if ($hasReqs) { $navLines += "pip install -r requirements.txt" }
    else { $navLines += "pip install -e ." }
    $navLines += "python -m pytest"
    $navLines += "~~~"
    $projCount++
  }

  if ($hasDotnet) {
    if ($projCount -gt 0) { $navLines += "" }
    $navLines += "### Dotnet"
    $navLines += "Suggested commands:"
    $navLines += "~~~sh"
    $navLines += "dotnet restore"
    $navLines += "dotnet build"
    $navLines += "dotnet test"
    $navLines += "~~~"
    $projCount++
  }

  if ($hasGo) {
    if ($projCount -gt 0) { $navLines += "" }
    $navLines += "### Go"
    $navLines += "Suggested commands:"
    $navLines += "~~~sh"
    $navLines += "go test ./..."
    $navLines += "go build ./..."
    $navLines += "go run ."
    $navLines += "~~~"
    $projCount++
  }

  if ($hasRust) {
    if ($projCount -gt 0) { $navLines += "" }
    $navLines += "### Rust"
    $navLines += "Suggested commands:"
    $navLines += "~~~sh"
    $navLines += "cargo build"
    $navLines += "cargo test"
    $navLines += "cargo run"
    $navLines += "~~~"
    $projCount++
  }

  if ($hasMaven -or $hasGradle) {
    if ($projCount -gt 0) { $navLines += "" }
    if ($hasMaven -and -not $hasGradle) { $navLines += "### Java (Maven)" }
    elseif ($hasGradle -and -not $hasMaven) { $navLines += "### Java (Gradle)" }
    else { $navLines += "### Java" }
    $navLines += "Suggested commands:"
    $navLines += "~~~sh"
    if ($hasGradle) {
      $navLines += "gradle test"
      $navLines += "gradle build"
      $navLines += "gradle run"
    } else {
      $navLines += "mvn test"
      $navLines += "mvn package"
      $navLines += "mvn clean install"
    }
    $navLines += "~~~"
    $projCount++
  }

  if ($projCount -eq 0) {
    $navLines += "No common project files detected at repo root."
  }

  Write-Utf8NoBom $navPath ($navLines -join "`n")

  $deleteConfirmed = $false
  if ($ZipOnly) {
    Write-Host "WARNING: -ZipOnly will delete the output folder after the zip is created."
    if ($Yes) {
      $deleteConfirmed = $true
    } else {
      $confirm = Read-Host "Type DELETE to confirm deleting $outDir after zip creation"
      if ($confirm -eq "DELETE") { $deleteConfirmed = $true }
      else { Write-Host "Deletion canceled; keeping $outDir" }
    }
  }

  $folderDisposition = $(if ($ZipOnly -and $deleteConfirmed) { "deleted" } else { "retained" })
  $zipLabel = $(if ($zipEnabled) { $zipPath } else { "$zipPath (disabled)" })

  $sumBase = @()
  $sumBase += "AIPACK complete"
  $sumBase += "outDir: $outDir"
  $sumBase += "nav: $navPath"
  $sumBase += "repomix: $repomixOut"
  $sumBase += "diff: $patchPath"
  $sumBase += "staged diff: $patchStagedPath"
  $unstagedBytes = 0
  $stagedBytes = 0
  try { $unstagedBytes = (Get-Item -LiteralPath $patchPath -ErrorAction Stop).Length } catch { }
  try { $stagedBytes = (Get-Item -LiteralPath $patchStagedPath -ErrorAction Stop).Length } catch { }
  $sumBase += "unstaged_diff_bytes: $unstagedBytes"
  $sumBase += "staged_diff_bytes: $stagedBytes"
  $sumBase += "included_count: $includedCount"
  $sumBase += "missing_tracked_count: $missingTrackedCount"
  $sumBase += "untracked_count: $untrackedCount"
  $sumBase += $untrackedPackStatus
  $sum = $sumBase + @("zip: $zipLabel","folder: $folderDisposition")
  $sumPath = Join-Path $outDir "AIPACK_SUMMARY.txt"
  Write-Step "Writing AIPACK_SUMMARY.txt"
  Write-Utf8NoBom $sumPath ($sum -join "`n")

  $zipOk = $false
  if ($zipEnabled) {
    Write-Step "Creating zip archive"
    try {
      New-AipackZip -OutDir $outDir -ZipPath $zipPath -Force
      $zipInfo = Get-Item -LiteralPath $zipPath -ErrorAction SilentlyContinue
      if ($zipInfo -and $zipInfo.Length -gt 0) {
        $zipOk = $true
        Write-Host "Wrote $zipPath"
      } else {
        throw "Zip archive missing or empty: $zipPath"
      }
    } catch {
      $sum = $sumBase + @("zip: $zipPath (failed)","folder: retained")
      Write-Utf8NoBom $sumPath ($sum -join "`n")
      throw
    }
  }

  if ($zipOk -and $ZipOnly -and $deleteConfirmed) {
    Write-Host "WARNING: Deleting output folder $outDir after zip success."
    Remove-Item -LiteralPath $outDir -Recurse -Force
    Write-Host "Deleted $outDir"
  } elseif (-not ($ZipOnly -and $deleteConfirmed)) {
    Write-Host "Wrote $outDir"
  }

} finally {
  Pop-Location
}
