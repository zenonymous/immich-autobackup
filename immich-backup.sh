#!/usr/bin/env bash
#
# immich-backup.sh — Manual backup of an Immich (LAN Ubuntu) instance to two
# external macOS APFS drives. Pulls remote -> Drive A over SSH, then mirrors
# Drive A -> Drive B locally. SHA-256 verifies every file rsync says it
# transferred on the SSH leg. Ejects both drives at the end (even on failure).
#
# WHY DUMP-FIRST
#   Per the Immich docs, the database dump is copied BEFORE the asset files.
#   A restored DB that references assets which haven't been copied yet is
#   recoverable; the inverse — assets present but the DB older than them —
#   leaves orphaned files and broken references.
#
# WHY --rsync-path="sudo rsync"
#   Docker writes parts of the Immich library tree as root, so an unprivileged
#   remote user can't read them as itself. The rsync trick runs the *remote*
#   rsync under sudo so it has read access to everything; only rsync is
#   privileged, the SSH session itself is not. This requires a sudoers entry
#   on the remote host (substitute your remote username):
#       <remote_user> ALL=(ALL) NOPASSWD: /usr/bin/rsync
#
# PREREQUISITES
#   - Homebrew rsync >= 3.x (`brew install rsync`). The system rsync 2.6.9
#     that ships with macOS is too old; this script picks up Homebrew's
#     /opt/homebrew/bin/rsync (Apple Silicon) or /usr/local/bin/rsync (Intel)
#     automatically.
#   - SSH key for ${REMOTE_USER}@${REMOTE_HOST} already in the agent /
#     authorized_keys on the remote, with BatchMode-friendly auth.
#   - Passwordless sudo for rsync on the remote (sudoers line above).
#   - Two external APFS drives mounted at /Volumes/BackupA and /Volumes/BackupB.
#     Either one missing is OK (the script will warn and use whichever is
#     present); both missing aborts.
#
# USAGE
#   ./immich-backup.sh
#   VERIFY_LOCAL_MIRROR=1 ./immich-backup.sh   # also checksum the A->B mirror
#
# OUT OF SCOPE
#   Restore. Encryption (FileVault is doing that). Notifications. Scheduling.
#
# ─────────────────────────────────────────────────────────────────────────

set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================================
# CONFIG — edit these
# ============================================================================

REMOTE_USER="user"                          # Edit: SSH username on the remote
REMOTE_HOST="1.2.3.4"                       # Edit: hostname or IP of the remote
SSH_KEY=""                                  # Optional override; empty => default

# Remote home directory. Almost always /home/${REMOTE_USER} on Ubuntu/Debian.
# Override if the remote uses a non-standard home location.
REMOTE_HOME="/home/${REMOTE_USER}"

# Source paths to back up. Each entry is "REMOTE_PATH:DEST_SUBPATH".
# Trailing slashes are intentional (rsync semantics: copy CONTENTS of dir).
# Add "thumbs/" or "encoded-video/" here later if you ever change your mind.
SOURCES=(
  "${REMOTE_HOME}/immich-app/library/upload/:originals/upload/"
  "${REMOTE_HOME}/immich-app/library/library/:originals/library/"
  "${REMOTE_HOME}/immich-app/library/profile/:originals/profile/"
  "${REMOTE_HOME}/photos/:external-library/photos/"
)

# Postgres dump location. We only ever copy the newest *.sql.gz from here.
DUMP_REMOTE_DIR="${REMOTE_HOME}/immich-app/library/backups"
DUMP_DEST_SUBPATH="db"

# DB defaults — unused by the default flow, kept here for future support of
# a live `docker exec ... pg_dump` path if you ever want to add one.
DB_CONTAINER="immich_postgres"
DB_USER="postgres"
DB_NAME="immich"

# Destinations (macOS APFS).
DRIVE_A="/Volumes/BackupA"
DRIVE_B="/Volumes/BackupB"
BACKUP_SUBDIR="immich-backup"

# Logging.
LOG_DIR="${HOME}/Library/Logs/immich-backup"
LOG_RETENTION=30

# Free-space headroom on each destination, as percent of the remote source
# size. The drive has to have at least (source * (100+headroom)/100) free.
HEADROOM_PCT=10

# Verification toggles.
VERIFY_LOCAL_MIRROR="${VERIFY_LOCAL_MIRROR:-0}"

# ============================================================================
# Internal state — don't edit
# ============================================================================

START_TIME="$(date +%s)"
RUN_TS="$(date +%Y-%m-%d_%H%M%S)"
LOG_FILE=""
RUN_DIR=""
RSYNC=""
declare -a SSH_OPTS=()
declare -a USED_DRIVES=()                   # Drives we've touched; eject these

