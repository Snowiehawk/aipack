# aipack

Creates an AI friendly snapshot of the current git repo folder:
- repomix-output.xml
- patch.diff (git diff --no-color)
- REPO_INFO.md and other metadata (depends on script version)

## Install
In PowerShell from this repo folder:
.\install.ps1

Open a new terminal:
aipack help

## Progress and timing
- During repomix, aipack shows a live PowerShell progress indicator with elapsed time and `files: X/Y`.
- Percent is based on files packed so far vs expected files (tracked + untracked non-ignored).
- If repomix skips some files (for example binaries), the percent is an estimate, but it should stay close.
- After repomix completes, aipack prints: `repomix finished in HH:MM:SS`
- At the end of a successful run, aipack prints: `Finished in HH:MM:SS`
- `AIPACK_SUMMARY.txt` includes:
  - `elapsed_pack: HH:MM:SS`
  - `repomix_elapsed: HH:MM:SS`
- Running PowerShell with `-Verbose` passes through to repomix as `--verbose`.

### Manual test
From repo root:
```powershell
.\install.ps1 -Force
aipack -Verbose
```
Confirm you see the repomix progress indicator and both timing lines:
- `repomix finished in HH:MM:SS`
- `Finished in HH:MM:SS`

## Update
git pull
.\install.ps1 -Force

## Uninstall
.\uninstall.ps1

Installer now ensures git + node are installed (winget preferred, official installers as fallback).
