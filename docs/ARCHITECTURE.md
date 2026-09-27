# Architecture

Everything lives in `immich-backup.sh`. This doc maps it section by section so
you can find things without reading all ~890 lines. Function names are stable
anchors; line numbers are not, so none are given.

## Topology

```
┌──────────── Ubuntu host (LAN) ─────────────┐        ┌──────────── Mac ─────────────────────┐
│ ~/immich-app/library/   (Immich UPLOAD_LOC)│        │ immich-backup.sh (run by hand)       │
│   upload/  library/  profile/   ← synced   │        │                                      │
│   thumbs/  encoded-video/       ← skipped  │  ssh   │  /Volumes/BackupA/immich-backup/ ◀─┐ │
│   backups/*.sql.gz  ← newest one copied    │ ─────▶ │  /Volumes/BackupB/immich-backup/ ◀─┘ │
│ ~/photos/        (external library) synced │ rsync  │        (A → B local mirror)          │
│ remote rsync runs as root via sudo         │        │  ~/Library/Logs/immich-backup/       │
└────────────────────────────────────────────┘        └──────────────────────────────────────┘
```

The Mac always *pulls*. Nothing is installed on the server except a sudoers entry.

## File layout (top to bottom)

| Section | Contents |
|---|---|
| Header comment | Purpose, rationale for dump-first and `sudo rsync`, prerequisites. |
| `set -Eeuo pipefail`, `IFS=$'\n\t'` | Strict mode. `-E` makes the `ERR` trap fire inside functions. |
| **CONFIG** | `REMOTE_*`, `SSH_KEY`, `SOURCES`, `DUMP_REMOTE_DIR`, `DRIVE_A/B`, `BACKUP_SUBDIR`, `LOG_*`, `HEADROOM_PCT`, `VERIFY_LOCAL_MIRROR`. `DB_CONTAINER/DB_USER/DB_NAME` are unused placeholders. Only `VERIFY_LOCAL_MIRROR` can be overridden from the environment. |
| Internal state | Globals: counters, `SSH_OPTS`, `USED_DRIVES`, `SSH_LEG_DRIVE`, `DRIVE_A_OK/B_OK`, `LOG_FILE`, `RUN_DIR`, `RSYNC`. |
| Pretty printing | `_emit`, `log`, `warn`, `err`, `die`, `hr`. Coloured to stdout if a TTY, plain line appended to `$LOG_FILE`. |
| SSH plumbing | `init_ssh_opts` (BatchMode, 10s timeout, optional `-i`), `remote_ssh`, `ssh_string_for_rsync` (flattens opts for rsync `-e`). |
| Tooling | `detect_rsync` (Homebrew paths first, requires major ≥ 3), `human_bytes`. |
| Logging | `setup_logging`, `prune_old_logs`. |
| Pre-flight helpers | `check_local_tools`, `check_ssh`, `drive_ready`, `drive_free_bytes`, `remote_source_bytes`. |
| Traps | `print_summary`, `cleanup_eject` (EXIT), `on_err` (ERR), `mark_used`. |
| rsync wrappers | `RSYNC_BASE_FLAGS`, `_normalise_log`, `rsync_ssh_leg`, `rsync_local_leg`, `parse_bytes_transferred`, `tally_itemize`. |
| Verification | `extract_transferred_relpaths`, `_count_nuls`, `verify_ssh_leg`, `verify_local_leg`. |
| Stages | `find_latest_dump`, `fetch_latest_dump`, `prune_old_dumps`, `sync_remote_to_drive`, `mirror_a_to_b`. |
| Main | `preflight`, `main`, then `main "$@"` (arguments are ignored). |

## Control flow

