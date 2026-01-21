param(
  [Parameter(Position=0)]
  [string]$Arg = "",
  [Alias("Name")]
  [string]$OutName = "",
  [string]$RepoName = "",
  [switch]$Zip,
  [switch]$Staged,
  [switch]$NoRemote,
  [switch]$Lean,
  [string]$OpenAPIUrl = "",
  [switch]$Compress,
  [string]$ExtraIgnore = ""
)

$AIPACK_VERSION = "0.3.1"

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

function Write-Step([string]$Message) {
  $ts = (Get-Date).ToString("HH:mm:ss")
  Write-Host ("[$ts] " + $Message)
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
  Write-Host "Usage (run from the repo folder you want packed):"
  Write-Host "  aipack"
  Write-Host "  aipack <outFolderName>"
  Write-Host "  aipack help"
  Write-Host "  aipack list"
  Write-Host "  aipack doctor"
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -Zip               Create <outFolder>.zip next to the folder"
  Write-Host "  -Staged            Also write patch.staged.diff"
  Write-Host "  -NoRemote          Omit origin URL from REPO_INFO.md"
  Write-Host "  -Lean              Ignore common noisy outputs (preflight/mutations txt)"
  Write-Host "  -Compress          Pass --compress to repomix"
  Write-Host "  -OpenAPIUrl <url>  Fetch openapi.json (ex: http://127.0.0.1:8000/openapi.json)"
  Write-Host "  -ExtraIgnore <csv> Extra repomix ignore patterns, comma separated"
  Write-Host ""
  Write-Host "Outputs (inside the out folder):"
  Write-Host "  repomix-output.xml"
  Write-Host "  patch.diff (plus patch.staged.diff if -Staged)"
  Write-Host "  REPO_INFO.md"
  Write-Host "  ASSET_MANIFEST.md"
  Write-Host "  AIPACK_SUMMARY.txt"
  Write-Host ""
}

function Run-Doctor {
  Write-Host ""
  Write-Host "AIPACK doctor"
  Write-Host ("pwd: " + (Get-Location).Path)
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

if ($Arg -in @("help","list","-h","--help","/?")) { Show-Help; exit 0 }
if ($Arg -eq "doctor") { Run-Doctor; exit 0 }

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
  $injectLines += "- repomix-output.xml is the packed snapshot of this folder."
  $injectLines += "- patch.diff (and optional patch.staged.diff) contain git diffs from this same snapshot."
  $injectLines += "- See REPO_INFO.md for full environment and repo metadata."
  Write-Utf8NoBom $injectPath ($injectLines -join "`n")

  $patchPath = Join-Path $outDir "patch.diff"
  Write-Step "Writing patch.diff"
  $diff = Try-Cmd "git" @("diff","--no-color")
  if ($diff.Code -ne 0) { throw "git diff failed." }
  Write-Utf8NoBom $patchPath $diff.Out

  if ($Staged) {
    Write-Step "Writing patch.staged.diff"
    $stagedPath = Join-Path $outDir "patch.staged.diff"
    $sdiff = Try-Cmd "git" @("diff","--cached","--no-color")
    if ($sdiff.Code -eq 0) { Write-Utf8NoBom $stagedPath $sdiff.Out }
  }

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
  $r = Try-Cmd "npx.cmd" (@("--yes","repomix@latest") + $repArgs.ToArray())
  if ($r.Code -ne 0) { throw "repomix failed.`n$r" }

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

  $assetPath = Join-Path $outDir "ASSET_MANIFEST.md"
  Write-Step "Writing ASSET_MANIFEST.md"
  Write-Utf8NoBom $assetPath ($assetLines -join "`n")

  $sum = @()
  $sum += "AIPACK complete"
  $sum += "outDir: $outDir"
  $sum += "repomix: $repomixOut"
  $sum += "diff: $patchPath"
  if ($Staged) { $sum += "staged diff: " + (Join-Path $outDir "patch.staged.diff") }
  $sumPath = Join-Path $outDir "AIPACK_SUMMARY.txt"
  Write-Step "Writing AIPACK_SUMMARY.txt"
  Write-Utf8NoBom $sumPath ($sum -join "`n")

  if ($Zip) {
    Write-Step "Creating zip archive"
    $zipPath = Join-Path $invocationDir ($OutName + ".zip")
    if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
    Compress-Archive -Path (Join-Path $outDir "*") -DestinationPath $zipPath -Force
    Write-Host "Wrote $zipPath"
  } else {
    Write-Host "Wrote $outDir"
  }

} finally {
  Pop-Location
}
