# aipack

Creates an AI friendly snapshot of the current git repo folder:
- repomix-output.xml
- patch.unstaged.diff and patch.staged.diff (plus legacy patch.diff)
- REPO_INFO.md and other metadata (depends on script version)

## Trustworthiness
- aipack_included.txt lists the file paths repomix saw for this pack.
- aipack_missing_tracked.txt lists git-tracked files that did not make it into the repomix pack.
- git_untracked.txt lists files that exist but are not tracked by git, so diffs will not include them.
- Diffs are split into patch.unstaged.diff and patch.staged.diff for clarity.
- -StrictTracked makes the pack deterministic by packing exactly what `git ls-files` reports.
- -PackUntracked adds untracked file contents into a separate pack (optional).

## Install
In PowerShell from this repo folder:
.\install.ps1

Open a new terminal:
aipack help

## Update
git pull
.\install.ps1 -Force

## Uninstall
.\uninstall.ps1

Installer now ensures git + node are installed (winget preferred, official installers as fallback).

