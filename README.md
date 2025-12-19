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

## Update
git pull
.\install.ps1 -Force

## Uninstall
.\uninstall.ps1
