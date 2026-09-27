# Testing

| What | Command | Needs | Runs in CI on |
|---|---|---|---|
| Syntax | `bash -n immich-backup.sh` | bash | Linux, macOS `/bin/bash` 3.2 |
| Lint | `shellcheck -s bash immich-backup.sh tests/e2e.sh tests/unit.bats` | shellcheck | Linux |
| Unit tests | `bats tests/unit.bats` | bats-core ≥ 1.5 | Linux, **macOS `/bin/bash` 3.2** |
| End-to-end | `sudo tests/e2e.sh` | Linux, root, rsync, openssh-server, sudo, perl `shasum` | Linux |

CI is `.github/workflows/ci.yml` and runs on every push and pull request.

## Lint

shellcheck must report **nothing**. The few intentional exceptions carry an
inline `# shellcheck disable=…` with a reason (unused placeholder variables,
and `remote_ssh`'s deliberately client-side command string). Don't add a
disable without a reason on the same line or the line above.

## Unit tests (`tests/unit.bats`)

The unit tests source the script (it only runs `main` when executed, not when
sourced) and call functions directly. There's no network, root or real drive
involved, so they run on a laptop in about a second. They cover:

- rsync output parsing: byte totals in both locale formats, the itemize filter
  (new, c/s/t changes, perms-only, dirs, symlinks, deletions, spaces,
  non-ASCII), counters per leg
- verification: `_compare_sums` (every outcome, order independence, GNU `\`
  prefix, binary `*` marker), `_hash_list` with a missing file (BSD xargs
  exits 1, GNU exits 123, and both must be accepted), `verify_leg`
  end-to-end on temp dirs
- `prune_old_logs`, `drive_needed_bytes`, `_rsync_rc`, `mount_point_of`
- `parse_args`, `load_config`, `finalize_config` (derivation, env
  precedence, validation, permission check)
- lock acquire/stale/live, and `drive_ready` (tagging, dry run, swap, not a
  mount)

**Why macOS matters:** the macOS CI job puts `/bin/bash` (3.2) first on `PATH`,
so bats and the sourced script really run under 3.2 with BSD `awk`, `xargs`,
`touch`, `du` and `df`. It's the only automated check of the Mac's
environment, so keep new logic unit-testable and add a test for it.

Watch out in tests: sourcing sets the script's `IFS=$'\n\t'`, so
`"${arr[*]}"` joins with newlines (use a loop, as `has_flag` does). In bats, a
bare `! cmd` never fails a test; use `run ! cmd`.

## End-to-end (`tests/e2e.sh`)

This runs the real script, unmodified, through 26 scenarios. It needs root on
Linux and sets up everything itself:

- a user `immich-e2e` with the documented 3-command sudoers line
- its own sshd on 127.0.0.1:2223 (the system sshd isn't touched)
- a root-owned fake Immich library (`upload/`, `library/`, `profile/`,
  `backups/` with a fresh and an old dump) and `~/photos` with a non-ASCII
  filename
- two tmpfs mounts as Drive A/B, so the "must be a mount point" check is real
- a stub `diskutil` that records calls, and a per-run config file (the SSH
  port and known_hosts file go in through `SSH_EXTRA_OPTS`)

At the end it removes the user, the sudoers file, the mounts and sshd.

Scenarios: CLI and config errors, a dry run on empty drives, the first run,
an unchanged re-run, a dry run with pending changes, an empty or missing
source, `REMOTE_MOUNTPOINTS`, a stale or missing dump, env-over-config
precedence, the deletion limit, rsync-only sudoers, a hash mismatch, an
unreadable copy, an unverifiable source (exit 3), live and stale locks,
swapped drives, and a drive folder that isn't a mount.

To check that the suite can actually catch a regression, run it against a
modified copy:

```sh
sed 's|RSYNC_BASE_FLAGS+=(--max-delete="$MAX_DELETE")|:|' immich-backup.sh > /tmp/mutant.sh
sudo IMMICH_BACKUP_SCRIPT=/tmp/mutant.sh tests/e2e.sh   # "deletion limit" must FAIL
```

Hashing failures are simulated with a `shasum` wrapper placed first on `PATH`
(`fake_shasum corrupt|omit PATTERN`).

## What no automated test covers

- The full flow on macOS: real `diskutil eject`, `caffeinate`, APFS, `/Volumes`.
- A real Immich server (real dump names, Docker file ownership, `.immich`
  marker files).

After changes that touch those areas, say that they were only exercised on
Linux, and ask the owner to do a `--dry-run` and then a real run on the Mac.
