# Known issues and risks

The list started from a code review in September 2026. Items that have been
fixed are kept at the bottom, with how they were fixed, so nobody reintroduces
them. The owner wants fixes pitched before they're implemented.

Status meanings:
- **Confirmed**: reproduced with real rsync, bash and sshd in a Linux container.
- **By inspection**: follows from the code; not reproduced.

---

## Open

### Case-insensitive APFS (low, depends on drive format)
Default APFS is case-insensitive. Linux paths that differ only by case
(`IMG_1.JPG` and `img_1.jpg` in the same directory) collide on the drive. One
overwrites the other, and every run re-transfers them. This is unlikely under
Immich's own `upload/` and `library/`, but possible in `~/photos`. Formatting
the drives as *APFS (Case-sensitive)* avoids it; the README says how to check.
The owner doesn't yet know how their drives are formatted.

### Drive tags identify a role, not a specific disk
The `.immich-backup-drive` marker says "A" or "B", so it catches swapped
drives. A *new* disk that gets named `BackupA` is simply tagged A on first use
and accepted. That's intended: replacing a drive should just work.

### Laptop lid closed = sleep anyway
`caffeinate -ims` prevents idle and disk sleep, and system sleep on AC power.
Closing a MacBook's lid without an external display still sleeps it.

### The deletion limit is a brake, not a wall (by design)
`--max-delete=N` lets rsync delete up to N files before it stops, so a wiped
source can still lose up to N files per source from the **first** drive. The
run then aborts before the mirror, so Drive B is untouched, and the next good
run restores Drive A from the server. The empty-source and mount-point checks
catch the common case (a mount that didn't come up) before any rsync runs.

### The empty-source check can't see a "hollow" Immich folder
Recent Immich versions keep a `.immich` marker file in `upload/`, `library/`
and `profile/`, so those folders are never empty to the check. The check
mainly protects `~/photos` and similar trees. `MAX_DELETE` is the protection
for Immich's own folders.

### Smaller items
- GNU `sha256sum` prefixes the line with `\` for names containing a backslash
  or newline. The comparison strips the prefix from the hash, but the escaped
  name may not match, so such files end up as *unverified*, never as passed.
- Two `SOURCES` entries with the same basename write to the same
  `rsync-<tag>.log`.
- When an rsync call fails (for example on the deletion limit), its itemized
  changes aren't added to the summary counters.
- After a handled failure, the `ERR` trap still prints `Unhandled error in
  main() … failing command: return 1`. That's noisy but harmless: the real
  error is logged just above it.
- The end-to-end suite runs on Linux (Bash 5, GNU tools). macOS is covered
  by the unit tests in CI under `/bin/bash` 3.2 with the BSD tools, but the
  full flow (real `diskutil`, `caffeinate`, `/Volumes`) is only exercised by
  real runs on the Mac.
- `--dry-run` on a drive that has never been backed up can't simulate the
  mirror step, and reports rsync's view of a destination that doesn't exist
  yet (everything new).

---

## Fixed (September 2026, phase A+B+C)

| # | Was | Fix |
|---|---|---|
| 1 | Remote `sudo du` / `sudo xargs sha256sum` weren't covered by the documented sudoers line. The free-space check silently became a no-op and verification was silently skipped. | Pre-flight checks `sudo -n` for `/usr/bin/rsync`, `du` and `sha256sum` and dies with the exact sudoers line. Commands use `sudo -n` and absolute paths. xargs runs unprivileged and calls `sudo sha256sum`, so sudoers doesn't have to allow `xargs`. A failed `du` is fatal. Confirmed with an rsync-only sudoers file (dies) and the 3-command file (passes). |
| 2 | The free-space check required the *whole* library plus 10% free on every run. | `drive_has_room` measures the existing backup on each drive (`du -sk`) and requires `(source − existing) × (1 + headroom)`. |
| 3 | An empty source plus `--delete` could wipe both drives in one run. | `check_remote_sources` aborts if a source is missing or empty. Optional `REMOTE_MOUNTPOINTS` requires paths to be mounted. `MAX_DELETE` (default 1000) goes to rsync as `--max-delete`, and exit 25 is fatal before the mirror. Confirmed. |
| 4 | Verification was all-or-nothing per batch and relied on lockstep line order. | `verify_leg` + `_compare_sums` key the results by relative path (awk arrays). Each file is OK, MISMATCH, NODST (fail), NOSRC or NONE (unverified). |
| 5 | A non-UTF-8 locale made rsync escape non-ASCII names, which broke verification. | rsync runs with `-8`. Confirmed with `LANG=C`. |
| 6 | Exit code 0 despite verification failures; skipped verification was invisible. | Exit 2 for failures, 3 for unverified files, with `unverified.txt` and a summary line. |
| 7 | rsync exit 24 (vanished files) aborted the run. | `_rsync_rc` turns 24 into a warning and counts it. |
| 8 | A missing dump only produced a warning, and dump age wasn't checked. | `check_dump` in pre-flight dies if there's no dump or if it's older than `DUMP_MAX_AGE_HOURS` (26). Age is computed on the remote. |
| 9 | Byte totals were 1024-based while rsync `-h` is 1000-based. | Dropped `--human-readable`. The parser strips `,`/`.` separators and uses base-1000 units if a suffix ever appears. |
| 10 | Log retention kept only about half the run directories. | Logs and run dirs are counted separately. Confirmed: 40 runs → 30 of each kept. |
| 11 | File counters added the SSH leg and the mirror together. | Separate `FILES_*` (SSH) and `MIRROR_*` counters. |

## Fixed (September 2026, phase D+E)

| Was | Fix |
|---|---|
| `drive_ready` accepted any writable folder, even an empty leftover in `/Volumes`. | Must be the mount point of its own filesystem (`REQUIRE_DRIVE_MOUNT=1`), and carry the right A/B tag. |
| The Mac could sleep during a long run. | `caffeinate -ims -w $$` for the life of the process. |
| No `--help`/`--dry-run`, no lock. | `parse_args`, `--dry-run`, and a `mkdir` lock with PID and stale-lock recovery. |
| Settings lived in the script, so updating the script lost them. | Config file (`load_config`/`finalize_config`), with an example file. |
| No tests or CI. | `tests/unit.bats`, `tests/e2e.sh`, and `.github/workflows/ci.yml`. |

---

## Restore-related notes (not bugs)

- `thumbs/` and `encoded-video/` aren't backed up. After a restore, Immich has
  to regenerate them (thumbnail and transcode jobs). Recent Immich versions
  also check for `.immich` marker files in each media folder at startup. Check
  the current Immich restore docs for how to recreate the empty folders.
- There's only one dump on the drives. If that dump is bad, no older one is
  available.
