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

1. Pre-flight (nothing touched yet): Homebrew rsync ≥ 3, SSH key auth,
   remote passwordless `sudo` for rsync/du/sha256sum, sources exist and aren't
   empty (optionally mounted), a DB dump ≤ 26h old exists, drives mounted and
   writable, enough free space for what's missing.
2. Copy the **newest existing** `*.sql.gz` Immich DB dump (made by Immich's own
   scheduled backup job; the script does not create one).
3. `rsync -aH --delete --max-delete=N` the asset folders (`upload/`,
   `library/`, `profile/`) and an external photo tree (`~/photos/`, a mount).
4. SHA-256 verify every file rsync reported as transferred on the SSH leg.
5. Mirror Drive A → Drive B (verification optional, `VERIFY_LOCAL_MIRROR=1`).
6. Eject both drives from an `EXIT` trap and print a summary.
   Exit codes: 0 ok, 1 failed, 2 verification failures, 3 unverified files,
   64 bad command line.

Around that: settings come from `~/.config/immich-backup/config` (sourced
bash), a lock prevents parallel runs, `caffeinate` keeps the Mac awake, drives
must be real mounts carrying an A/B tag file, and `--dry-run` runs the checks
plus `rsync -n` without writing to the drives.

The owner runs it by hand only (the drives live in a vault between runs), has
full passwordless sudo on the server, and `~/photos` is a mounted disk/share.

It is intentionally **not** a daemon, not scheduled, not versioned, no restore.
See README "Non-goals" before proposing features in those areas.

## Repo map

| Path | What |
|---|---|
| `immich-backup.sh` | The whole program (~1300 lines). Defaults block at the top; sourceable (main runs only when executed). |
| `immich-backup.conf.example` | User config template → `~/.config/immich-backup/config`. Keep in sync with the defaults block. |
| `tests/unit.bats` | Unit tests (bats). Also run under macOS `/bin/bash` 3.2 in CI. |
| `tests/e2e.sh` | End-to-end suite (Linux, root): throwaway sshd + tmpfs drives. |
| `.github/workflows/ci.yml` | shellcheck, unit (Linux + macOS 3.2), e2e (Linux). |
| `README.md` | User-facing docs: setup, config table, usage, troubleshooting. |
| `AGENTS.md` / `CLAUDE.md` | This orientation. |
| `docs/ARCHITECTURE.md` | Function-by-function walkthrough, control flow, state, output files. |
| `docs/DESIGN_DECISIONS.md` | Why things are the way they are, incl. the non-obvious Bash 3.2 workarounds. |
| `docs/KNOWN_ISSUES.md` | Verified bugs and risks, with evidence. **Check before "fixing" something.** |
| `docs/TESTING.md` | Test suites, what they cover, what nothing covers. |

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
- **Every remote privileged command must be allowed by sudoers.** The
  documented line is `NOPASSWD: /usr/bin/rsync, /usr/bin/du, /usr/bin/sha256sum`.
  Call them as `sudo -n /usr/bin/<cmd>` (absolute path, non-interactive). Never
  `sudo xargs` or `sudo sh`. Adding a new privileged command means updating
  `check_ssh`, the README sudoers line and the script header.
- **`--delete` is destructive.** Any change touching source paths, destination
  paths, or `SOURCES` parsing can wipe a backup. Treat it as high-risk. Keep
  the three guards (pre-flight source checks, `--max-delete`, mirror only after
  a clean SSH leg); see `docs/DESIGN_DECISIONS.md`.
- **Pre-flight must stay side-effect free** on the drives: all "should we
  run?" checks happen before the first rsync.
- **Don't reintroduce silent success**: a check that fails must `die` or feed
  a counter that changes the exit code. Watch out for `die` inside `$(…)`,
  which only exits the subshell. Return non-zero and let the caller die.
- Keep it a **single self-contained file** unless the owner agrees otherwise.

## How to work here

- Before pushing, run: `shellcheck -s bash immich-backup.sh tests/e2e.sh tests/unit.bats`
  (must be **clean**; intentional exceptions are inline `disable` comments with
  a reason), `bats tests/unit.bats`, and, if you're root on Linux,
  `tests/e2e.sh`. Details are in `docs/TESTING.md`.
- New logic gets a unit test. New safety behaviour gets an e2e scenario, and
  it's worth checking that the scenario fails against a copy with the
  behaviour removed (`IMMICH_BACKUP_SCRIPT=…`).
- CI's macOS job is the only automated Bash 3.2 / BSD-tools check. Linux
  results say nothing about 3.2. Say which parts were tested where.
- New settings: add them to the defaults block, `finalize_config`
  (validation or derivation), `immich-backup.conf.example`, and the README
  config table.
- Anything that writes to a drive must respect `DRY_RUN`.
- The owner wants improvements **pitched before implemented**. Don't refactor
  or change behaviour unprompted.
- Keep README's config table and "What it does" list in sync with the script.

## Glossary

- **SSH leg** — remote → first available drive (`SSH_LEG_DRIVE`, normally A).
- **Local leg / mirror** — Drive A → Drive B.
- **Itemize line** — rsync `--itemize-changes` record, e.g. `>f+++++++++ path`.
- **Dump** — Immich's gzipped Postgres dump in `library/backups/`.
- **Unverified** — a transferred file whose source couldn't be hashed (exit 3).

## Roadmap agreed with the owner

- ✅ A+B+C (Sept 2026): delete guards, dump checks, trustworthy verification,
  exit codes, free-space/byte/log fixes. See KNOWN_ISSUES "Fixed".
- ✅ D (Sept 2026): `caffeinate`, `--dry-run`, lock, drives must be real
  mounts with an A/B tag.
- ✅ E (Sept 2026): config file, `tests/unit.bats`, `tests/e2e.sh`, CI.
- Maybe later (F): keep deleted files for N days on the drives, keep several
  dumps, restore runbook.
