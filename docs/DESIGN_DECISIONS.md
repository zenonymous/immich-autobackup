# Design decisions

Why the script looks the way it does. Recorded so a future change doesn't
undo a deliberate choice by accident. If you change one of these, update
this file.

## Scope

**Manual, attended, single-file.** The owner plugs in two drives, runs the
script, and unplugs them. The drives live in a vault between runs. No daemon,
no scheduler, no restore path. The README's *Non-goals* are deliberate, not
missing features. The program is still one file. Settings moved to an
optional config file (below), and tests live next to it.

**Pull from the Mac, not push from the server.** The server needs no software
beyond `rsync` and one sudoers line. The Mac holds the SSH key; the server has
no credentials for the backup drives.

**Two drives, A then B.** Remote → A is the slow, verified network leg. A → B
is a fast local copy. If only one drive is present, it gets the SSH leg and the
mirror is skipped. The mirror never runs B → A, even if that would be possible
(see the edge case at the end of `main`) — the direction is fixed so the
operator always knows which drive is authoritative.

**Mirror, not versioned.** `rsync --delete` means the destination matches the
source. Deleted photos disappear from both drives on the next run. Versioning
was explicitly left to Time Machine / restic.

## What gets backed up

| Included | Why |
|---|---|
| `upload/`, `library/`, `profile/` | Originals and user data. Not regenerable. |
| `~/photos/` | Immich *external library*: Immich only references it, so it must be copied separately. |
| Newest `backups/*.sql.gz` | Immich's own scheduled DB dump. All album, face, metadata state lives here. |

| Excluded | Why |
|---|---|
| `thumbs/`, `encoded-video/` | Regenerable by Immich jobs. Big. |
| `postgres/` (raw data dir) | Not safe to copy while running; the dump covers it. |
| Older dumps | Only the latest is kept on the drives. |

## Database dump first

The dump is copied before the asset files. The script's header and README
explain this in a confusing way; here is the actual reasoning:

- The dump always shows the DB at a point in time **before** the asset copy
  finishes. After a restore you get files that the DB doesn't know about
  ("orphans"). That is harmless: files are intact and can be re-imported.
- The reverse (assets older than the DB) means the DB points at files that
  aren't in the backup. That is real data loss for those rows.

