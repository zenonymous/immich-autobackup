# Architecture

Everything lives in `immich-backup.sh` (~1300 lines). Settings come from an
optional config file (`immich-backup.conf.example` shows the format). Tests
are in `tests/`, CI in `.github/workflows/ci.yml`. This doc maps the script
section by section, so you can find things without reading all of it. Function names are stable
anchors; line numbers are not, so none are given.

## Topology

```
┌──────────── Ubuntu host (LAN) ─────────────┐        ┌──────────── Mac ─────────────────────┐
│ ~/immich-app/library/   (Immich UPLOAD_LOC)│        │ immich-backup.sh (run by hand)       │
│   upload/  library/  profile/   ← synced   │        │                                      │
│   thumbs/  encoded-video/       ← skipped  │  ssh   │  /Volumes/BackupA/immich-backup/ ◀─┐ │
│   backups/*.sql.gz  ← newest one copied    │ ─────▶ │  /Volumes/BackupB/immich-backup/ ◀─┘ │
│ ~/photos/        (external library) synced │ rsync  │        (A → B local mirror)          │
│ rsync, du, sha256sum run as root via sudo  │        │  ~/Library/Logs/immich-backup/       │
└────────────────────────────────────────────┘        └──────────────────────────────────────┘
```

The Mac always *pulls*. Nothing is installed on the server except a sudoers entry.

## File layout (top to bottom)

| Section | Contents |
|---|---|
| Header comment | Purpose, rationale for dump-first and `sudo rsync`, prerequisites, usage, exit codes. |
| `set -Eeuo pipefail`, `IFS=$'\n\t'` | Strict mode. `-E` makes the `ERR` trap fire inside functions. |
| `ENV_*` capture | `VERIFY_LOCAL_MIRROR`, `MAX_DELETE`, `DUMP_MAX_AGE_HOURS` from the environment, saved before the defaults overwrite them. |
| **CONFIG — defaults** | `REMOTE_*`, `SSH_KEY`, `SSH_EXTRA_OPTS`, `SOURCES`, `REMOTE_MOUNTPOINTS`, `DUMP_REMOTE_DIR`, `DUMP_MAX_AGE_HOURS`, `MAX_DELETE`, `DRIVE_A/B`, `BACKUP_SUBDIR`, `REQUIRE_DRIVE_MOUNT`, `LOG_*`, `HEADROOM_PCT`, `VERIFY_LOCAL_MIRROR`. Derived values (`REMOTE_HOME`, `SOURCES`, `DUMP_REMOTE_DIR`) default to empty and are filled in by `finalize_config`. `DB_CONTAINER/DB_USER/DB_NAME` are unused placeholders. |
| Internal state | Globals: counters, `SSH_OPTS`, `USED_DRIVES`, `SSH_LEG_DRIVE`, `DRIVE_A_OK/B_OK`, `DUMP_PATH`, `DRY_RUN`, `CONFIG_FILE`, `LOCK_DIR/LOCK_HELD`, `LOG_FILE`, `RUN_DIR`, `RSYNC`. |
| Pretty printing | `_emit`, `log`, `warn`, `err`, `die`, `hr`. Coloured to stdout if a TTY, plain line appended to `$LOG_FILE`. |
| Arguments and config | `usage`, `parse_args`, `load_config` (find, permission-check and source the file), `finalize_config` (derive, apply env overrides, validate, build `RSYNC_BASE_FLAGS`, set `LOCK_DIR`). |
| Lock, sleep | `acquire_lock`, `release_lock`, `keep_awake`. |
| SSH plumbing | `init_ssh_opts` (BatchMode, 10s timeout, optional `-i`), `remote_ssh`, `ssh_string_for_rsync` (flattens opts for rsync `-e`). |
| Tooling | `detect_rsync` (Homebrew paths first, requires major ≥ 3), `human_bytes`. |
| Logging | `setup_logging`, `prune_old_logs`. |
| Pre-flight helpers | `check_local_tools`, `check_ssh` (sudo for rsync/du/sha256sum), `check_remote_sources` (exists, non-empty, mounted), `find_latest_dump` + `check_dump` (exists, age), `mount_point_of`, `drive_ready` (exists, real mount, writable, A/B tag), `drive_free_bytes`, `remote_source_bytes`, `local_backup_bytes`, `drive_needed_bytes`. |
| Traps | `print_summary`, `cleanup_eject` (EXIT; also maps verification results to exit 2/3), `on_err` (ERR), `mark_used`. |
| rsync wrappers | `RSYNC_BASE_FLAGS` (+ `--max-delete`), `_rsync_rc` (exit 24 → warning, 25 → explained failure), `_normalise_log`, `rsync_ssh_leg`, `rsync_local_leg`, `parse_bytes_transferred`, `tally_itemize`. |
| Verification | `extract_transferred_relpaths`, `_hash_list`, `_compare_sums`, `verify_leg`. |
| Stages | `fetch_latest_dump`, `prune_old_dumps`, `sync_remote_to_drive`, `mirror_a_to_b`. |
| Main | `drive_has_room`, `preflight`, `main`. The last lines call `main "$@"` only when the file is executed, not when it's sourced (the unit tests source it). |