# Per-leg byte/file accumulators (filled in as each rsync completes).
SSH_BYTES=0
LOCAL_BYTES=0
FILES_NEW=0
FILES_UPDATED=0
FILES_DELETED=0
VERIFY_CHECKED=0
VERIFY_PASSED=0
VERIFY_FAILED=0

# Selected by preflight().
SSH_LEG_DRIVE=""
DRIVE_A_OK=0
DRIVE_B_OK=0

# ============================================================================
# Pretty printing — coloured stdout, plain log file
# ============================================================================

if [[ -t 1 ]]; then
  C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'
  C_GRN=$'\033[32m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
  C_DIM=""; C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""; C_RST=""
fi

_emit() {
  # _emit LEVEL COLOR MESSAGE...
  local level="$1" color="$2"; shift 2
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s%s%s [%s%-5s%s] %s\n' \
    "$C_DIM" "$ts" "$C_RST" "$color" "$level" "$C_RST" "$*"
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s [%-5s] %s\n' "$ts" "$level" "$*" >> "$LOG_FILE"
  fi
}
log()  { _emit "INFO"  "$C_BLU" "$@"; }
warn() { _emit "WARN"  "$C_YEL" "$@"; }
err()  { _emit "ERROR" "$C_RED" "$@"; }
die()  { err "$@"; exit 1; }
hr()   { log "────────────────────────────────────────────────────────────"; }

# ============================================================================
# SSH plumbing
# ============================================================================

init_ssh_opts() {
  SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
  # NOTE: `[[ test ]] && cmd` as the LAST statement of a function leaks the
  # test's exit status under bash 3.2 (macOS default), tripping `set -e`.
  # Use the if/then form and an explicit return to be safe.
  if [[ -n "$SSH_KEY" ]]; then
    SSH_OPTS+=(-i "$SSH_KEY")
  fi
  return 0
}

remote_ssh() {
  ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "$@"
}

# rsync's -e takes a single string, so we flatten the SSH_OPTS array.
# (None of our options contain whitespace, so this is safe.)
ssh_string_for_rsync() {
  local s="ssh" o
  for o in "${SSH_OPTS[@]}"; do s+=" $o"; done
  printf '%s' "$s"
}

# ============================================================================
# Tooling
# ============================================================================

