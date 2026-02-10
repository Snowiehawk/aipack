# aipack

Creates an AI friendly snapshot of the current git repository.
By default, `aipack` packs from the git repo root (even if invoked from a subfolder).
Use `-FromCwd` to keep legacy current-directory scope.

Core outputs:
- repomix-output.xml
- patch.unstaged.diff and patch.staged.diff (plus legacy patch.diff)
- REPO_INFO.md and other metadata (depends on script version)

## Trustworthiness
- `aipack_included.txt` lists file paths repomix actually emitted (`<file path="...">`).
- `aipack_missing_tracked.txt` lists git-tracked files that did not make it into the repomix pack.
- `git_untracked.txt` lists files that exist but are not tracked by git, so diffs will not include them.
- Diffs are split into patch.unstaged.diff and patch.staged.diff for clarity.
- `-StrictTracked` attempts tracked-only stdin packing; if stdin nested-path support is broken, aipack auto-falls back to non-stdin mode and records that downgrade in outputs.
- Coverage gate is enabled by default: pack fails if tracked coverage is below `85%`.
- Configure gate with `-MinTrackedCoveragePct <0-100>` or disable with `-NoCoverageGate`.
- `-PackUntracked` adds untracked file contents into a separate pack (optional).

## Troubleshooting
If coverage gate fails:
1. Run `aipack validate <outDirOrZip>`.
2. Inspect `aipack_missing_tracked.txt` in that pack.
3. Check `AIPACK_SUMMARY.txt` for `strict_mode`, `tracked_coverage_pct`, and `coverage_gate`.

## Install
In PowerShell from this repo folder:
`./install.ps1`

Open a new terminal:
`aipack help`

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
- `aipack` pins repomix to `repomix@1.9.0` by default for stability.
- Set `AIPACK_REPOMIX_SPEC` to override the package spec (for example `repomix@latest`).

### Manual test
From repo root:
```powershell
./install.ps1 -Force
aipack -Verbose
```
Confirm you see the repomix progress indicator and both timing lines:
- `repomix finished in HH:MM:SS`
- `Finished in HH:MM:SS`

## Update
`git pull`
`./install.ps1 -Force`

## Uninstall
`./uninstall.ps1`

Installer now ensures git + node are installed (winget preferred, official installers as fallback).
