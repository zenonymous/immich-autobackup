# immich-backup

A single-file Bash script for manually backing up an [Immich](https://immich.app) instance running on a LAN Ubuntu host to two external APFS drives attached to a Mac. Pulls remote → Drive A over SSH+rsync, then mirrors Drive A → Drive B locally. SHA-256 verifies every file rsync says it transferred on the SSH leg. Ejects both drives on exit.

It's deliberately small, deliberately not a daemon, and deliberately tied to one specific home setup. If you want notifications, scheduling, encryption, or a restore path, this isn't that — see [Non-goals](#non-goals).

## What it does

On each run, in order:

1. **Pre-flight checks** — Homebrew rsync ≥ 3, SSH reachable, passwordless `sudo rsync` works on the remote, at least one destination drive is mounted and writable, free space ≥ source size + 10% headroom.
2. **Database dump first** — copies the newest `*.sql.gz` from `~/immich-app/library/backups/` on the remote. Old dumps on the destination are pruned so only the latest remains. Dump-before-assets is intentional: it guarantees the backed-up assets are at least as new as the DB, so a restore can at worst leave harmless untracked files, rather than DB rows pointing at files that aren't in the backup. The script copies Immich's own scheduled dump; it does not create a fresh one.
3. **Asset sync** — `rsync -aH --delete` over SSH for `upload/`, `library/`, `profile/`, and `~/photos/`. `thumbs/`, `encoded-video/`, and `postgres/` are excluded — they're regenerable or already captured by the dump.
4. **Verification** — for every file rsync reports as newly transferred or content/size/time-changed, computes SHA-256 on both ends and compares. Mismatches go to `verification-failures.txt` in the run's log directory.
5. **Local mirror** — `rsync -aH --delete` from Drive A → Drive B. Checksum verification is off by default here (the local copy is fast and the next remote sync would catch corruption); set `VERIFY_LOCAL_MIRROR=1` to turn it on.
6. **Eject** — both drives are ejected via an `EXIT` trap, so they come out cleanly even if the script aborts.

If only one drive is mounted, it's used and the mirror step is skipped with a warning. Both missing aborts.

## Requirements

**On the Mac:**

- macOS with default `/bin/bash` (the script is bash 3.2-compatible)
- Homebrew `rsync` ≥ 3.x — `brew install rsync`. The system rsync 2.6.9 is too old. The script auto-detects `/opt/homebrew/bin/rsync` (Apple Silicon) or `/usr/local/bin/rsync` (Intel).
- Two APFS-formatted external drives, mounted at `/Volumes/BackupA` and `/Volumes/BackupB` (paths are configurable).
- An SSH key for the remote loaded in your agent or `~/.ssh/`.

**On the Ubuntu host:**

- `rsync` at `/usr/bin/rsync`
- An unprivileged SSH user (e.g. `user`, configured via `REMOTE_USER`) with passwordless sudo specifically for rsync — see [Setup](#setup).
- Immich library at `${REMOTE_HOME}/immich-app/library/` and a separate external photo tree at `${REMOTE_HOME}/photos/`. `REMOTE_HOME` defaults to `/home/${REMOTE_USER}`; both source paths are configurable at the top of the script.

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

### 3. Passwordless sudo for rsync on the remote

Docker writes parts of the Immich library tree as root, so `user` can't read them as itself. The script works around this by passing `--rsync-path="sudo rsync"` so the *remote* rsync runs as root while the SSH session itself stays unprivileged. That requires a sudoers entry on the remote:

```sh
ssh user@1.2.3.4
sudo visudo -f /etc/sudoers.d/immich-backup
```

Add exactly one line:

```
user ALL=(ALL) NOPASSWD: /usr/bin/rsync
```

Confirm `which rsync` returns `/usr/bin/rsync` on the remote — if it's somewhere else, the path in the sudoers line has to match exactly. Then test:

```sh
ssh user@1.2.3.4 'sudo -n rsync --version >/dev/null && echo OK'
# OK
```

### 4. Format and mount the drives

Two APFS drives, named `BackupA` and `BackupB` in Disk Utility (or whatever you prefer — match the names against `DRIVE_A` and `DRIVE_B` in the script). Encryption is optional; if you have FileVault on the boot drive and want symmetry, turn on APFS encryption when formatting these too.

When mounted, they should appear at `/Volumes/BackupA` and `/Volumes/BackupB`.

### 5. Drop the script somewhere convenient

```sh
mkdir -p ~/bin
cp immich-backup.sh ~/bin/
chmod +x ~/bin/immich-backup.sh
```

## Configuration

Everything you'd reasonably want to change lives at the top of the script under `CONFIG — edit these`. The names match the Setup section above:

| Variable | Default | Notes |
|---|---|---|
| `REMOTE_USER` | `user` | SSH username on the Ubuntu host. **Edit this.** |
| `REMOTE_HOST` | `1.2.3.4` | Hostname or IP of the Ubuntu host. **Edit this.** |
| `SSH_KEY` | *(empty)* | Optional `-i` override. Empty means use the agent / default key. |
| `REMOTE_HOME` | `/home/${REMOTE_USER}` | Remote home dir. Override only for non-standard layouts. |
| `SOURCES` | 4 paths under `${REMOTE_HOME}` | `REMOTE_PATH:DEST_SUBPATH` pairs. Trailing slashes are intentional. |
| `DUMP_REMOTE_DIR` | `${REMOTE_HOME}/immich-app/library/backups` | Where the latest `.sql.gz` is picked up from. |
| `DRIVE_A`, `DRIVE_B` | `/Volumes/BackupA`, `/Volumes/BackupB` | Mountpoints. |
| `BACKUP_SUBDIR` | `immich-backup` | Top-level directory created on each drive. |
| `LOG_DIR` | `~/Library/Logs/immich-backup` | Per-run logs and `latest.log` symlink. |
| `LOG_RETENTION` | `30` | Older run logs are pruned. |
| `HEADROOM_PCT` | `10` | Free-space safety margin checked in pre-flight. |
| `VERIFY_LOCAL_MIRROR` | `0` | Set to `1` (env or edit) to checksum the A→B leg too. |

The `DB_CONTAINER`, `DB_USER`, `DB_NAME` vars are present but unused — they're a placeholder for adding a live `docker exec ... pg_dump` path later.

## Usage

Plug both drives in. Run:

```sh
~/bin/immich-backup.sh
```

To also checksum-verify the A→B mirror (slower):

```sh
VERIFY_LOCAL_MIRROR=1 ~/bin/immich-backup.sh
```

The script is verbose on stdout (with colour) and writes a plain copy of the same output to a per-run log file. Expect output along the lines of:

```
2026-04-26 17:33:12 [INFO ] ── pre-flight ──
2026-04-26 17:33:12 [INFO ] rsync: /opt/homebrew/bin/rsync (3.2.7)
2026-04-26 17:33:13 [INFO ] ssh user@1.2.3.4 ... OK
2026-04-26 17:33:13 [INFO ] sudo -n rsync on remote ... OK
2026-04-26 17:33:13 [INFO ] /Volumes/BackupA writable, 1.4T free
2026-04-26 17:33:13 [INFO ] /Volumes/BackupB writable, 1.4T free
2026-04-26 17:33:14 [INFO ] ── db dump ──
...
2026-04-26 17:33:21 [INFO ] ── remote → BackupA ──
...
```

A backup of an already-mirrored library with no new photos completes in under a minute. The first run, or one after importing a lot of new media, is bound by your LAN and disk speed.

## On-disk layout

Each drive ends up with this structure:

```
/Volumes/BackupA/
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

1. Hashes the file on the remote: `ssh ... xargs -0 sudo sha256sum`.
2. Hashes the file locally: `xargs -0 shasum -a 256`.
3. Compares.

Per-file results go to the log file (not stdout — they'd drown out everything else). Mismatches go to both stdout and `<run-dir>/verification-failures.txt`. The summary at the end of the run reports `checked / passed / failed`.

Files rsync didn't touch are not re-hashed. That's the whole point of using rsync's own report — verifying things rsync skipped would defeat the speed.

## Logs

```
~/Library/Logs/immich-backup/
├── 2026-04-26_173312.log                 # main run log
├── 2026-04-26_173312/                    # per-run dir
│   ├── rsync-dump-BackupA.log
│   ├── rsync-BackupA-upload.log …        # one rsync transcript per source
│   ├── rsync-mirror-a-to-b.log
│   └── verification-failures.txt         # only if any failed
├── 2026-04-25_173015.log
├── ...
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
2. **The function name.** Tells you which stage broke — `check_ssh`, `detect_rsync`, `verify_ssh_leg`, etc.
3. **The failing command.** The literal text bash was running when it died. Often the fix is obvious from this alone.

The `near line N` is a best-effort pointer — bash's own line-number reporting inside `ERR` traps is occasionally off by a few lines, especially under bash 3.2. Trust the function name and the failing command first.

### Common failures

**`rsync: command not found` or `rsync 2.6.9` showing up.**
The script didn't find Homebrew rsync. Run `brew install rsync` and check that `/opt/homebrew/bin/rsync` (Apple Silicon) or `/usr/local/bin/rsync` (Intel) exists.

**`Permission denied` reading `library/upload/...` on the remote.**
The sudoers line is missing or wrong. Run `ssh user@host 'sudo -n rsync --version'` — if it prompts for a password, sudoers isn't set up. The path on the right of `NOPASSWD:` has to be the exact absolute path that `which rsync` returns on the remote.

**SSH hangs or asks for a password.**
Key auth isn't working from a non-interactive shell. The script forces `BatchMode=yes`, so any prompt = abort. Re-run `ssh-copy-id` and confirm `ssh -o BatchMode=yes user@host true` exits 0.

**Drive missing — only one used, mirror skipped.**
Expected behaviour when one drive isn't mounted. Plug it in and re-run; the next run will populate it from the remote (it does *not* auto-fall-back to copying from Drive B → A in the same run).

**Verification failure.**
Check `verification-failures.txt`. Most likely causes: a file changed on the remote between rsync transferring it and the script hashing it (re-run; it'll fix itself), a flaky USB cable on the destination drive (test the drive), or genuine corruption (rare; investigate). The script does not auto-retry — it's a manual tool, you decide.

**Free-space pre-flight fails.**
`HEADROOM_PCT` defaults to 10%. If you're confident, lower it. If you're not, get a bigger drive.

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
- [`docs/TESTING.md`](docs/TESTING.md): how to test without a Mac

## License

Use it, change it, break it. No warranty.