```
main
├─ trap on_err ERR ; trap cleanup_eject EXIT
├─ preflight
│   ├─ setup_logging → prune_old_logs
│   ├─ init_ssh_opts → detect_rsync → check_local_tools → check_ssh
│   ├─ drive_ready A / B            (both missing → die)
│   ├─ remote_source_bytes          (sudo du -sb on remote)
│   ├─ drive_free_bytes vs source*(1+HEADROOM)   (drive disqualified if short)
│   └─ SSH_LEG_DRIVE = A if OK else B
├─ mark_used SSH_LEG_DRIVE
├─ fetch_latest_dump   → rsync_ssh_leg (no-delete) → verify_ssh_leg → prune_old_dumps
├─ sync_remote_to_drive  (for each SOURCES entry)
│      rsync_ssh_leg → parse_bytes_transferred → tally_itemize → verify_ssh_leg
├─ if SSH_LEG_DRIVE==A and B OK: mark_used B → mirror_a_to_b
│      rsync_local_leg → parse/tally → [verify_local_leg if VERIFY_LOCAL_MIRROR=1]
└─ (EXIT) cleanup_eject: diskutil eject each USED_DRIVES → print_summary → exit rc
```

### Error handling model

- Any unhandled non-zero status → `ERR` trap (`on_err`) logs function, line,
  and `BASH_COMMAND`, then `set -e` exits → `EXIT` trap ejects and summarises.
- `die` logs and `exit 1` → same EXIT path.
- rsync failures are caught explicitly (`if ! rsync_…`) and turned into
  `return 1`, which then aborts via `set -e` at the call site in `main`.
- Verification failures do **not** abort. They're counted, printed, and written
  to `${RUN_DIR}/verification-failures.txt`. The exit code is still 0 (see
  KNOWN_ISSUES).
- A failure *inside* verification tooling (remote/local hash command fails)
  logs an error, skips that batch, and is swallowed by `|| true` — the summary
  will still say `BACKUP COMPLETE` (see KNOWN_ISSUES #1).

### rsync invocation

```
$RSYNC -aH --delete --partial --info=progress2 --human-readable \
       --itemize-changes --stats \
       -e "ssh -o BatchMode=yes -o ConnectTimeout=10 [-i KEY]" \
       --rsync-path="sudo rsync" \
       user@host:/remote/path/  /Volumes/BackupA/immich-backup/<subpath>/
```

Output is `tee`'d to `${RUN_DIR}/rsync-<tag>.log`, then `_normalise_log`
rewrites `\r` → `\n` so progress lines don't glue onto itemize lines.
Everything downstream (byte totals, counters, verification list) is parsed
from that file.

The dump uses the same wrapper with `no-delete` (single-file source).

### Verification algorithm

1. `extract_transferred_relpaths` picks `>f` lines whose flags are
   `+++++++++` (new) or have `c` (checksum), `s` (size) or `t` (mtime) set.
   Output is NUL-separated relative paths.
2. Build two NUL lists: remote absolute paths and local absolute paths.
3. Remote: `ssh … "sudo xargs -0 sha256sum --" < list`. Local:
   `xargs -0 shasum -a 256 -- < list`.
4. Walk the relpath list and both sum files in lockstep (fd 3 and 4),
   comparing the first field of each line. Relies on output order == input order
   and on exactly one output line per input.

## State & counters

| Variable | Meaning | Notes |
|---|---|---|
| `SSH_BYTES` | Sum of "Total transferred file size" over SSH-leg rsyncs | Parsed from `--human-readable` output; approximate. |
| `LOCAL_BYTES` | Same for A→B | |
| `FILES_NEW/UPDATED/DELETED` | From itemize lines | Summed across **both** legs, so a new file counts twice when the mirror runs. |
| `VERIFY_CHECKED/PASSED/FAILED` | Verification results | Both legs. |
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
latest.log -> 2026-04-26_173312.log
```

Temporary `.relpaths.nul`, `.remote-sums.txt`, etc. are created in `RUN_DIR`
and removed after each verification batch.

## Extension points

- **Add/remove a source**: edit `SOURCES` (`REMOTE_PATH/:DEST_SUBPATH/`, keep
  trailing slashes). The tag in log names is the basename of the remote path,
  so two sources with the same basename will overwrite each other's rsync log.
- **Live DB dump**: `DB_CONTAINER/DB_USER/DB_NAME` were reserved for a
  `docker exec … pg_dumpall` path that was never written.
- **Different drive names**: `DRIVE_A`, `DRIVE_B`.