## Control flow

```
main
├─ parse_args → load_config → finalize_config   (errors here: exit 1/64, no summary)
├─ trap on_err ERR ; trap cleanup_eject EXIT
├─ acquire_lock                     (another live run → die)
├─ preflight
│   ├─ setup_logging → prune_old_logs → keep_awake (caffeinate)
│   ├─ init_ssh_opts → detect_rsync → check_local_tools → check_ssh
│   ├─ check_remote_sources         (mounted? exists? non-empty? else die)
│   ├─ check_dump                   (newest dump exists and is young enough, else die)
│   ├─ drive_ready A / B            (missing/not a mount → skip; wrong tag → die; both unusable → die)
│   ├─ remote_source_bytes          (sudo du -sb on remote; failure → die)
│   ├─ drive_has_room A / B         ((source − existing)*(1+HEADROOM) ≤ free, else skip drive)
│   └─ SSH_LEG_DRIVE = A if OK else B
├─ mark_used SSH_LEG_DRIVE
├─ fetch_latest_dump   → rsync_ssh_leg (no-delete) → verify_leg remote → prune_old_dumps
├─ sync_remote_to_drive  (for each SOURCES entry)
│      rsync_ssh_leg → parse_bytes_transferred → tally_itemize ssh → verify_leg remote
├─ if DRY_RUN: skip mirror
│  elif SSH_LEG_DRIVE==A and B OK: mark_used B → mirror_a_to_b
│      rsync_local_leg → parse/tally mirror → [verify_leg local if VERIFY_LOCAL_MIRROR=1]
└─ (EXIT) cleanup_eject: diskutil eject each USED_DRIVES (not in dry run) → rc 0→2/3
          if verification failed/incomplete → print_summary → release_lock → exit rc
```

### Dry run

`finalize_config` adds `--dry-run` to `RSYNC_BASE_FLAGS`. The rest is guarded
with `DRY_RUN`: no `mkdir` of destinations, no drive tagging, no verification,
no dump pruning, no mirror, no eject. Pre-flight runs in full, and the summary
counters then show what a real run would do.

### Error handling model

- Any unhandled non-zero status → `ERR` trap (`on_err`) logs function, line,
  and `BASH_COMMAND`, then `set -e` exits → `EXIT` trap ejects and summarises.
- `die` logs and `exit 1` → same EXIT path.
- rsync failures are caught explicitly (`if ! rsync_…`) and turned into
  `return 1`, which then aborts via `set -e` at the call site in `main`.
  `_rsync_rc` treats exit 24 (files vanished on the source) as a warning, and
  explains exit 25 (the `MAX_DELETE` limit was hit) before failing.
- All "is it safe to start?" checks happen in `preflight`, before any rsync
  runs, so a failure there leaves both drives untouched.
