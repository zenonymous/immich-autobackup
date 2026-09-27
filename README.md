# immich-backup

A single-file Bash script for manually backing up an [Immich](https://immich.app) instance running on a LAN Ubuntu host to two external APFS drives attached to a Mac. Pulls remote → Drive A over SSH+rsync, then mirrors Drive A → Drive B locally. SHA-256 verifies every file rsync says it transferred on the SSH leg. Ejects both drives on exit.

It's deliberately small, deliberately not a daemon, and deliberately tied to one specific home setup. If you want notifications, scheduling, encryption, or a restore path, this isn't that — see [Non-goals](#non-goals).

## What it does

On each run, in order:

1. **Pre-flight checks**, before anything is copied or deleted:
   - No other run is in progress (a lock in the log directory). The Mac is kept awake with `caffeinate` until the script exits.
   - Homebrew rsync ≥ 3, SSH reachable, and passwordless `sudo` works on the remote for `rsync`, `du` and `sha256sum`.
   - Every source exists and isn't empty, and any path in `REMOTE_MOUNTPOINTS` is actually mounted. An empty source combined with `--delete` would otherwise wipe that part of the backup.
   - A DB dump exists and is no older than `DUMP_MAX_AGE_HOURS` (26 by default).
   - At least one destination drive is a real mounted volume, writable, carries the right A/B tag (see [Drive tags](#drive-tags)), and has room for whatever it doesn't already hold, plus 10% headroom.
2. **Database dump first** — copies the newest `*.sql.gz` from `~/immich-app/library/backups/` on the remote. Old dumps on the destination are pruned so only the latest remains. Dump-before-assets is intentional: it guarantees the backed-up assets are at least as new as the DB, so a restore can at worst leave harmless untracked files, rather than DB rows pointing at files that aren't in the backup. The script copies Immich's own scheduled dump; it does not create a fresh one.
3. **Asset sync** — `rsync -aH --delete` over SSH for `upload/`, `library/`, `profile/`, and `~/photos/`. Each rsync call may delete at most `MAX_DELETE` files (1000 by default). If it hits the limit, the run aborts and the A → B mirror is skipped, so Drive B keeps the previous state. `thumbs/`, `encoded-video/`, and `postgres/` are excluded — they're regenerable or already captured by the dump.
4. **Verification** — for every file rsync reports as newly transferred or content/size/time-changed, computes SHA-256 on both ends and compares, file by file. Mismatches go to `verification-failures.txt` in the run's log directory; files that couldn't be hashed go to `unverified.txt`.
5. **Local mirror** — `rsync -aH --delete` from Drive A → Drive B. Checksum verification is off by default here (the local copy is fast and the next remote sync would catch corruption); set `VERIFY_LOCAL_MIRROR=1` to turn it on.
6. **Eject** — both drives are ejected via an `EXIT` trap, so they come out cleanly even if the script aborts.

If only one drive is mounted, it's used and the mirror step is skipped with a warning. Both missing aborts.

`--dry-run` does step 1 in full, then shows what step 2 and 3 *would* copy and delete, without writing anything to the drives.

## Requirements

**On the Mac:**

- macOS with default `/bin/bash` (the script is bash 3.2-compatible)
- Homebrew `rsync` ≥ 3.x — `brew install rsync`. The system rsync 2.6.9 is too old. The script auto-detects `/opt/homebrew/bin/rsync` (Apple Silicon) or `/usr/local/bin/rsync` (Intel).
- Two APFS-formatted external drives, mounted at `/Volumes/BackupA` and `/Volumes/BackupB` (paths are configurable).
- An SSH key for the remote loaded in your agent or `~/.ssh/`.

**On the Ubuntu host:**

- `rsync` at `/usr/bin/rsync`
- An unprivileged SSH user (e.g. `user`, configured via `REMOTE_USER`) with passwordless sudo for `rsync`, `du` and `sha256sum` (or full passwordless sudo) — see [Setup](#setup).
- Immich's scheduled database backup enabled (Administration → Settings → Backup Settings), so a fresh `*.sql.gz` appears nightly.
- Immich library at `${REMOTE_HOME}/immich-app/library/` and a separate external photo tree at `${REMOTE_HOME}/photos/`. `REMOTE_HOME` defaults to `/home/${REMOTE_USER}`; both source paths are configurable (see [Configuration](#configuration)).

## Setup

These are one-time steps. None are scripted — they're the kind of thing you want to do once with your eyes open.

### 1. Install Homebrew rsync

```sh
brew install rsync
```

Verify it's the new one:

```sh
$(brew --prefix)/bin/rsync --version | head -1
# rsync  version 3.x.x  ...
```

### 2. SSH key auth for the remote

```sh
ssh-copy-id user@1.2.3.4
ssh -o BatchMode=yes user@1.2.3.4 true && echo "key auth OK"
```

`BatchMode=yes` matters — the script uses it to fail fast instead of hanging at a password prompt.

### 3. Passwordless sudo for rsync, du and sha256sum on the remote

Docker writes parts of the Immich library tree as root, so `user` can't read them as itself. The script works around this by passing `--rsync-path="sudo rsync"` so the *remote* rsync runs as root while the SSH session itself stays unprivileged. The free-space check (`du`) and verification (`sha256sum`) need root for the same reason. If `user` already has full passwordless sudo, skip to the test below. Otherwise, add a sudoers entry on the remote:

```sh
ssh user@1.2.3.4
sudo visudo -f /etc/sudoers.d/immich-backup
```

Add exactly one line:

```
user ALL=(ALL) NOPASSWD: /usr/bin/rsync, /usr/bin/du, /usr/bin/sha256sum
```

Confirm `which rsync du sha256sum` returns those paths on the remote. The script calls them by these absolute paths, and sudoers only matches exact paths. Then test:

```sh
ssh user@1.2.3.4 'for c in rsync du sha256sum; do sudo -n /usr/bin/$c --version >/dev/null && echo "$c OK"; done'
# rsync OK
# du OK
# sha256sum OK
```

### 4. Format and mount the drives

Two APFS drives, named `BackupA` and `BackupB` in Disk Utility (or whatever you prefer — set `DRIVE_A` and `DRIVE_B` in the config file to match). Prefer **APFS (Case-sensitive)**: Linux allows `IMG_1.JPG` and `img_1.jpg` side by side, and a case-insensitive drive can only hold one of them. To check an existing drive: `diskutil info /Volumes/BackupA | grep Personality`. Encryption is optional; if you have FileVault on the boot drive and want symmetry, turn on APFS encryption when formatting these too.

When mounted, they should appear at `/Volumes/BackupA` and `/Volumes/BackupB`.

### 5. Drop the script somewhere convenient

```sh
mkdir -p ~/bin
cp immich-backup.sh ~/bin/
chmod +x ~/bin/immich-backup.sh
```

### 6. Create your config file

```sh
mkdir -p ~/.config/immich-backup
cp immich-backup.conf.example ~/.config/immich-backup/config
chmod 600 ~/.config/immich-backup/config
```

Edit it and set at least `REMOTE_USER` and `REMOTE_HOST`. See [Configuration](#configuration).

### 7. Try a dry run

```sh
~/bin/immich-backup.sh --dry-run
```

This checks everything (SSH, sudo, sources, dump, drives, free space) and lists what a real run would copy and delete, without touching the drives.

## Configuration

Settings live in a config file, not in the script, so you can replace the script with a newer version without losing them. The file is plain bash, read after the script's built-in defaults; set only what you want to change. [`immich-backup.conf.example`](immich-backup.conf.example) lists everything.

The script looks for, in order: `--config FILE`, then `$IMMICH_BACKUP_CONFIG`, then `~/.config/immich-backup/config` (or `$XDG_CONFIG_HOME/immich-backup/config`). An explicitly named file must exist. The default one is optional. The file must not be writable by group or others, because the script executes it.

**Upgrading from a version where you edited the script:** copy your `REMOTE_USER`, `REMOTE_HOST` and any other values you changed into the config file. The script now refuses to run while `REMOTE_HOST` is the placeholder `1.2.3.4`.

| Variable | Default | Notes |
|---|---|---|
| `REMOTE_USER` | `user` | SSH username on the Ubuntu host. **Set this.** |
| `REMOTE_HOST` | `1.2.3.4` | Hostname or IP of the Ubuntu host. **Set this.** |
| `SSH_KEY` | *(empty)* | Optional `-i` override. Empty means use the agent / default key. |
| `SSH_EXTRA_OPTS` | *(empty)* | Extra ssh flags as an array, e.g. `(-p 2222)`. No spaces inside an element. |
| `REMOTE_HOME` | `/home/${REMOTE_USER}` | Remote home dir. Override only for non-standard layouts. |
| `SOURCES` | 4 paths under `${REMOTE_HOME}` | `REMOTE_PATH:DEST_SUBPATH` pairs. Trailing slashes are intentional. Each must exist and be non-empty. |
| `REMOTE_MOUNTPOINTS` | *(empty)* | Remote paths that must be mount points, e.g. `("${REMOTE_HOME}/photos")` if that's a mounted disk or share. The run aborts if one isn't mounted. |
| `DUMP_REMOTE_DIR` | `${REMOTE_HOME}/immich-app/library/backups` | Where the latest `.sql.gz` is picked up from. |
| `DUMP_MAX_AGE_HOURS` | `26` | Abort if the newest dump is older. `0` disables. Env-overridable. |
| `MAX_DELETE` | `1000` | Max files a single rsync call may delete. `unlimited` disables. Env-overridable. |
| `DRIVE_A`, `DRIVE_B` | `/Volumes/BackupA`, `/Volumes/BackupB` | Mountpoints. |
| `REQUIRE_DRIVE_MOUNT` | `1` | Skip a drive path that exists but isn't a mounted volume. |
| `BACKUP_SUBDIR` | `immich-backup` | Top-level directory created on each drive. |
| `LOG_DIR` | `~/Library/Logs/immich-backup` | Per-run logs and `latest.log` symlink. |
| `LOG_RETENTION` | `30` | Older run logs are pruned. |
| `HEADROOM_PCT` | `10` | Safety margin on top of the data a drive still needs, checked in pre-flight. |
| `VERIFY_LOCAL_MIRROR` | `0` | `1` checksums the A→B leg too. Env-overridable. |

"Env-overridable" means you can set it for one run, e.g. `MAX_DELETE=unlimited ~/bin/immich-backup.sh`. That wins over the config file.

The `DB_CONTAINER`, `DB_USER`, `DB_NAME` vars are present but unused — they're a placeholder for adding a live `docker exec ... pg_dump` path later.

### Drive tags

Each drive gets a small file `.immich-backup-drive` at its root containing `A` or `B`. It's written the first time a drive is used. From then on, a drive tagged `B` that shows up at `DRIVE_A`'s path (for example after renaming the drives the wrong way round) stops the run instead of being written to. To retag a drive on purpose, edit or delete that file.

## Usage

Plug both drives in. Run:

```sh
~/bin/immich-backup.sh
```

To see what would happen first, without writing to the drives (they stay mounted afterwards):

```sh
~/bin/immich-backup.sh --dry-run      # or -n
~/bin/immich-backup.sh --help
```

To also checksum-verify the A→B mirror (slower):

```sh
VERIFY_LOCAL_MIRROR=1 ~/bin/immich-backup.sh
```

If you deliberately deleted a lot of photos (or ran Immich's storage template migration, which moves every file), the deletion limit will stop the run. Check that the deletions are expected, then:

```sh
MAX_DELETE=unlimited ~/bin/immich-backup.sh
```

Exit codes: `0` complete and verified, `1` failed, `2` finished with verification failures, `3` finished but some transferred files couldn't be verified, `64` bad command line.

The script is verbose on stdout (with colour) and writes a plain copy of the same output to a per-run log file. Abridged example:

```
2026-09-27 17:33:12 [INFO ] Config file: /Users/me/.config/immich-backup/config
2026-09-27 17:33:12 [INFO ] Sleep prevention on (caffeinate).
2026-09-27 17:33:12 [INFO ] Using rsync: /opt/homebrew/bin/rsync (3.4.1)
2026-09-27 17:33:13 [INFO ] Checking passwordless sudo for rsync, du and sha256sum on remote...
2026-09-27 17:33:14 [INFO ] All 4 remote sources present and non-empty.
2026-09-27 17:33:14 [INFO ] Latest dump on remote: /home/user/immich-app/library/backups/immich-db-backup-….sql.gz (14h old)
2026-09-27 17:33:14 [INFO ] Drive A present: /Volumes/BackupA
2026-09-27 17:33:15 [INFO ] Drive A: backup 812.40 GB, free 1.02 TB, needs 1.21 GB (incl. 10% headroom)
...
2026-09-27 17:35:02 [INFO ]   SSH leg files new/upd/del:     143 / 2 / 5
2026-09-27 17:35:02 [INFO ]   Verification checked:          145
2026-09-27 17:35:02 [INFO ]   Verification passed:           145
2026-09-27 17:35:02 [INFO ] BACKUP COMPLETE
```

A backup of an already-mirrored library with no new photos completes in under a minute. The first run, or one after importing a lot of new media, is bound by your LAN and disk speed.

## On-disk layout

Each drive ends up with this structure:

```
/Volumes/BackupA/
├── .immich-backup-drive                        # "A" (drive tag, not mirrored)
└── immich-backup/
    ├── db/
    │   └── immich-2026-04-26T03-00-00.sql.gz   # latest only; older pruned
    ├── originals/
    │   ├── upload/
    │   ├── library/
    │   └── profile/
    └── external-library/
        └── photos/
```

Drive B is a byte-for-byte mirror of Drive A.

The split between `originals/` (Immich-managed) and `external-library/` (your photo tree) reflects how Immich treats the two: assets you upload through the app live in `library/upload/library/profile`, and external libraries are read-only references to a path Immich watches. Restoring would mean putting both back where they came from on a fresh Immich install and then importing the dump.

## Verification

On the SSH leg, the script parses rsync's `--itemize-changes` output for `>f` lines whose flag string is either `+++++++++` (new file) or has any of `c`/`s`/`t` set (content/size/time changed). For each, it:

1. Hashes the file on the remote: `ssh ... xargs -0 sudo -n /usr/bin/sha256sum`.
2. Hashes the file locally: `xargs -0 shasum -a 256`.
3. Compares the two hashes for that file.

Per-file results go to the log file (not stdout — they'd drown out everything else). Outcomes:

- **Match**: passed.
- **Mismatch, or the copied file can't be read on the drive**: failed. Printed and listed in `<run-dir>/verification-failures.txt`. Exit code 2.
- **Source can't be hashed** (usually because Immich deleted the file after rsync copied it): not verified. Listed in `<run-dir>/unverified.txt`. Exit code 3.

The summary at the end of the run reports checked / passed / failed / not possible. rsync is run with `-8`, so filenames with accents or non-Latin characters verify correctly whatever the locale.

Files rsync didn't touch are not re-hashed. That's the whole point of using rsync's own report — verifying things rsync skipped would defeat the speed.

## Logs

```
~/Library/Logs/immich-backup/
├── 2026-04-26_173312.log                 # main run log
├── 2026-04-26_173312/                    # per-run dir
│   ├── rsync-dump-BackupA.log
│   ├── rsync-BackupA-upload.log …        # one rsync transcript per source
│   ├── rsync-mirror-a-to-b.log
│   ├── verification-failures.txt         # only if any failed
│   └── unverified.txt                    # only if any couldn't be hashed
├── 2026-04-25_173015.log
├── ...
├── .lock/                                # only while a run is in progress
└── latest.log → 2026-04-26_173312.log
```

`tail -f ~/Library/Logs/immich-backup/latest.log` while a run is in progress works. Logs older than `LOG_RETENTION` runs are pruned at the start of each run.

## Troubleshooting

### Reading error output

When something fails, the script's `ERR` trap prints a line like:

```
[ERROR] Unhandled error in detect_rsync() near line 178 (trap line 178, exit 141)
[ERROR]   failing command: ver="$("$RSYNC" --version 2>/dev/null | ...)"
```

Three things to look at, in order:

1. **The exit code.** `1` is a generic failure. `141` is `128 + 13` = `SIGPIPE` (a producer wrote to a pipe whose consumer had already closed — usually a `head -N` cutting off a long output under `pipefail`). `255` from anything ssh-related means SSH itself failed (key, host, network). `127` means a command wasn't found.
2. **The function name.** Tells you which stage broke — `check_ssh`, `check_dump`, `detect_rsync`, `verify_leg`, etc.
3. **The failing command.** The literal text bash was running when it died. Often the fix is obvious from this alone.

The `near line N` is a best-effort pointer — bash's own line-number reporting inside `ERR` traps is occasionally off by a few lines, especially under bash 3.2. Trust the function name and the failing command first.

### Common failures

**`rsync: command not found` or `rsync 2.6.9` showing up.**
The script didn't find Homebrew rsync. Run `brew install rsync` and check that `/opt/homebrew/bin/rsync` (Apple Silicon) or `/usr/local/bin/rsync` (Intel) exists.

**`Remote 'sudo -n /usr/bin/…' failed` or `Permission denied` reading `library/upload/...` on the remote.**
The sudoers line is missing or wrong. Run the test from [Setup step 3](#3-passwordless-sudo-for-rsync-du-and-sha256sum-on-the-remote). The paths on the right of `NOPASSWD:` have to be the exact absolute paths.

**`Remote source … is empty` or `… is not a mount point`.**
A source directory on the server is empty or its disk isn't mounted. Nothing was copied or deleted. Fix the mount on the server and re-run.

**`No *.sql.gz dump found` or `Newest dump is Nh old`.**
Immich's database backup job isn't running (Administration → Settings → Backup Settings), or its folder isn't readable by the SSH user. If you knowingly want to back up with an old dump, run with `DUMP_MAX_AGE_HOURS=0`.

**`rsync hit the deletion limit`.**
More than `MAX_DELETE` files would have been deleted from one source. At most that many were removed from the first drive, and the second drive wasn't touched. If the deletions are expected, re-run with `MAX_DELETE=unlimited`. The next run brings the first drive back in line either way.

**`rsync: some source files vanished during transfer`.**
Immich moved or deleted files while rsync was scanning. This is harmless, and the run continues.

**`Another immich-backup run is in progress`.**
Another run holds the lock. If you're sure there isn't one (for example after a crash), the script clears a lock whose process is gone by itself. If it says the lock has no PID, remove `~/Library/Logs/immich-backup/.lock`.

**`The drive at … is tagged as drive 'B', but is mounted as drive A`.**
The drives are swapped, or a different disk has the name. Rename them in Disk Utility so each mounts at its own path, or, if you really mean to reuse a disk in the other role, edit its `.immich-backup-drive` file.

**`… exists but isn't a mounted volume`.**
There's a folder at `/Volumes/BackupX` but no drive mounted there (a leftover after an unclean eject). Plug the drive in, or remove the empty folder.

**`REMOTE_HOST is still the placeholder`.**
No config file was found, or it doesn't set `REMOTE_HOST`. See [Setup step 6](#6-create-your-config-file).

**SSH hangs or asks for a password.**
Key auth isn't working from a non-interactive shell. The script forces `BatchMode=yes`, so any prompt = abort. Re-run `ssh-copy-id` and confirm `ssh -o BatchMode=yes user@host true` exits 0.

**Drive missing — only one used, mirror skipped.**
Expected behaviour when one drive isn't mounted. Plug it in and re-run; the next run will populate it from the remote (it does *not* auto-fall-back to copying from Drive B → A in the same run).

**Verification failure.**
Check `verification-failures.txt`. Most likely causes: a file changed on the remote between rsync transferring it and the script hashing it (re-run; it'll fix itself), a flaky USB cable on the destination drive (test the drive), or genuine corruption (rare; investigate). The script does not auto-retry — it's a manual tool, you decide.

**Free-space pre-flight fails.**
The check asks for room for whatever isn't on the drive yet, plus `HEADROOM_PCT` (10%). If it fails, the drive is genuinely close to full. Lower the headroom if you're confident, or get a bigger drive.

## Non-goals

This script does *not*:

- Restore. Restore is a different operation with different risks; do it by hand.
- Encrypt the destination. Use APFS encryption or FileVault.
- Notify on failure. It exits non-zero; wrap it in something else if you want notifications (`launchd`, a one-line `||` to `osascript`, etc.).
- Schedule itself. Run it manually, or wrap it in `launchd` / `cron`.
- Do incremental snapshots, versioning, or point-in-time recovery. The destination is a *mirror*; deleted files on the source are deleted on the destination on the next run. If you want versioned history, use Time Machine alongside this, or layer something like `restic` on top.

## For contributors (and AI agents)

- [`AGENTS.md`](AGENTS.md): orientation, hard constraints (Bash 3.2, BSD tools, sudoers), how to work here
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): function map, control flow, output files
- [`docs/DESIGN_DECISIONS.md`](docs/DESIGN_DECISIONS.md): why it's built this way
- [`docs/KNOWN_ISSUES.md`](docs/KNOWN_ISSUES.md): verified bugs and risks. **Read before relying on verification or the free-space check.**
- [`docs/TESTING.md`](docs/TESTING.md): the test suites (`bats tests/unit.bats`, `sudo tests/e2e.sh`) and CI

## License

Use it, change it, break it. No warranty.