# Pick a non-system rsync. macOS's bundled rsync (2.6.9) lacks
# --info=progress2, modern --itemize-changes nuances, and reasonable
# --info=stats output, so we require Homebrew rsync 3.x.
detect_rsync() {
  local cand
  for cand in /opt/homebrew/bin/rsync /usr/local/bin/rsync; do
    if [[ -x "$cand" ]]; then RSYNC="$cand"; break; fi
  done
  [[ -z "$RSYNC" ]] && RSYNC="$(command -v rsync || true)"
  [[ -z "$RSYNC" || ! -x "$RSYNC" ]] && \
    die "rsync not found. Install Homebrew rsync: brew install rsync"

  local ver="" major="" rsync_out
  # Capture the whole --version output first, then parse with bash regex.
  # Don't `head -1 | grep | head -1` here: head closes the pipe before rsync
  # finishes writing, rsync gets SIGPIPE (exit 141), and pipefail propagates
  # the failure to the assignment.
  rsync_out="$("$RSYNC" --version 2>/dev/null || true)"
  # Match X.Y.Z anywhere in the first line.
  local first_line="${rsync_out%%$'\n'*}"
  if [[ "$first_line" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    ver="${BASH_REMATCH[1]}"
    major="${ver%%.*}"
  fi
  if [[ -z "${major:-}" || "$major" -lt 3 ]]; then
    die "rsync at $RSYNC is version ${ver:-unknown}; need >= 3.x. Run: brew install rsync"
  fi
  log "Using rsync: $RSYNC ($ver)"
}

human_bytes() {
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN{
    split("B KB MB GB TB PB",u," ");
    i=1; while (b>=1024 && i<6) { b/=1024; i++ }
    printf("%.2f %s", b, u[i]);
  }'
}

# ============================================================================
# Logging dir setup + retention
# ============================================================================

setup_logging() {
  mkdir -p "$LOG_DIR"
  RUN_DIR="${LOG_DIR}/${RUN_TS}"
  mkdir -p "$RUN_DIR"
  LOG_FILE="${LOG_DIR}/${RUN_TS}.log"
  : > "$LOG_FILE"
  ln -sfn "$LOG_FILE" "${LOG_DIR}/latest.log"
}

prune_old_logs() {
  # Keep the LOG_RETENTION newest top-level *.log files (excluding the
  # latest.log symlink) and per-run dirs; drop the rest.
  local victim
  while IFS= read -r victim; do
    [[ -n "$victim" ]] && rm -f -- "$victim"
  done < <(ls -1t "${LOG_DIR}"/*.log 2>/dev/null \
            | grep -v '/latest\.log$' \
            | tail -n +$((LOG_RETENTION+1)))
  while IFS= read -r victim; do
    [[ -n "$victim" && -d "$victim" ]] && rm -rf -- "$victim"
  done < <(ls -1td "${LOG_DIR}"/[0-9]*_* 2>/dev/null \
            | tail -n +$((LOG_RETENTION+1)))
}

# ============================================================================
# Pre-flight checks (fail fast before any transfer)
# ============================================================================

check_local_tools() {
  local cmd missing=()
  for cmd in ssh shasum diskutil awk find df du basename xargs tr grep; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  # Same bash 3.2 set -e wart as init_ssh_opts — use if/then.
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing local commands: ${missing[*]}"
  fi
  return 0
}

check_ssh() {
  log "Checking SSH reachability to ${REMOTE_USER}@${REMOTE_HOST}..."
  if ! remote_ssh true; then
    die "Cannot SSH to ${REMOTE_USER}@${REMOTE_HOST}. Is the key in the agent? Host reachable?"
  fi
  log "Checking passwordless sudo rsync on remote..."
  if ! remote_ssh "sudo -n /usr/bin/rsync --version" >/dev/null 2>&1; then
    die "Remote 'sudo -n /usr/bin/rsync' failed. Add sudoers line: ${REMOTE_USER} ALL=(ALL) NOPASSWD: /usr/bin/rsync"
  fi
}

drive_ready() {
  local d="$1"
  [[ -d "$d" && -w "$d" ]]
}

drive_free_bytes() {
  local d="$1" kb
  kb="$(df -P -k "$d" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ -z "${kb:-}" ]] && { echo 0; return; }
  echo $((kb * 1024))
}

# Sum of `du -sb` over each source path, plus the dump dir, on the remote.
# `du -sb` is GNU and only available on the Ubuntu side, which is exactly
# where we run it.
remote_source_bytes() {
  local paths=("$DUMP_REMOTE_DIR")
  local s
  for s in "${SOURCES[@]}"; do paths+=("${s%%:*}"); done
  local quoted="" p
  for p in "${paths[@]}"; do
    quoted+=" $(printf "%q" "$p")"
  done
  remote_ssh "sudo du -sb -- $quoted 2>/dev/null | awk '{s+=\$1} END{print s+0}'"
}

# ============================================================================
# Trap / cleanup
# ============================================================================

print_summary() {
  local rc="$1"
  local elapsed=$(($(date +%s) - START_TIME))
  hr
  log "Summary"
  log "  SSH leg bytes transferred:     $(human_bytes "$SSH_BYTES")"
  log "  Local mirror bytes:            $(human_bytes "$LOCAL_BYTES")"
  log "  Files new:                     $FILES_NEW"
  log "  Files updated:                 $FILES_UPDATED"
  log "  Files deleted:                 $FILES_DELETED"
  log "  Verification checked:          $VERIFY_CHECKED"
  log "  Verification passed:           $VERIFY_PASSED"
  log "  Verification failed:           $VERIFY_FAILED"
  log "  Total runtime:                 ${elapsed}s"
  if [[ ${#USED_DRIVES[@]} -gt 0 ]]; then
    log "  Drives ejected:                ${USED_DRIVES[*]}"
  else
    log "  Drives ejected:                none"
  fi
  hr
  if [[ $rc -eq 0 && $VERIFY_FAILED -eq 0 ]]; then
    log "BACKUP COMPLETE"
  elif [[ $rc -eq 0 && $VERIFY_FAILED -gt 0 ]]; then
    err "BACKUP FINISHED WITH VERIFICATION FAILURES (see ${RUN_DIR}/verification-failures.txt)"
  else
    err "BACKUP FAILED (exit $rc)"
  fi
}

cleanup_eject() {
  local rc=$?
  trap - EXIT ERR
  if [[ ${#USED_DRIVES[@]} -gt 0 ]]; then
    local drive
    for drive in "${USED_DRIVES[@]}"; do
      if [[ -d "$drive" ]]; then
        log "Ejecting $drive"
        diskutil eject "$drive" >/dev/null 2>&1 || warn "Failed to eject $drive"
      fi
    done
  fi
  print_summary "$rc"
  exit "$rc"
}

on_err() {
  # $1 is $LINENO at the call site, but in bash 3.2 (macOS) this often
  # resolves to the function-definition line rather than the failing
  # command. BASH_LINENO[0] is the line of the *caller* of the function
  # the trap fired in, which is what we usually want. BASH_COMMAND is
  # the literal text of the command that triggered ERR.
  local rc=$? trap_line="${1:-?}"
  local caller_line="${BASH_LINENO[0]:-?}"
  local cmd="${BASH_COMMAND:-?}"
  local fn="${FUNCNAME[1]:-main}"
  err "Unhandled error in ${fn}() near line ${caller_line} (trap line ${trap_line}, exit ${rc})"
  err "  failing command: ${cmd}"
  # Don't exit here — let the EXIT trap run cleanup with this rc.
}

mark_used() {
  local d="$1" u
  if [[ ${#USED_DRIVES[@]} -gt 0 ]]; then
    for u in "${USED_DRIVES[@]}"; do
      [[ "$u" == "$d" ]] && return 0
    done
  fi
  USED_DRIVES+=("$d")
}

# ============================================================================
# rsync wrappers
# ============================================================================

# Common flag set required by spec, plus --stats so we can parse byte totals.
RSYNC_BASE_FLAGS=(
  -aH --delete --partial --info=progress2 --human-readable
  --itemize-changes --stats
)

RSYNC_LAST_LOG=""

# After tee'ing rsync's output to the log, normalise \r (progress carriage
# returns) to \n so the file is line-grep-friendly for the parsers below.
_normalise_log() {
  local f="$1" tmp
  tmp="$(mktemp)"
  if tr '\r' '\n' < "$f" > "$tmp"; then
    mv -- "$tmp" "$f" || warn "_normalise_log: mv failed for $f"
  else
    rm -f -- "$tmp"
    warn "_normalise_log: tr failed for $f"
  fi
  return 0
}

# rsync_ssh_leg "remote_path[/]" "local_dest/" "tag" [no-delete]
rsync_ssh_leg() {
  local remote_path="$1" dest="$2" tag="$3" extra="${4:-}"
  local logfile="${RUN_DIR}/rsync-${tag}.log"
  RSYNC_LAST_LOG="$logfile"
  mkdir -p "$dest"

  local flags=("${RSYNC_BASE_FLAGS[@]}")
  if [[ "$extra" == "no-delete" ]]; then
    local newf=() f
    for f in "${flags[@]}"; do
      [[ "$f" == "--delete" ]] || newf+=("$f")
    done
    flags=("${newf[@]}")
  fi

  log "rsync (SSH): ${REMOTE_USER}@${REMOTE_HOST}:${remote_path} -> ${dest}"

  # The pipe through tee preserves live progress on stdout AND captures the
  # full transcript for post-hoc parsing. PIPESTATUS[0] keeps rsync's exit
  # code despite the success of tee.
  local rc=0
  "$RSYNC" "${flags[@]}" \
    -e "$(ssh_string_for_rsync)" \
    --rsync-path="sudo rsync" \
    "${REMOTE_USER}@${REMOTE_HOST}:${remote_path}" "$dest" \
    2>&1 | tee "$logfile" || rc=${PIPESTATUS[0]:-1}

  _normalise_log "$logfile"
  return $rc
}

# rsync_local_leg "src/" "dest/" "tag"
rsync_local_leg() {
  local src="$1" dest="$2" tag="$3"
  local logfile="${RUN_DIR}/rsync-${tag}.log"
  RSYNC_LAST_LOG="$logfile"
  mkdir -p "$dest"
  log "rsync (local): $src -> $dest"

  local rc=0
  "$RSYNC" "${RSYNC_BASE_FLAGS[@]}" "$src" "$dest" \
    2>&1 | tee "$logfile" || rc=${PIPESTATUS[0]:-1}

  _normalise_log "$logfile"
  return $rc
}

# Parse "Total transferred file size: N bytes" out of an rsync --stats log.
# With --human-readable on, N may be like "1.23M"; without, it's a raw integer
# (possibly comma-separated). Handle both.
parse_bytes_transferred() {
  local f="$1"
  awk '/^Total transferred file size:/ {
    val=$5;
    gsub(",", "", val);
    mul=1;
    if (val ~ /[KMGTP]$/) {
      ch=substr(val, length(val), 1);
      val=substr(val, 1, length(val)-1);
      if      (ch=="K") mul=1024;
      else if (ch=="M") mul=1024*1024;
      else if (ch=="G") mul=1024*1024*1024;
      else if (ch=="T") mul=1024*1024*1024*1024;
      else if (ch=="P") mul=1024*1024*1024*1024*1024;
    }
    printf("%.0f", val*mul);
    exit;
  }' "$f"
}

# Tally itemize-changes lines: new files, updated files, deletions.
tally_itemize() {
  local f="$1" n u d
  n=$(grep -c '^>f+++++++++' "$f" 2>/dev/null || true); n=${n:-0}
  # Updated = received-file lines whose change flags aren't all-+ (i.e. some
  # property differed: content, size, mtime, perms, etc.).
  u=$(grep -cE '^>f[^+]' "$f" 2>/dev/null || true); u=${u:-0}
  d=$(grep -c '^\*deleting' "$f" 2>/dev/null || true); d=${d:-0}
  FILES_NEW=$((FILES_NEW + n))
  FILES_UPDATED=$((FILES_UPDATED + u))
  FILES_DELETED=$((FILES_DELETED + d))
}

# ============================================================================
# Verification
# ============================================================================
#
# rsync --itemize-changes emits an 11-char status code "YXcstpoguax" before
# each path:
#   pos1 (Y) = update kind: '>' received, '<' sent, '.' unchanged, 'c' created
#   pos2 (X) = file type:   'f' file, 'd' dir, 'L' symlink, ...
#   pos3..11 = change flags vs. the destination (or '+++++++++' for a new file)
#       pos3 'c' = checksum/content changed
#       pos4 's' = size changed
#       pos5 't' = mtime changed
#
# We treat a file as "actually transferred" if its line starts with '>f' AND
# either the flags are all '+' (new) or any of c/s/t indicate the content or
# size or mtime drove the transfer. (Permission-only changes don't move bytes,
# so we don't bother sha-checking them.)

# Emit NUL-separated relpaths of files transferred in this rsync log.
extract_transferred_relpaths() {
  local f="$1"
  awk '
    /^>f/ {
      code = $1
      sp = index($0, " ")
      if (sp == 0) next
      path = substr($0, sp + 1)
      # Defensive: skip anything that ended up looking like a directory.
      if (path ~ /\/$/) next
      flags = substr(code, 3)
      if (flags == "+++++++++"      ||
          substr(flags, 1, 1) == "c" ||
          substr(flags, 2, 1) == "s" ||
          substr(flags, 3, 1) == "t") {
        printf "%s%c", path, 0
      }
    }
  ' "$f"
}

# Count NULs in a file (== element count of a NUL-separated list).
_count_nuls() {
  tr -cd '\0' < "$1" | wc -c | tr -d ' '
}

# Verify SSH-leg transfers: hash on remote (sudo, because Docker files are
# root-owned) and locally, then compare. Lockstep iteration relies on
# sha256sum/shasum preserving input order in their output, which they do.
verify_ssh_leg() {
  local remote_base="$1" local_dest="$2" rsync_log="$3"

  local relpaths_nul="${RUN_DIR}/.relpaths.nul"
  local remote_paths_nul="${RUN_DIR}/.remote-paths.nul"
  local local_paths_nul="${RUN_DIR}/.local-paths.nul"
  local remote_sums="${RUN_DIR}/.remote-sums.txt"
  local local_sums="${RUN_DIR}/.local-sums.txt"
  local fail_log="${RUN_DIR}/verification-failures.txt"

  : > "$relpaths_nul"
  : > "$remote_paths_nul"
  : > "$local_paths_nul"
  : > "$remote_sums"
  : > "$local_sums"

  extract_transferred_relpaths "$rsync_log" > "$relpaths_nul"
  if [[ ! -s "$relpaths_nul" ]]; then
    log "Verify (SSH leg): no new/changed files."
    return 0
  fi

  local count=0 rel
  while IFS= read -r -d '' rel; do
    printf '%s\0' "${remote_base}${rel}" >> "$remote_paths_nul"
    printf '%s\0' "${local_dest}${rel}"  >> "$local_paths_nul"
    count=$((count + 1))
  done < "$relpaths_nul"
  log "Verify (SSH leg): hashing ${count} file(s)..."

  if ! remote_ssh "sudo xargs -0 sha256sum --" < "$remote_paths_nul" \
         > "$remote_sums" 2>>"$LOG_FILE"; then
    err "Verify (SSH leg): remote sha256sum failed; skipping verification of this batch."
    rm -f "$relpaths_nul" "$remote_paths_nul" "$local_paths_nul" "$remote_sums" "$local_sums"
    return 1
  fi
  if ! xargs -0 shasum -a 256 -- < "$local_paths_nul" \
         > "$local_sums" 2>>"$LOG_FILE"; then
    err "Verify (SSH leg): local shasum failed; skipping verification of this batch."
    rm -f "$relpaths_nul" "$remote_paths_nul" "$local_paths_nul" "$remote_sums" "$local_sums"
    return 1
  fi

  local n_rel n_rem n_loc
  n_rel=$(_count_nuls "$relpaths_nul")
  n_rem=$(wc -l < "$remote_sums" | tr -d ' ')
  n_loc=$(wc -l < "$local_sums" | tr -d ' ')
  if [[ "$n_rem" != "$n_rel" || "$n_loc" != "$n_rel" ]]; then
    warn "Verify (SSH leg): line-count mismatch (rel=$n_rel remote=$n_rem local=$n_loc); results may be partial."
  fi

  exec 3<"$remote_sums"
  exec 4<"$local_sums"
  local remote_line local_line remote_hash local_hash
  while IFS= read -r -d '' rel; do
    IFS= read -r remote_line <&3 || remote_line=""
    IFS= read -r local_line  <&4 || local_line=""
    remote_hash="${remote_line%% *}"
    local_hash="${local_line%% *}"
    VERIFY_CHECKED=$((VERIFY_CHECKED + 1))
    if [[ -n "$remote_hash" && "$remote_hash" == "$local_hash" ]]; then
      VERIFY_PASSED=$((VERIFY_PASSED + 1))
      # Per-file OKs go to the file log only — keeps the console readable.
      [[ -n "$LOG_FILE" ]] && \
        printf '%s [VERIFY-OK] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$rel" >> "$LOG_FILE"
    else
      VERIFY_FAILED=$((VERIFY_FAILED + 1))
      err "VERIFY MISMATCH: $rel  remote=${remote_hash:-<none>} local=${local_hash:-<none>}"
      printf '%s\n' "${local_dest}${rel}" >> "$fail_log"
    fi
  done < "$relpaths_nul"
  exec 3<&-
  exec 4<&-

  rm -f "$relpaths_nul" "$remote_paths_nul" "$local_paths_nul" \
        "$remote_sums" "$local_sums"
}

# Local-leg verification (off by default). Identical shape to verify_ssh_leg
# but both sides are local, so no SSH/sudo needed.
verify_local_leg() {
  local src_base="$1" dst_base="$2" rsync_log="$3"
  local relpaths_nul="${RUN_DIR}/.relpaths.local.nul"
  local src_paths_nul="${RUN_DIR}/.src-paths.nul"
  local dst_paths_nul="${RUN_DIR}/.dst-paths.nul"
  local src_sums="${RUN_DIR}/.src-sums.txt"
  local dst_sums="${RUN_DIR}/.dst-sums.txt"
  local fail_log="${RUN_DIR}/verification-failures.txt"

  : > "$relpaths_nul"; : > "$src_paths_nul"; : > "$dst_paths_nul"
  : > "$src_sums";    : > "$dst_sums"

  extract_transferred_relpaths "$rsync_log" > "$relpaths_nul"
  if [[ ! -s "$relpaths_nul" ]]; then
    log "Verify (local mirror): no new/changed files."
    return 0
  fi

  local count=0 rel
  while IFS= read -r -d '' rel; do
    printf '%s\0' "${src_base}${rel}" >> "$src_paths_nul"
    printf '%s\0' "${dst_base}${rel}" >> "$dst_paths_nul"
    count=$((count + 1))
  done < "$relpaths_nul"
  log "Verify (local mirror): hashing ${count} file(s)..."

  if ! xargs -0 shasum -a 256 -- < "$src_paths_nul" > "$src_sums" 2>>"$LOG_FILE"; then
    err "Verify (local mirror): source shasum failed; skipping."
    rm -f "$relpaths_nul" "$src_paths_nul" "$dst_paths_nul" "$src_sums" "$dst_sums"
    return 1
  fi
  if ! xargs -0 shasum -a 256 -- < "$dst_paths_nul" > "$dst_sums" 2>>"$LOG_FILE"; then
    err "Verify (local mirror): dest shasum failed; skipping."
    rm -f "$relpaths_nul" "$src_paths_nul" "$dst_paths_nul" "$src_sums" "$dst_sums"
    return 1
  fi

  exec 3<"$src_sums"; exec 4<"$dst_sums"
  local sl dl sh dh
  while IFS= read -r -d '' rel; do
    IFS= read -r sl <&3 || sl=""
    IFS= read -r dl <&4 || dl=""
    sh="${sl%% *}"; dh="${dl%% *}"
    VERIFY_CHECKED=$((VERIFY_CHECKED + 1))
    if [[ -n "$sh" && "$sh" == "$dh" ]]; then
      VERIFY_PASSED=$((VERIFY_PASSED + 1))
    else
      VERIFY_FAILED=$((VERIFY_FAILED + 1))
      err "LOCAL VERIFY MISMATCH: $rel  src=${sh:-<none>} dst=${dh:-<none>}"
      printf '%s\n' "${dst_base}${rel}" >> "$fail_log"
    fi
  done < "$relpaths_nul"
  exec 3<&-; exec 4<&-

  rm -f "$relpaths_nul" "$src_paths_nul" "$dst_paths_nul" "$src_sums" "$dst_sums"
}

# ============================================================================
# Stages
# ============================================================================

find_latest_dump() {
  remote_ssh "ls -1t -- ${DUMP_REMOTE_DIR}/*.sql.gz 2>/dev/null | head -1"
}

# Copy the newest dump to one drive and prune older dumps on that drive.
fetch_latest_dump() {
  local drive="$1" tag="$2"
  local latest dump_name dest_dir

  latest="$(find_latest_dump || true)"
  if [[ -z "$latest" ]]; then
    warn "No .sql.gz dump found in ${DUMP_REMOTE_DIR} on remote"
    return 0
  fi
  dump_name="$(basename "$latest")"
  dest_dir="${drive}/${BACKUP_SUBDIR}/${DUMP_DEST_SUBPATH}"
  mkdir -p "$dest_dir"

  log "Latest dump on remote: $latest"

  # Single-file copy: no --delete (we'd risk wiping unrelated files), and we
  # do retention via prune_old_dumps below.
  if ! rsync_ssh_leg "$latest" "${dest_dir}/" "dump-${tag}" "no-delete"; then
    err "rsync of dump failed: $latest"
    return 1
  fi

  local bytes; bytes="$(parse_bytes_transferred "$RSYNC_LAST_LOG")"
  SSH_BYTES=$((SSH_BYTES + ${bytes:-0}))
  tally_itemize "$RSYNC_LAST_LOG"

  # Verify only when this is the SSH-leg drive (per spec).
  if [[ "$drive" == "$SSH_LEG_DRIVE" ]]; then
    verify_ssh_leg "${DUMP_REMOTE_DIR}/" "${dest_dir}/" "$RSYNC_LAST_LOG" || true
  fi

  prune_old_dumps "$dest_dir" "$dump_name"
}

prune_old_dumps() {
  local dir="$1" keep="$2"
  [[ -d "$dir" ]] || return 0
  local f removed=0
  while IFS= read -r f; do
    if [[ "$(basename "$f")" != "$keep" ]]; then
      rm -f -- "$f" && removed=$((removed + 1))
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.sql.gz' 2>/dev/null)
  [[ $removed -gt 0 ]] && log "Pruned $removed older dump(s) from $dir"
  return 0
}

# Pull every entry from $SOURCES to one drive over SSH.
sync_remote_to_drive() {
  local drive="$1" tag="$2"
  local entry remote_path dest_subpath dest stem

  for entry in "${SOURCES[@]}"; do
    remote_path="${entry%%:*}"
    dest_subpath="${entry#*:}"
    dest="${drive}/${BACKUP_SUBDIR}/${dest_subpath}"
    stem="$(basename "${remote_path%/}")"

    if ! rsync_ssh_leg "$remote_path" "$dest" "${tag}-${stem}"; then
      err "rsync failed for ${remote_path} -> ${dest}"
      return 1
    fi
    local bytes; bytes="$(parse_bytes_transferred "$RSYNC_LAST_LOG")"
    SSH_BYTES=$((SSH_BYTES + ${bytes:-0}))
    tally_itemize "$RSYNC_LAST_LOG"

    if [[ "$drive" == "$SSH_LEG_DRIVE" ]]; then
      verify_ssh_leg "$remote_path" "$dest" "$RSYNC_LAST_LOG" || true
    fi
  done
}

mirror_a_to_b() {
  local src="${DRIVE_A}/${BACKUP_SUBDIR}/"
  local dst="${DRIVE_B}/${BACKUP_SUBDIR}/"
  if ! rsync_local_leg "$src" "$dst" "mirror-a-to-b"; then
    err "Local mirror A -> B failed"
    return 1
  fi
  local bytes; bytes="$(parse_bytes_transferred "$RSYNC_LAST_LOG")"
  LOCAL_BYTES=$((LOCAL_BYTES + ${bytes:-0}))
  tally_itemize "$RSYNC_LAST_LOG"

  if [[ "$VERIFY_LOCAL_MIRROR" == "1" ]]; then
    log "VERIFY_LOCAL_MIRROR=1 — verifying transferred files for the local mirror leg."
    verify_local_leg "$src" "$dst" "$RSYNC_LAST_LOG" || true
  fi
}

# ============================================================================
# Main
# ============================================================================

preflight() {
  setup_logging
  prune_old_logs
  log "==== immich-backup.sh starting at $(date) ===="
  log "Run log: $LOG_FILE"
  log "Run dir: $RUN_DIR"

  init_ssh_opts
  detect_rsync
  check_local_tools
  check_ssh

  # Drive availability.
  if drive_ready "$DRIVE_A"; then
    DRIVE_A_OK=1; log "Drive A present: $DRIVE_A"
  else
    warn "Drive A missing or not writable: $DRIVE_A"
  fi
  if drive_ready "$DRIVE_B"; then
    DRIVE_B_OK=1; log "Drive B present: $DRIVE_B"
  else
    warn "Drive B missing or not writable: $DRIVE_B"
  fi
  if [[ $DRIVE_A_OK -eq 0 && $DRIVE_B_OK -eq 0 ]]; then
    die "Neither $DRIVE_A nor $DRIVE_B is mounted. Aborting."
  fi

  # Source size + headroom.
  log "Computing remote source size (sudo du -sb)..."
  local src_bytes
  src_bytes="$(remote_source_bytes || echo 0)"
  src_bytes="${src_bytes:-0}"
  local needed=$(( src_bytes * (100 + HEADROOM_PCT) / 100 ))
  log "Remote source size:                $(human_bytes "$src_bytes")"
  log "Required (with ${HEADROOM_PCT}% headroom):       $(human_bytes "$needed")"

  if [[ $DRIVE_A_OK -eq 1 ]]; then
    local fa; fa="$(drive_free_bytes "$DRIVE_A")"
    log "Drive A free:                      $(human_bytes "$fa")"
    if [[ $fa -lt $needed ]]; then
      warn "Drive A has insufficient free space; skipping it."
      DRIVE_A_OK=0
    fi
  fi
  if [[ $DRIVE_B_OK -eq 1 ]]; then
    local fb; fb="$(drive_free_bytes "$DRIVE_B")"
    log "Drive B free:                      $(human_bytes "$fb")"
    if [[ $fb -lt $needed ]]; then
      warn "Drive B has insufficient free space; skipping it."
      DRIVE_B_OK=0
    fi
  fi
  if [[ $DRIVE_A_OK -eq 0 && $DRIVE_B_OK -eq 0 ]]; then
    die "No drive has enough free space. Aborting."
  fi

  # The SSH leg goes to A by preference; falls back to B if A is unavailable.
  if [[ $DRIVE_A_OK -eq 1 ]]; then
    SSH_LEG_DRIVE="$DRIVE_A"
  else
    SSH_LEG_DRIVE="$DRIVE_B"
  fi

  hr
  log "Configuration"
  log "  Remote:           ${REMOTE_USER}@${REMOTE_HOST}"
  log "  Drive A:          ${DRIVE_A}  (ok=${DRIVE_A_OK})"
  log "  Drive B:          ${DRIVE_B}  (ok=${DRIVE_B_OK})"
  log "  SSH leg target:   ${SSH_LEG_DRIVE}"
  log "  Local mirror:     $([[ $DRIVE_A_OK -eq 1 && $DRIVE_B_OK -eq 1 ]] && echo "A -> B" || echo "skipped (only one drive)")"
  log "  Verify local A->B: ${VERIFY_LOCAL_MIRROR}"
  log "  Sources:"
  local s
  for s in "${SOURCES[@]}"; do log "    - ${s}"; done
  log "  Dump dir:         ${DUMP_REMOTE_DIR}"
  hr
}

main() {
  trap 'on_err $LINENO' ERR
  trap cleanup_eject EXIT

  preflight

  # ── Stage 1: SSH leg → primary drive ─────────────────────────────────────
  mark_used "$SSH_LEG_DRIVE"
  local stage_start

  # DUMP FIRST: a restorable DB pointing at not-yet-copied assets is fine,
  # the inverse leaves orphans. See the file header for the full rationale.
  stage_start=$(date +%s)
  log "BEGIN  fetch latest DB dump (target: ${SSH_LEG_DRIVE})"
  fetch_latest_dump "$SSH_LEG_DRIVE" "$(basename "$SSH_LEG_DRIVE")"
  log "END    fetch latest DB dump            (elapsed $(( $(date +%s) - stage_start ))s)"

  stage_start=$(date +%s)
  log "BEGIN  sync remote sources -> ${SSH_LEG_DRIVE}"
  sync_remote_to_drive "$SSH_LEG_DRIVE" "$(basename "$SSH_LEG_DRIVE")"
  log "END    sync remote sources             (elapsed $(( $(date +%s) - stage_start ))s)"

  # ── Stage 2: local mirror, only when A was the primary AND B is available ─
  if [[ "$SSH_LEG_DRIVE" == "$DRIVE_A" && $DRIVE_B_OK -eq 1 ]]; then
    mark_used "$DRIVE_B"
    stage_start=$(date +%s)
    log "BEGIN  mirror Drive A -> Drive B"
    mirror_a_to_b
    log "END    mirror A -> B                   (elapsed $(( $(date +%s) - stage_start ))s)"
  elif [[ "$SSH_LEG_DRIVE" == "$DRIVE_B" && $DRIVE_A_OK -eq 1 ]]; then
    # Edge case (unlikely): A came back online after pre-flight ruled it out.
    # We don't auto-reverse the mirror direction; the spec is "remote -> A,
    # then A -> B", so honour that and skip.
    warn "SSH leg targeted Drive B but Drive A is also present; not auto-mirroring B->A."
  else
    log "Only one drive used; skipping local mirror."
  fi
}

main "$@"