- Verification failures do **not** abort. They're counted, printed, and written
  to `${RUN_DIR}/verification-failures.txt` or `unverified.txt`.
  `cleanup_eject` turns them into exit code 2 (a mismatch, or the copy is
  missing on the drive) or 3 (a source couldn't be hashed).

### rsync invocation

```
$RSYNC -aH -8 --delete --partial --info=progress2 \
       --itemize-changes --stats --max-delete=1000 \
       -e "ssh -o BatchMode=yes -o ConnectTimeout=10 [-i KEY]" \
       --rsync-path="sudo rsync" \
       user@host:/remote/path/  /Volumes/BackupA/immich-backup/<subpath>/
```

Output is `tee`'d to `${RUN_DIR}/rsync-<tag>.log`, then `_normalise_log`
rewrites `\r` → `\n` so progress lines don't glue onto itemize lines.
Everything downstream (byte totals, counters, verification list) is parsed
from that file.

The dump uses the same wrapper with `no-delete` (single-file source).
`-8` keeps non-ASCII filenames unescaped in the itemize output, whatever the
locale. `--human-readable` is deliberately absent so the byte counts in the
`--stats` output are exact.

### Verification algorithm (`verify_leg`)

1. `extract_transferred_relpaths` picks `>f` lines whose flags are
   `+++++++++` (new) or have `c` (checksum), `s` (size) or `t` (mtime) set.
   Output is NUL-separated relative paths.
2. Build two NUL lists: source absolute paths and destination absolute paths.
3. `_hash_list`: remote `ssh … "xargs -0 sudo -n /usr/bin/sha256sum --"`, or
   local `xargs -0 shasum -a 256 --`. Files that can't be hashed just produce
   no output line (xargs exits 123 on GNU or 1 on BSD, and that's accepted).
4. `_compare_sums` (awk): strips each base path so results are keyed by
   relative path, then classifies every expected file as `OK`, `MISMATCH`,
   `NODST` (source hashed, copy not), `NOSRC` (copy hashed, source not) or
   `NONE`. Order and missing lines don't matter.
5. OK → passed; MISMATCH/NODST → failed; NOSRC/NONE → unverified.

## State & counters

| Variable | Meaning | Notes |
|---|---|---|
| `SSH_BYTES` | Sum of "Total transferred file size" over SSH-leg rsyncs | Exact byte count from `--stats`. |
| `LOCAL_BYTES` | Same for A→B | |
| `FILES_NEW/UPDATED/DELETED` | From SSH-leg itemize lines | The dump counts as a file. |
| `MIRROR_NEW/UPDATED/DELETED` | From A→B itemize lines | |
| `VERIFY_CHECKED/PASSED/FAILED` | Verification results | Both legs. Checked = passed + failed. |
| `VERIFY_UNVERIFIED` | Transferred files that couldn't be hashed | Non-zero → exit 3. |
| `RSYNC_WARNINGS` | rsync exits of 24 | Informational. |
| `USED_DRIVES` | Drives to eject | Only drives actually written to. |

## Output on disk

Destination (each drive):

```
/Volumes/BackupX/immich-backup/
├── db/<newest dump>.sql.gz           # older dumps pruned
├── originals/{upload,library,profile}/
└── external-library/photos/
```

Logs (`LOG_DIR`, default `~/Library/Logs/immich-backup/`):

```
2026-04-26_173312.log                 # main run log (plain text)
2026-04-26_173312/                    # per-run dir (RUN_DIR)
    rsync-dump-BackupA.log
    rsync-BackupA-upload.log …        # one per SOURCES entry
    rsync-mirror-a-to-b.log
    verification-failures.txt         # only if something failed
    unverified.txt                    # only if something couldn't be hashed
latest.log -> 2026-04-26_173312.log
```

Temporary `.relpaths.nul`, `.src-sums.txt`, `.verify-results.txt`, etc. are
created in `RUN_DIR` and removed after each verification batch.

## Extension points

- **Add/remove a source**: edit `SOURCES` (`REMOTE_PATH/:DEST_SUBPATH/`, keep
  trailing slashes). The tag in log names is the basename of the remote path,
  so two sources with the same basename will overwrite each other's rsync log.
- **Live DB dump**: `DB_CONTAINER/DB_USER/DB_NAME` were reserved for a
  `docker exec … pg_dumpall` path that was never written.
- **Different drive names**: `DRIVE_A`, `DRIVE_B`.
