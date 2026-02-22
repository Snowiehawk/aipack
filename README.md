# aipack

AIPACK creates an AI-facing repository snapshot where the effective packaging boundary is `repomix-output.xml`.

## Install
In PowerShell from this repo folder:

```powershell
.\install.ps1
```

Open a new terminal, then run:

```powershell
aipack help
```

## Directory semantics
- Target repo: the git repository you run `aipack` against.
- Output dir: always inside target repo root (default `_aipack_<repo>_<utc>`).
- Staging dir: temporary OS temp folder outside the repo, deleted after run.
- Pack mode never reads/writes from the install directory.

## Modes
- Default (`aipack`): full snapshot.
- Full snapshot includes tracked + untracked non-ignored files.
- `-TrackedOnly`: full snapshot but tracked only.
- `-LegacyFiltered`: opt-in old filtered behavior.
- `-AllowMissingTracked`: do not hard-fail when tracked files are missing from `repomix-output.xml`.

Compatibility aliases:
- `-StrictTracked`: deprecated alias for `-TrackedOnly`.
- `-PackUntracked`: deprecated compatibility alias (default already includes untracked).

## Missing tracked enforcement
- Full snapshot mode: missing tracked files are a hard failure by default.
- Legacy filtered mode: warning by default (non-fatal).
- Legacy strict opt-in: `-LegacyFiltered -TrackedOnly` enables hard failure.
- `-AllowMissingTracked` disables hard failure in any mode.

## Full snapshot protections
Full snapshot mode avoids silent omissions by:
- building an explicit manifest and staging mirror (no stdin selection),
- shadowing `.repomixignore` files during staging,
- disabling repomix default ignore layers for the full run,
- disabling repomix security filtering for the full run,
- pinning repomix max file size to `largest_manifest_file + margin`,
- enabling parsable output for deterministic path rewriting.

Because security filtering is disabled in full snapshot mode, review pack contents before sharing externally.

## Key output artifacts
- `repomix-output.xml`
- `patch.diff` (and optional `patch.staged.diff`)
- `REPO_INFO.md`
- `AIPACK_NAV.md`
- `AIPACK_SUMMARY.txt`
- `aipack_included.txt`
- `git_tracked.txt`
- `git_untracked.txt`
- `aipack_missing_tracked.txt`
- `aipack_missing_untracked.txt`
- `aipack_skipped_oversize.txt`
- `aipack_excluded_security.txt`

## Acceptance harness
Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\acceptance_harness.ps1
```

The harness validates packaging boundary completeness, legacy compatibility, and cwd independence.