The script doesn't create a dump; it copies the newest one Immich wrote. That
dump can be up to a day old (Immich's default schedule is nightly), so the
orphan window is "since the last nightly dump", not "since the start of this
run". An asset that was *permanently* deleted after the dump (trash emptied)
will be referenced by the DB but missing from the mirror.

A missing dump, or one older than `DUMP_MAX_AGE_HOURS` (26h: one nightly
cycle plus slack), stops the run in pre-flight. A backup without a current DB
restores the photos but loses albums, people and metadata, so it shouldn't
report success. `DUMP_MAX_AGE_HOURS=0` overrides this for a one-off run.

## `--rsync-path="sudo rsync"`

Immich runs in Docker and writes files as root. Rather than chmod the library
or run SSH as root, only the remote rsync process is elevated, via a
`NOPASSWD: /usr/bin/rsync` sudoers entry. SSH stays unprivileged.
Consequence: every *other* remote command that needs root also needs a sudoers
entry. The script uses exactly three: `/usr/bin/rsync`, `/usr/bin/du` (sizing)
and `/usr/bin/sha256sum` (verification). They're always called by absolute
path with `sudo -n`, so they match sudoers exactly and fail instead of
prompting. `xargs` stays unprivileged and calls `sudo sha256sum` itself,
because allowing `xargs` in sudoers would effectively allow any command.
`check_ssh` tests all three up front. Full passwordless sudo also works.

## Guarding `--delete`

A mirror faithfully copies mistakes. The script adds three brakes, all of
which fire before the mirror step so Drive B keeps the previous state:

1. **Pre-flight source checks**: each source must exist and be non-empty, and
   paths in `REMOTE_MOUNTPOINTS` must be mount points. This catches the most
   likely disaster, a disk or share on the server that didn't mount, before
   any rsync runs.
2. **`--max-delete` (`MAX_DELETE`, default 1000 per rsync call)**: catches mass
   deletion inside Immich's own folders. rsync stops deleting at the limit
   and exits 25, which aborts the run.
3. **Mirror only after a clean SSH leg**: any failure on the SSH leg aborts
   before A → B runs.

A dry-run pass to count deletions before touching anything was considered and
rejected. It would double the remote file-list scan on every run, and checks
1 and 3 already cover the destructive cases.

## Verify only what rsync moved

Hashing the whole library every run would take hours. rsync's own
`--itemize-changes` output says which files it transferred, so only those are
SHA-256'd on both ends. Unchanged files aren't re-checked. Permission-only
changes (`>f.....p…`) aren't hashed because no bytes moved.

Results are matched per file, by relative path, and there are three outcomes:
passed, failed (mismatch, or the copy can't be read) and unverified (the
source can't be hashed, typically because Immich removed it mid-run). They map
to exit codes 0 / 2 / 3, so "nothing was verified" can never look like
success.

A→B verification is off by default: it's a local copy, and it's slow.

## Bash 3.2 compatibility

macOS ships Bash 3.2 as `/bin/bash`. The script is written so it runs there
without Homebrew bash. Workarounds you'll see in the code:

| Pattern | Reason |
|---|---|
| `if [[ … ]]; then …; fi; return 0` instead of `[[ … ]] && …` at end of functions | Under 3.2 + `set -e`, the failed test's status becomes the function's return and aborts the script. |
| Checking `${#arr[@]} -gt 0` before `"${arr[@]}"` | Empty arrays are "unbound" under `set -u` in 3.2. |
| Capturing `rsync --version` into a variable, then regex-parsing | `rsync --version \| head -1` gets SIGPIPE (141) under `pipefail`. |
| `BASH_LINENO[0]` + `BASH_COMMAND` in `on_err` | `$LINENO` in ERR traps is unreliable in 3.2. |
| NUL-separated lists + `read -d ''` loops | No `mapfile -d`. Filenames can contain spaces. |

## Config file, not script edits

Settings used to be edited in the script itself, which meant every update of
the script overwrote them. Now the script only holds defaults, and the config
file is **sourced bash**. That's the simplest format that supports arrays
(`SOURCES`, `REMOTE_MOUNTPOINTS`, `SSH_EXTRA_OPTS`) without a parser, and it's
what the old in-script block already was. Because it's executed, a config
file that's writable by group or others is refused.

Precedence: environment (only the three documented one-run overrides), then
the config file, then the defaults. Values derived from others (`REMOTE_HOME`
from `REMOTE_USER`, the default `SOURCES` from `REMOTE_HOME`) are computed in
`finalize_config`, *after* loading, so setting `REMOTE_USER` alone is enough.
`finalize_config` also validates, so a typo fails before anything connects.

## Lock, sleep, drive identity

- **Lock**: `mkdir` is atomic everywhere, needs no `flock` (not on macOS), and
  holds the PID so a crash's leftover lock is detected and cleared. It lives in
  `LOG_DIR`, which is per user.
- **Sleep**: `caffeinate -ims -w $$` runs alongside the script and exits with
  it. There's nothing to clean up, and it's skipped where caffeinate doesn't
  exist (Linux tests).
- **Drive identity**: a drive must be the mount point of its own filesystem.
  An empty `/Volumes/BackupA` folder left after an unclean eject would
  otherwise look like a drive. Each drive carries a one-line tag file (`A`/`B`)
  outside `BACKUP_SUBDIR`, so the mirror never copies it. The tag catches
  swapped drives. It deliberately doesn't pin a specific disk (UUIDs would make
  replacing a drive a chore). Untagged drives are tagged on first use, so
  existing drives and new drives need no setup step.

## Dry run

`--dry-run` answers "is everything ready, and what would change?". It runs
all pre-flight checks for real, then the SSH leg with `rsync -n`. It stops
there: a dry A→B comparison would compare against a Drive A that wasn't
actually updated, and would mislead. The drives aren't ejected, because a real
run usually follows.

## Tests and CI

Two layers:
- **`tests/unit.bats`**: pure functions and config logic, with no network or
  root. CI runs it on Linux *and* on macOS forced onto `/bin/bash` 3.2 with
  the BSD tools. That's the only automated check of the real target
  environment.
- **`tests/e2e.sh`**: the real script against a throwaway sshd, a root-owned
  fake Immich tree, tmpfs "drives" and a stub `diskutil`, as root on Linux. It
  covers the safety behaviour (deletion limit, empty source, sudo, exit codes).

shellcheck must be clean. Intentional exceptions are annotated inline with a
reason, so CI can fail on any new finding.

## Output

Coloured, timestamped stdout for the operator; a plain copy in a per-run log;
rsync transcripts in a per-run directory for post-mortem. Per-file
`VERIFY-OK` lines go only to the log file so the terminal stays readable.

## Eject in the EXIT trap

The drives are ejected whether the run succeeds, fails, or is interrupted, so
the operator can just unplug them. Only drives that were actually written to
(`USED_DRIVES`) are ejected. `diskutil eject` ejects the whole physical disk.
