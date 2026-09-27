# AGENTS.md — orientation for AI coding agents

Read this first. It is the shortest path to being useful in this repo.
`CLAUDE.md` imports this file, so Claude Code and other agents see the same text.

## What this project is

A single Bash script, `immich-backup.sh`, that a person runs **by hand on a Mac**
to back up a self-hosted [Immich](https://immich.app) server (Docker, on a LAN
Ubuntu box) to **two external APFS drives**:

```
Ubuntu host (Immich)  ──ssh + "sudo rsync"──▶  Drive A  ──local rsync──▶  Drive B
                                                 (/Volumes/BackupA)          (/Volumes/BackupB)
```

1. Pre-flight: Homebrew rsync ≥ 3, SSH key auth, remote passwordless `sudo rsync`,
   drives mounted and writable, free space check.
2. Copy the **newest existing** `*.sql.gz` Immich DB dump (made by Immich's own
   scheduled backup job; the script does not create one).
3. `rsync -aH --delete` the asset folders (`upload/`, `library/`, `profile/`)
   and an external photo tree (`~/photos/`).
4. SHA-256 verify every file rsync reported as transferred on the SSH leg.
5. Mirror Drive A → Drive B (verification optional, `VERIFY_LOCAL_MIRROR=1`).
6. Eject both drives from an `EXIT` trap and print a summary.

It is intentionally **not** a daemon, not scheduled, not versioned, no restore.
See README "Non-goals" before proposing features in those areas.

## Repo map

| Path | What |
|---|---|
| `immich-backup.sh` | The whole program (~890 lines). Config block at the top. |
| `README.md` | User-facing docs: setup, config table, usage, troubleshooting. |
| `AGENTS.md` / `CLAUDE.md` | This orientation. |
| `docs/ARCHITECTURE.md` | Function-by-function walkthrough, control flow, state, output files. |
| `docs/DESIGN_DECISIONS.md` | Why things are the way they are, incl. the non-obvious Bash 3.2 workarounds. |
| `docs/KNOWN_ISSUES.md` | Verified bugs and risks, with evidence. **Check before "fixing" something.** |
| `docs/TESTING.md` | How to test this on Linux / without the real hardware. |

## Hard constraints (don't break these)

- **Runs under macOS `/bin/bash` 3.2.** No `declare -A`, no `mapfile`/`readarray`,
  no `${var,,}`, no `&>>`, no negative array indices, no `wait -n`.
  Empty-array expansion under `set -u` is fatal in 3.2 — guard with a length check
  (see `mark_used`, `cleanup_eject`).
- **`set -Eeuo pipefail` is on.** `[[ cond ]] && cmd` as the last line of a function
  leaks a non-zero status and kills the script under 3.2 — use `if/then` + `return 0`.
  `producer | head -1` can die with SIGPIPE (exit 141) — capture into a variable first.
- **`IFS=$'\n\t'`** globally. Unquoted expansions do *not* split on spaces.
- **Local tools are BSD/macOS flavoured**: `shasum -a 256` (not `sha256sum`), BSD
  `df`/`du`/`find`/`xargs`, `diskutil`. GNU-only flags (`du -b`, `find -printf`,
  `stat -c`) may only be used **inside `remote_ssh` commands** (Ubuntu side).
- **rsync is Homebrew 3.x** on the Mac (`detect_rsync`); remote is `/usr/bin/rsync`.
- **Every remote privileged command must be allowed by sudoers.** The README's
  documented sudoers line only allows `/usr/bin/rsync`. Anything else run via
  `sudo` on the remote (`du`, `xargs sha256sum`) will fail under that setup —
  see `docs/KNOWN_ISSUES.md` #1.
- **`--delete` is destructive.** Any change touching source paths, destination
  paths, or `SOURCES` parsing can wipe a backup. Treat it as high-risk.
- Keep it a **single self-contained file** unless the owner agrees otherwise.

## How to work here

- Lint: `shellcheck -s bash immich-backup.sh`. Current baseline: only warnings
  for the unused `DB_*`/`C_GRN` vars, `ls | grep` in `prune_old_logs`, and
  unquoted `return $rc` (see `docs/TESTING.md`). Don't add new ones.
- Syntax check: `bash -n immich-backup.sh`.
- There is **no test suite and no CI** yet. `docs/TESTING.md` explains how to
  exercise the parsing functions against real rsync output on Linux.
- You cannot run the full flow in a Linux container (needs `diskutil`, `/Volumes`,
  an Immich host). Say so rather than claiming end-to-end verification.
- The owner wants improvements **pitched before implemented**. Don't refactor
  or change behaviour unprompted.
- Keep README's config table and "What it does" list in sync with the script.

## Glossary

- **SSH leg** — remote → first available drive (`SSH_LEG_DRIVE`, normally A).
- **Local leg / mirror** — Drive A → Drive B.
- **Itemize line** — rsync `--itemize-changes` record, e.g. `>f+++++++++ path`.
- **Dump** — Immich's gzipped Postgres dump in `library/backups/`.
