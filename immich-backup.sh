#!/usr/bin/env bash
#
# immich-backup.sh — Manual backup of an Immich (LAN Ubuntu) instance to two
# external macOS APFS drives. Pulls remote -> Drive A over SSH, then mirrors
# Drive A -> Drive B locally. SHA-256 verifies every file rsync says it
# transferred on the SSH leg. Ejects both drives at the end (even on failure).
#
# WHY DUMP-FIRST
#   The database dump is copied BEFORE the asset files, so the backed-up
#   assets are always at least as new as the DB. After a restore the worst
#   case is files the DB doesn't know about (harmless), never DB rows that
#   point at files missing from the backup. The dump is Immich's own nightly
#   one; the script refuses to run if it's missing or too old.
#
# WHY --rsync-path="sudo rsync"
#   Docker writes parts of the Immich library tree as root, so an unprivileged
#   remote user can't read them as itself. The rsync trick runs the *remote*
#   rsync under sudo so it has read access to everything; only rsync is
#   privileged, the SSH session itself is not. du (free-space check) and
#   sha256sum (verification) need root for the same reason. This requires a
#   sudoers entry on the remote host (substitute your remote username):
#       <remote_user> ALL=(ALL) NOPASSWD: /usr/bin/rsync, /usr/bin/du, /usr/bin/sha256sum
#
# PREREQUISITES
#   - Homebrew rsync >= 3.x (`brew install rsync`). The system rsync 2.6.9
#     that ships with macOS is too old; this script picks up Homebrew's
#     /opt/homebrew/bin/rsync (Apple Silicon) or /usr/local/bin/rsync (Intel)
#     automatically.
#   - SSH key for ${REMOTE_USER}@${REMOTE_HOST} already in the agent /
#     authorized_keys on the remote, with BatchMode-friendly auth.
#   - Passwordless sudo for rsync, du and sha256sum on the remote (above).
#   - Two external APFS drives mounted at /Volumes/BackupA and /Volumes/BackupB.
#     Either one missing is OK (the script will warn and use whichever is
#     present); both missing aborts.
#
# USAGE
#   ./immich-backup.sh
#   VERIFY_LOCAL_MIRROR=1 ./immich-backup.sh   # also checksum the A->B mirror
#   MAX_DELETE=unlimited ./immich-backup.sh    # allow a large intended deletion
#   DUMP_MAX_AGE_HOURS=0 ./immich-backup.sh    # accept an old DB dump
#
# EXIT CODES
#   0  backup complete, everything transferred was verified
#   1  failed (pre-flight check, rsync error, deletion limit hit, ...)
#   2  finished, but some files failed verification
#   3  finished, but some transferred files couldn't be verified
#
# OUT OF SCOPE
#   Restore. Encryption (FileVault is doing that). Notifications. Scheduling.
#
# ─────────────────────────────────────────────────────────────────────────

set -Eeuo pipefail
IFS=$'\n\t'

# Values that can be overridden from the environment for one run. Captured
# before the defaults below, so they win over both defaults and config file.
ENV_VERIFY_LOCAL_MIRROR="${VERIFY_LOCAL_MIRROR-}"
ENV_MAX_DELETE="${MAX_DELETE-}"
ENV_DUMP_MAX_AGE_HOURS="${DUMP_MAX_AGE_HOURS-}"

# ============================================================================
# CONFIG — defaults
# ============================================================================
#
# Don't edit these here: put your settings in a config file instead, so
# updating the script doesn't overwrite them. The file is plain bash,
# sourced after these defaults; set only what you need. Location:
#   ${XDG_CONFIG_HOME:-~/.config}/immich-backup/config
# or pass --config FILE, or set IMMICH_BACKUP_CONFIG. A commented example
# ships as immich-backup.conf.example.

REMOTE_USER="user"                          # SSH username on the remote
REMOTE_HOST="1.2.3.4"                       # Hostname or IP of the remote
SSH_KEY=""                                  # Optional -i key; empty => default
# Extra ssh options, e.g. (-p 2222 -o UserKnownHostsFile=/path). Used for
# both ssh and rsync's -e, so no element may contain whitespace.
SSH_EXTRA_OPTS=()

# Remote home directory. Empty => /home/${REMOTE_USER}.
REMOTE_HOME=""

# Source paths to back up. Each entry is "REMOTE_PATH:DEST_SUBPATH".
# Trailing slashes are intentional (rsync semantics: copy CONTENTS of dir).
# Empty => upload/, library/, profile/ from ${REMOTE_HOME}/immich-app/library
# and ${REMOTE_HOME}/photos (see finalize_config). Every source must exist
# and be non-empty on the remote.
SOURCES=()

# Remote paths that must be mount points (e.g. a disk or NAS share holding
# the external library). If one isn't mounted, the run aborts before any
# transfer instead of letting `rsync --delete` mirror an empty directory.
# Example: REMOTE_MOUNTPOINTS=("/home/me/photos")
REMOTE_MOUNTPOINTS=()

# Postgres dump location. We only ever copy the newest *.sql.gz from here.
# Empty => ${REMOTE_HOME}/immich-app/library/backups.
DUMP_REMOTE_DIR=""
DUMP_DEST_SUBPATH="db"

# Abort if the newest dump is older than this many hours (Immich writes one
# nightly by default). 0 disables the check. Env override for one run:
#   DUMP_MAX_AGE_HOURS=0 ./immich-backup.sh
DUMP_MAX_AGE_HOURS=26

# Maximum number of files a single rsync call may delete on the destination.
# Protects against a source that was emptied by mistake. When the limit is hit
# rsync stops deleting, the run aborts, and the A->B mirror is skipped so
# Drive B keeps the previous state. "unlimited" disables the limit. Env
# override for one run:
#   MAX_DELETE=unlimited ./immich-backup.sh
MAX_DELETE=1000

# DB defaults — unused by the default flow, kept here for future support of
# a live `docker exec ... pg_dump` path if you ever want to add one.
# shellcheck disable=SC2034
DB_CONTAINER="immich_postgres"
# shellcheck disable=SC2034
DB_USER="postgres"
# shellcheck disable=SC2034
DB_NAME="immich"

# Destinations (macOS APFS).
DRIVE_A="/Volumes/BackupA"
DRIVE_B="/Volumes/BackupB"
BACKUP_SUBDIR="immich-backup"

# Refuse a drive path that isn't the mount point of its own volume (e.g. a
# leftover empty folder in /Volumes after an unclean eject).
REQUIRE_DRIVE_MOUNT=1

# Logging.
LOG_DIR="${HOME}/Library/Logs/immich-backup"
LOG_RETENTION=30

# Free-space headroom, as percent of the data a drive still needs. The drive
# must have at least (missing_bytes * (100+headroom)/100) free.
HEADROOM_PCT=10

# Also SHA-256 verify the A->B mirror (slower). Env override for one run:
#   VERIFY_LOCAL_MIRROR=1 ./immich-backup.sh
VERIFY_LOCAL_MIRROR=0

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
MIRROR_NEW=0
MIRROR_UPDATED=0
MIRROR_DELETED=0
VERIFY_CHECKED=0
VERIFY_PASSED=0
VERIFY_FAILED=0
VERIFY_UNVERIFIED=0                         # Transferred but couldn't be hashed
RSYNC_WARNINGS=0                            # Non-fatal rsync exits (24)

# Selected by preflight().
SSH_LEG_DRIVE=""
DRIVE_A_OK=0
DRIVE_B_OK=0
DUMP_PATH=""                                # Newest remote dump (preflight)

# Set by parse_args() / main().
DRY_RUN=0
CONFIG_FILE=""
LOCK_DIR=""
LOCK_HELD=0

# ============================================================================
# Pretty printing — coloured stdout, plain log file
# ============================================================================

# shellcheck disable=SC2034  # C_GRN is part of the palette, unused for now
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
# Arguments and config file
# ============================================================================

usage() {
  cat <<'USAGE'
Usage: immich-backup.sh [--dry-run] [--config FILE] [--help]

Back up an Immich server to two external drives (remote -> A, then A -> B).

  -n, --dry-run    Run all pre-flight checks, then show what the SSH leg would
                   copy and delete (rsync -n). Nothing is written to the
                   drives; no verification, no mirror, no eject.
  -c, --config F   Read settings from F instead of the default
                   ${XDG_CONFIG_HOME:-~/.config}/immich-backup/config
                   (also: IMMICH_BACKUP_CONFIG=F).
  -h, --help       Show this help.

One-run overrides via environment: VERIFY_LOCAL_MIRROR=1, MAX_DELETE=N|unlimited,
DUMP_MAX_AGE_HOURS=N (0 = don't check).

Exit codes: 0 ok, 1 failed, 2 verification failures, 3 some files unverified,
64 bad command line.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run) DRY_RUN=1 ;;
      -c|--config)
        if [[ $# -lt 2 ]]; then usage >&2; exit 64; fi
        CONFIG_FILE="$2"; shift ;;
      --config=*)   CONFIG_FILE="${1#--config=}" ;;
      -h|--help)    usage; exit 0 ;;
      *)            echo "Unknown argument: $1" >&2; usage >&2; exit 64 ;;
    esac
    shift
  done
  return 0
}

# Source the config file, if there is one. It's executed as bash, so refuse
# one that other users could have written to.
load_config() {
  local f="$CONFIG_FILE" explicit=1
  if [[ -z "$f" ]]; then
    f="${IMMICH_BACKUP_CONFIG:-}"
  fi
  if [[ -z "$f" ]]; then
    explicit=0
    f="${XDG_CONFIG_HOME:-${HOME}/.config}/immich-backup/config"
  fi
  if [[ ! -f "$f" ]]; then
    if [[ $explicit -eq 1 ]]; then
      die "Config file not found: $f"
    fi
    CONFIG_FILE=""
    return 0
  fi
  if [[ -n "$(find "$f" -maxdepth 0 \( -perm -020 -o -perm -002 \) 2>/dev/null)" ]]; then
    die "Config file $f is writable by group/others; fix with: chmod go-w '$f'"
  fi
  # shellcheck source=/dev/null
  source "$f"
  CONFIG_FILE="$f"
  return 0
}

# Fill in derived defaults, apply env overrides, validate. Runs after
# load_config so derived paths follow a REMOTE_USER set in the config file.
finalize_config() {
  if [[ -z "$REMOTE_HOME" ]]; then REMOTE_HOME="/home/${REMOTE_USER}"; fi
  if [[ -z "$DUMP_REMOTE_DIR" ]]; then
    DUMP_REMOTE_DIR="${REMOTE_HOME}/immich-app/library/backups"
  fi
  if [[ ${#SOURCES[@]} -eq 0 ]]; then
    SOURCES=(
      "${REMOTE_HOME}/immich-app/library/upload/:originals/upload/"
      "${REMOTE_HOME}/immich-app/library/library/:originals/library/"
      "${REMOTE_HOME}/immich-app/library/profile/:originals/profile/"
      "${REMOTE_HOME}/photos/:external-library/photos/"
    )
  fi
  if [[ -n "$ENV_VERIFY_LOCAL_MIRROR" ]]; then VERIFY_LOCAL_MIRROR="$ENV_VERIFY_LOCAL_MIRROR"; fi
  if [[ -n "$ENV_MAX_DELETE" ]]; then MAX_DELETE="$ENV_MAX_DELETE"; fi
  if [[ -n "$ENV_DUMP_MAX_AGE_HOURS" ]]; then DUMP_MAX_AGE_HOURS="$ENV_DUMP_MAX_AGE_HOURS"; fi

  if [[ "$REMOTE_HOST" == "1.2.3.4" ]]; then
    die "REMOTE_HOST is still the placeholder 1.2.3.4. Set REMOTE_USER and REMOTE_HOST in your config file (see immich-backup.conf.example)."
  fi
  if [[ ! "$MAX_DELETE" =~ ^[0-9]+$ && "$MAX_DELETE" != "unlimited" ]]; then
    die "MAX_DELETE must be a number or 'unlimited' (got '$MAX_DELETE')"
  fi
  if [[ ! "$DUMP_MAX_AGE_HOURS" =~ ^[0-9]+$ ]]; then
    die "DUMP_MAX_AGE_HOURS must be a whole number (got '$DUMP_MAX_AGE_HOURS')"
  fi
  if [[ "$VERIFY_LOCAL_MIRROR" != "0" && "$VERIFY_LOCAL_MIRROR" != "1" ]]; then
    die "VERIFY_LOCAL_MIRROR must be 0 or 1 (got '$VERIFY_LOCAL_MIRROR')"
  fi
  local s o
  if [[ ${#SSH_EXTRA_OPTS[@]} -gt 0 ]]; then
    for o in "${SSH_EXTRA_OPTS[@]}"; do
      if [[ "$o" == *[[:space:]]* ]]; then
        die "SSH_EXTRA_OPTS element '$o' contains whitespace; split it into separate elements."
      fi
    done
  fi
  if [[ "$SSH_KEY" == *[[:space:]]* ]]; then
    die "SSH_KEY path '$SSH_KEY' contains whitespace, which rsync's -e can't pass through."
  fi
  for s in "${SOURCES[@]}"; do
    if [[ "$s" != *:* || "${s%%:*}" != /*/ || "${s#*:}" != */ ]]; then
      die "Bad SOURCES entry '$s': expected /absolute/remote/dir/:dest/subdir/ (both with trailing slash)"
    fi
  done

  # Common flag set, plus --stats so we can parse byte totals.
  # -8 prints non-ASCII filenames raw instead of \#ooo escapes, whatever the
  # locale, so the verification step gets real paths. No --human-readable: it
  # makes the --stats byte counts approximate (and locale-dependent).
  RSYNC_BASE_FLAGS=(
    -aH -8 --delete --partial --info=progress2
    --itemize-changes --stats
  )
  if [[ "$MAX_DELETE" != "unlimited" ]]; then
    RSYNC_BASE_FLAGS+=(--max-delete="$MAX_DELETE")
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    RSYNC_BASE_FLAGS+=(--dry-run)
  fi
  LOCK_DIR="${LOG_DIR}/.lock"
  return 0
}

# ============================================================================
# Single-run lock, sleep prevention
# ============================================================================

# mkdir is atomic, so it works as a lock on any filesystem. The owner's PID
# goes inside so a lock left by a crashed run can be detected and cleared.
acquire_lock() {
  mkdir -p "$LOG_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local pid
    pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
    if [[ -z "$pid" ]]; then
      die "Lock ${LOCK_DIR} exists without a PID. If no other run is going, remove it: rm -r '${LOCK_DIR}'"
    fi
    if kill -0 "$pid" 2>/dev/null; then
      die "Another immich-backup run is in progress (pid $pid). Aborting."
    fi
    warn "Removing stale lock left by pid $pid (no longer running)."
    rm -rf -- "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      die "Couldn't take the lock ${LOCK_DIR}; another run may have just started."
    fi
  fi
  echo "$$" > "${LOCK_DIR}/pid"
  LOCK_HELD=1
  return 0
}

release_lock() {
  if [[ $LOCK_HELD -eq 1 ]]; then
    rm -rf -- "$LOCK_DIR"
    LOCK_HELD=0
  fi
  return 0
}

# Keep the Mac awake (idle, disk and, on AC power, system sleep) until this
# process exits. caffeinate -w watches our PID, so no cleanup is needed.
keep_awake() {
  if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -ims -w "$$" >/dev/null 2>&1 &
    log "Sleep prevention on (caffeinate)."
  fi
  return 0
}

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
  if [[ ${#SSH_EXTRA_OPTS[@]} -gt 0 ]]; then
    SSH_OPTS+=("${SSH_EXTRA_OPTS[@]}")
  fi
  return 0
}

# The command string is expanded locally on purpose: callers quote remote
# paths with printf %q before passing them in.
remote_ssh() {
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "$@"
}

# rsync's -e takes a single string, so we flatten the SSH_OPTS array.
# (finalize_config rejects options containing whitespace, so this is safe.)
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
  # latest.log symlink) and per-run dirs; drop the rest. The two kinds are
  # counted separately: the run-dir glob also matches the .log files.
  local victim n=0
  while IFS= read -r victim; do
    [[ -z "$victim" || "$victim" == */latest.log ]] && continue
    n=$((n + 1))
    if [[ $n -gt $LOG_RETENTION ]]; then rm -f -- "$victim"; fi
  done < <(ls -1t "${LOG_DIR}"/*.log 2>/dev/null || true)
  n=0
  while IFS= read -r victim; do
    [[ -d "$victim" && ! -L "$victim" ]] || continue
    n=$((n + 1))
    if [[ $n -gt $LOG_RETENTION ]]; then rm -rf -- "$victim"; fi
  done < <(ls -1td "${LOG_DIR}"/[0-9]*_[0-9]* 2>/dev/null || true)
  return 0
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
  # rsync reads the library; du sizes it for the free-space check; sha256sum
  # verifies transferred files. All three need root because Docker owns the
  # files, so all three must be allowed by sudoers without a password.
  log "Checking passwordless sudo for rsync, du and sha256sum on remote..."
  local cmd
  for cmd in rsync du sha256sum; do
    if ! remote_ssh "sudo -n /usr/bin/${cmd} --version" >/dev/null 2>&1; then
      die "Remote 'sudo -n /usr/bin/${cmd}' failed. Sudoers line needed: ${REMOTE_USER} ALL=(ALL) NOPASSWD: /usr/bin/rsync, /usr/bin/du, /usr/bin/sha256sum"
    fi
  done
}

# Refuse to continue if a source is missing, empty, or (for paths listed in
# REMOTE_MOUNTPOINTS) not mounted. An empty source + `rsync --delete` would
# wipe that part of the backup on Drive A, then on Drive B via the mirror.
check_remote_sources() {
  local m s remote_path listing
  if [[ ${#REMOTE_MOUNTPOINTS[@]} -gt 0 ]]; then
    for m in "${REMOTE_MOUNTPOINTS[@]}"; do
      if ! remote_ssh "mountpoint -q -- $(printf '%q' "$m")"; then
        die "Remote path $m is not a mount point (not mounted?). Aborting before anything is deleted."
      fi
      log "Remote mount OK: $m"
    done
  fi
  for s in "${SOURCES[@]}"; do
    remote_path="${s%%:*}"
    # --list-only goes through `sudo rsync`, so it sees root-owned dirs.
    # Output has one line per entry; the dir itself shows up as ".".
    if ! listing="$("$RSYNC" --list-only -e "$(ssh_string_for_rsync)" \
                      --rsync-path="sudo rsync" \
                      "${REMOTE_USER}@${REMOTE_HOST}:${remote_path}" 2>&1)"; then
      err "$listing"
      die "Remote source ${remote_path} is missing or unreadable. Aborting."
    fi
    if ! grep -qv ' \.$' <<< "$listing"; then
      die "Remote source ${remote_path} is empty. Refusing to mirror an empty directory with --delete. If it's supposed to be empty, remove it from SOURCES. Aborting."
    fi
  done
  log "All ${#SOURCES[@]} remote sources present and non-empty."
}

# Prints "<age_seconds><TAB><path>" for the newest dump, or nothing. The age
# is computed on the remote so clock skew between the machines doesn't matter.
find_latest_dump() {
  local d; d="$(printf '%q' "$DUMP_REMOTE_DIR")"
  remote_ssh "f=\$(ls -1t -- ${d}/*.sql.gz 2>/dev/null | head -n 1); if [ -n \"\$f\" ]; then printf '%s\t%s\n' \"\$(( \$(date +%s) - \$(stat -c %Y -- \"\$f\") ))\" \"\$f\"; fi"
}

# A backup without a usable DB dump restores photos but not albums, people,
# faces or metadata, so a missing or stale dump is fatal.
check_dump() {
  local line age_s path tab=$'\t'
  line="$(find_latest_dump || true)"
  if [[ -z "$line" ]]; then
    die "No *.sql.gz dump found in ${DUMP_REMOTE_DIR} on remote (or it isn't readable by ${REMOTE_USER}). Enable Immich's database backup job (Administration > Settings > Backup Settings)."
  fi
  IFS="$tab" read -r age_s path <<< "$line"
  if [[ ! "$age_s" =~ ^-?[0-9]+$ ]]; then
    die "Couldn't determine the age of the remote dump: $line"
  fi
  log "Latest dump on remote: $path ($((age_s / 3600))h old)"
  if [[ "$DUMP_MAX_AGE_HOURS" -gt 0 && $age_s -gt $((DUMP_MAX_AGE_HOURS * 3600)) ]]; then
    die "Newest dump is $((age_s / 3600))h old (limit ${DUMP_MAX_AGE_HOURS}h). Check Immich's backup job, or rerun with DUMP_MAX_AGE_HOURS=0 to accept it."
  fi
  DUMP_PATH="$path"
}

# Mount point of the filesystem holding $1 (df -P's last column; may
# contain spaces, so join fields 6..NF).
mount_point_of() {
  df -P "$1" 2>/dev/null | awk 'NR==2 { mp=$6; for (i=7; i<=NF; i++) mp = mp " " $i; print mp }'
}

# drive_ready A|B PATH — is this drive usable as that role? Returns 1 (with a
# warning) if it's absent, not a real mounted volume, or read-only. Dies if
# the drive is tagged as the *other* role: that means the two drives are
# mixed up, and syncing would go the wrong way.
#
# Each drive carries a marker file ".immich-backup-drive" containing "A" or
# "B" at its root. An untagged drive gets tagged on first use (not in a dry
# run). The marker lives outside BACKUP_SUBDIR, so the mirror doesn't copy it.
drive_ready() {
  local role="$1" d="$2" marker tag
  marker="${d}/.immich-backup-drive"
  if [[ ! -d "$d" ]]; then
    warn "Drive ${role} missing: $d"
    return 1
  fi
  if [[ "$REQUIRE_DRIVE_MOUNT" == "1" && "$(mount_point_of "$d")" != "$d" ]]; then
    warn "Drive ${role}: $d exists but isn't a mounted volume (leftover folder?). Skipping it."
    return 1
  fi
  if [[ ! -w "$d" ]]; then
    warn "Drive ${role} not writable: $d"
    return 1
  fi
  if [[ -f "$marker" ]]; then
    tag="$(head -n 1 "$marker" 2>/dev/null | tr -d '[:space:]')" || true
    if [[ "$tag" != "$role" ]]; then
      die "The drive at $d is tagged as drive '${tag}', but is mounted as drive ${role}. Are the drives swapped (rename them in Disk Utility), or is this the wrong disk?"
    fi
  elif [[ $DRY_RUN -eq 1 ]]; then
    log "Drive ${role} has no tag yet; a real run would tag it (${marker})."
  else
    printf '%s\n' "$role" > "$marker"
    log "Tagged $d as drive ${role} (${marker})."
  fi
  log "Drive ${role} present: $d"
  return 0
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
  local quoted="" p out
  for p in "${paths[@]}"; do
    quoted+=" $(printf "%q" "$p")"
  done
  # Fail loudly: a silent 0 here would disable the free-space check.
  # No die here: this runs in a command substitution, so the caller dies.
  if ! out="$(remote_ssh "sudo -n /usr/bin/du -sb -- $quoted" 2>>"$LOG_FILE")"; then
    return 1
  fi
  printf '%s\n' "$out" | awk '{s+=$1} END{printf "%.0f", s}'
}

# Bytes already in the backup dir on a local drive. BSD du has no -b, so use
# -k (allocated size; close enough for a headroom check).
local_backup_bytes() {
  local p="$1/${BACKUP_SUBDIR}" kb
  if [[ ! -d "$p" ]]; then echo 0; return 0; fi
  kb="$(du -sk "$p" 2>/dev/null | awk '{print $1}')" || true
  echo $(( ${kb:-0} * 1024 ))
}

# Bytes a drive still needs for this run: what isn't there yet, plus headroom.
drive_needed_bytes() {
  local src="$1" have="$2" delta
  delta=$(( src - have ))
  if [[ $delta -lt 0 ]]; then delta=0; fi
  echo $(( delta * (100 + HEADROOM_PCT) / 100 ))
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
  log "  SSH leg files new/upd/del:     ${FILES_NEW} / ${FILES_UPDATED} / ${FILES_DELETED}"
  log "  Local mirror bytes:            $(human_bytes "$LOCAL_BYTES")"
  log "  Mirror files new/upd/del:      ${MIRROR_NEW} / ${MIRROR_UPDATED} / ${MIRROR_DELETED}"
  log "  Verification checked:          $VERIFY_CHECKED"
  log "  Verification passed:           $VERIFY_PASSED"
  log "  Verification failed:           $VERIFY_FAILED"
  log "  Verification not possible:     $VERIFY_UNVERIFIED"
  log "  rsync warnings (vanished):     $RSYNC_WARNINGS"
  log "  Total runtime:                 ${elapsed}s"
  if [[ $DRY_RUN -eq 1 ]]; then
    log "  Drives ejected:                none (dry run)"
  elif [[ ${#USED_DRIVES[@]} -gt 0 ]]; then
    local IFS=' '
    log "  Drives ejected:                ${USED_DRIVES[*]}"
  else
    log "  Drives ejected:                none"
  fi
  hr
  # rc here is the final exit code (see cleanup_eject).
  if [[ $DRY_RUN -eq 1 ]]; then
    if [[ $rc -eq 0 ]]; then
      log "DRY RUN COMPLETE: nothing was changed. The SSH-leg numbers above are what a real run would do."
    else
      err "DRY RUN FAILED (exit $rc): a real run would stop here too."
    fi
  elif [[ $rc -eq 0 ]]; then
    log "BACKUP COMPLETE"
  elif [[ $rc -eq 2 ]]; then
    err "BACKUP FINISHED WITH VERIFICATION FAILURES (exit 2; see ${RUN_DIR}/verification-failures.txt)"
  elif [[ $rc -eq 3 ]]; then
    err "BACKUP FINISHED BUT ${VERIFY_UNVERIFIED} FILE(S) COULD NOT BE VERIFIED (exit 3; see ${RUN_DIR}/unverified.txt)"
  else
    err "BACKUP FAILED (exit $rc)"
  fi
}

cleanup_eject() {
  local rc=$?
  trap - EXIT ERR
  # A dry run leaves the drives mounted: a real run usually follows.
  if [[ $DRY_RUN -eq 0 && ${#USED_DRIVES[@]} -gt 0 ]]; then
    local drive
    for drive in "${USED_DRIVES[@]}"; do
      if [[ -d "$drive" ]]; then
        log "Ejecting $drive"
        diskutil eject "$drive" >/dev/null 2>&1 || warn "Failed to eject $drive"
      fi
    done
  fi
  # Exit codes: 0 ok, 1 failed, 2 verification mismatches, 3 some transferred
  # files couldn't be verified. A hard failure (rc != 0) takes precedence.
  if [[ $rc -eq 0 ]]; then
    if [[ $VERIFY_FAILED -gt 0 ]]; then
      rc=2
    elif [[ $VERIFY_UNVERIFIED -gt 0 ]]; then
      rc=3
    fi
  fi
  print_summary "$rc"
  release_lock
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

# Set by finalize_config(): -aH -8 --delete ... (+ --max-delete, --dry-run).
RSYNC_BASE_FLAGS=()

RSYNC_LAST_LOG=""

# Map rsync exit codes that need special handling. Returns the code the
# caller should act on.
_rsync_rc() {
  local rc="$1" what="$2"
  if [[ $rc -eq 24 ]]; then
    # Files vanished on the source mid-transfer. Normal on a live server.
    warn "rsync: some source files vanished during transfer ($what); continuing."
    RSYNC_WARNINGS=$((RSYNC_WARNINGS + 1))
    return 0
  fi
  if [[ $rc -eq 25 ]]; then
    err "rsync hit the deletion limit (MAX_DELETE=${MAX_DELETE}) for $what."
    err "  If the source really lost that many files, check it first. If the"
    err "  deletions are intended, rerun with MAX_DELETE=unlimited (or a higher number)."
  fi
  return "$rc"
}

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
  if [[ $DRY_RUN -eq 0 ]]; then mkdir -p "$dest"; fi

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
  _rsync_rc "$rc" "$tag"
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
  _rsync_rc "$rc" "$tag"
}

# Parse "Total transferred file size: N bytes" out of an rsync --stats log.
# Without --human-readable, N is an integer with a locale-dependent thousands
# separator ("1,234,567" or "1.234.567"). A unit suffix (K/M/G/T/P, powers of
# 1000 in rsync 3.x) is still handled in case -h ever comes back.
parse_bytes_transferred() {
  local f="$1"
  awk '/^Total transferred file size:/ {
    val=$5;
    mul=1;
    if (val ~ /[KMGTP]$/) {
      ch=substr(val, length(val), 1);
      val=substr(val, 1, length(val)-1);
      sub(",", ".", val);
      if      (ch=="K") mul=1e3;
      else if (ch=="M") mul=1e6;
      else if (ch=="G") mul=1e9;
      else if (ch=="T") mul=1e12;
      else if (ch=="P") mul=1e15;
    } else {
      gsub(/[,.]/, "", val);
    }
    printf("%.0f", val*mul);
    exit;
  }' "$f"
}

# Tally itemize-changes lines into the SSH-leg or mirror counters.
# tally_itemize LOGFILE ssh|mirror
tally_itemize() {
  local f="$1" leg="$2" n u d
  n=$(grep -c '^>f+++++++++' "$f" 2>/dev/null || true); n=${n:-0}
  # Updated = received-file lines whose change flags aren't all-+ (i.e. some
  # property differed: content, size, mtime, perms, etc.).
  u=$(grep -cE '^>f[^+]' "$f" 2>/dev/null || true); u=${u:-0}
  d=$(grep -c '^\*deleting' "$f" 2>/dev/null || true); d=${d:-0}
  if [[ "$leg" == "mirror" ]]; then
    MIRROR_NEW=$((MIRROR_NEW + n))
    MIRROR_UPDATED=$((MIRROR_UPDATED + u))
    MIRROR_DELETED=$((MIRROR_DELETED + d))
  else
    FILES_NEW=$((FILES_NEW + n))
    FILES_UPDATED=$((FILES_UPDATED + u))
    FILES_DELETED=$((FILES_DELETED + d))
  fi
  return 0
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

# SHA-256 every NUL-separated path in LIST into OUT ("hash  path" lines).
# _hash_list remote|local LIST OUT
# Remote hashing runs `sudo sha256sum` (Docker files are root-owned); xargs
# itself stays unprivileged. A file that can't be hashed just has no line in
# OUT: xargs then exits 123 (GNU) or 1 (BSD), which is expected and returns 0.
# Any other status means the batch as a whole failed and is returned.
_hash_list() {
  local mode="$1" list="$2" out="$3" rc=0
  if [[ "$mode" == "remote" ]]; then
    remote_ssh "xargs -0 sudo -n /usr/bin/sha256sum --" < "$list" > "$out" 2>>"$LOG_FILE" || rc=$?
  else
    xargs -0 shasum -a 256 -- < "$list" > "$out" 2>>"$LOG_FILE" || rc=$?
  fi
  case "$rc" in
    0|1|123) return 0 ;;
    *)       return "$rc" ;;
  esac
}

# Classify each expected relpath against the two sum files. Paths are keyed
# relative to their base, so ordering and missing lines don't matter.
# Output, one per expected path, tab-separated:
#   OK rel | MISMATCH rel srchash dsthash | NODST rel | NOSRC rel | NONE rel
_compare_sums() {
  local expected="$1" src_sums="$2" src_base="$3" dst_sums="$4" dst_base="$5"
  # Bases go in through the environment: awk -v would mangle backslashes.
  V_SRC_BASE="$src_base" V_DST_BASE="$dst_base" awk '
    function parse(line, base,   sp, k) {
      sp = index(line, " ")
      if (sp == 0) return 0
      H = substr(line, 1, sp - 1)
      sub(/^\\/, "", H)                  # GNU escapes odd names with a leading \
      k = substr(line, sp + 2)           # skip "  " or " *"
      if (index(k, base) == 1) k = substr(k, length(base) + 1)
      K = k
      return 1
    }
    FILENAME == ARGV[1] { if ($0 != "") want[++n] = $0; next }
    FILENAME == ARGV[2] { if (parse($0, ENVIRON["V_SRC_BASE"])) src[K] = H; next }
    FILENAME == ARGV[3] { if (parse($0, ENVIRON["V_DST_BASE"])) dst[K] = H; next }
    END {
      for (i = 1; i <= n; i++) {
        k = want[i]
        if ((k in src) && (k in dst)) {
          if (src[k] == dst[k]) print "OK\t" k
          else print "MISMATCH\t" k "\t" src[k] "\t" dst[k]
        } else if (k in src) print "NODST\t" k
        else if (k in dst)   print "NOSRC\t" k
        else                 print "NONE\t" k
      }
    }
  ' "$expected" "$src_sums" "$dst_sums"
}

# Verify the files one rsync call transferred.
# verify_leg LABEL remote|local SRC_BASE DST_BASE RSYNC_LOG
#   remote: SRC_BASE is on the Ubuntu host (SSH leg)
#   local:  SRC_BASE is a local drive (A->B mirror)
# Results: a mismatch or a destination file that can't be read counts as a
# failure. A file whose source can't be hashed (usually it was deleted on the
# server after rsync copied it) counts as unverified. Always returns 0; the
# counters decide the exit code.
verify_leg() {
  local label="$1" mode="$2" src_base="$3" dst_base="$4" rsync_log="$5"
  local rel_nul="${RUN_DIR}/.relpaths.nul"
  local rel_txt="${RUN_DIR}/.relpaths.txt"
  local src_nul="${RUN_DIR}/.src-paths.nul"
  local dst_nul="${RUN_DIR}/.dst-paths.nul"
  local src_sums="${RUN_DIR}/.src-sums.txt"
  local dst_sums="${RUN_DIR}/.dst-sums.txt"
  local results="${RUN_DIR}/.verify-results.txt"
  local fail_log="${RUN_DIR}/verification-failures.txt"
  local unver_log="${RUN_DIR}/unverified.txt"

  extract_transferred_relpaths "$rsync_log" > "$rel_nul"
  if [[ ! -s "$rel_nul" ]]; then
    log "Verify (${label}): no new/changed files."
    rm -f -- "$rel_nul"
    return 0
  fi

  : > "$src_nul"; : > "$dst_nul"
  local count=0 rel
  while IFS= read -r -d '' rel; do
    printf '%s\0' "${src_base}${rel}" >> "$src_nul"
    printf '%s\0' "${dst_base}${rel}" >> "$dst_nul"
    count=$((count + 1))
  done < "$rel_nul"
  # awk can't portably read NUL-separated input; a filename containing a
  # newline will show up as unverified (NONE), never as a false pass.
  tr '\0' '\n' < "$rel_nul" > "$rel_txt"
  log "Verify (${label}): hashing ${count} file(s)..."

  local rc=0
  _hash_list "$mode" "$src_nul" "$src_sums" || rc=$?
  if [[ $rc -ne 0 ]]; then
    warn "Verify (${label}): source hashing failed (exit $rc); affected files count as unverified."
  fi
  rc=0
  _hash_list local "$dst_nul" "$dst_sums" || rc=$?
  if [[ $rc -ne 0 ]]; then
    warn "Verify (${label}): destination hashing failed (exit $rc); affected files count as unverified."
  fi

  _compare_sums "$rel_txt" "$src_sums" "$src_base" "$dst_sums" "$dst_base" > "$results"

  local status a b ts unver=0
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  while IFS=$'\t' read -r status rel a b; do
    case "$status" in
      OK)
        VERIFY_CHECKED=$((VERIFY_CHECKED + 1))
        VERIFY_PASSED=$((VERIFY_PASSED + 1))
        # Per-file OKs go to the file log only — keeps the console readable.
        printf '%s [VERIFY-OK] %s\n' "$ts" "$rel" >> "$LOG_FILE"
        ;;
      MISMATCH)
        VERIFY_CHECKED=$((VERIFY_CHECKED + 1))
        VERIFY_FAILED=$((VERIFY_FAILED + 1))
        err "VERIFY MISMATCH (${label}): $rel  src=$a dst=$b"
        printf '%s\n' "${dst_base}${rel}" >> "$fail_log"
        ;;
      NODST)
        VERIFY_CHECKED=$((VERIFY_CHECKED + 1))
        VERIFY_FAILED=$((VERIFY_FAILED + 1))
        err "VERIFY FAILED (${label}): $rel  copied file missing or unreadable on destination"
        printf '%s\n' "${dst_base}${rel}" >> "$fail_log"
        ;;
      NOSRC|NONE)
        unver=$((unver + 1))
        printf '%s [VERIFY-SKIP] %s (%s)\n' "$ts" "$rel" "$status" >> "$LOG_FILE"
        printf '%s\n' "${dst_base}${rel}" >> "$unver_log"
        ;;
    esac
  done < "$results"
  if [[ $unver -gt 0 ]]; then
    VERIFY_UNVERIFIED=$((VERIFY_UNVERIFIED + unver))
    warn "Verify (${label}): ${unver} file(s) could not be hashed (vanished on source, or hashing failed); listed in ${unver_log}"
  fi

  rm -f -- "$rel_nul" "$rel_txt" "$src_nul" "$dst_nul" \
        "$src_sums" "$dst_sums" "$results"
  return 0
}

# ============================================================================
# Stages
# ============================================================================

# Copy the newest dump to one drive and prune older dumps on that drive.
fetch_latest_dump() {
  local drive="$1" tag="$2"
  local latest="$DUMP_PATH" dump_name dest_dir

  # check_dump (pre-flight) already guaranteed a recent enough dump exists.
  dump_name="$(basename "$latest")"
  dest_dir="${drive}/${BACKUP_SUBDIR}/${DUMP_DEST_SUBPATH}"
  if [[ $DRY_RUN -eq 0 ]]; then mkdir -p "$dest_dir"; fi

  # Single-file copy: no --delete (we'd risk wiping unrelated files), and we
  # do retention via prune_old_dumps below.
  if ! rsync_ssh_leg "$latest" "${dest_dir}/" "dump-${tag}" "no-delete"; then
    err "rsync of dump failed: $latest"
    return 1
  fi

  local bytes; bytes="$(parse_bytes_transferred "$RSYNC_LAST_LOG")"
  SSH_BYTES=$((SSH_BYTES + ${bytes:-0}))
  tally_itemize "$RSYNC_LAST_LOG" ssh

  if [[ $DRY_RUN -eq 1 ]]; then
    return 0
  fi

  # Verify only when this is the SSH-leg drive (per spec).
  if [[ "$drive" == "$SSH_LEG_DRIVE" ]]; then
    verify_leg "SSH leg" remote "${DUMP_REMOTE_DIR}/" "${dest_dir}/" "$RSYNC_LAST_LOG"
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
    tally_itemize "$RSYNC_LAST_LOG" ssh

    if [[ $DRY_RUN -eq 0 && "$drive" == "$SSH_LEG_DRIVE" ]]; then
      verify_leg "SSH leg" remote "$remote_path" "$dest" "$RSYNC_LAST_LOG"
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
  tally_itemize "$RSYNC_LAST_LOG" mirror

  if [[ "$VERIFY_LOCAL_MIRROR" == "1" ]]; then
    log "VERIFY_LOCAL_MIRROR=1 — verifying transferred files for the local mirror leg."
    verify_leg "local mirror" local "$src" "$dst" "$RSYNC_LAST_LOG"
  fi
}

# ============================================================================
# Main
# ============================================================================

# drive_has_room LABEL DRIVE SRC_BYTES — logs the numbers, warns and returns 1
# if the drive can't take the rest of the backup.
drive_has_room() {
  local label="$1" drive="$2" src="$3" have free needed
  log "Measuring existing backup on ${label}..."
  have="$(local_backup_bytes "$drive")"
  free="$(drive_free_bytes "$drive")"
  needed="$(drive_needed_bytes "$src" "$have")"
  log "${label}: backup $(human_bytes "$have"), free $(human_bytes "$free"), needs $(human_bytes "$needed") (incl. ${HEADROOM_PCT}% headroom)"
  if [[ $free -lt $needed ]]; then
    warn "${label} has insufficient free space; skipping it."
    return 1
  fi
  return 0
}

preflight() {
  setup_logging
  prune_old_logs
  log "==== immich-backup.sh starting at $(date) ===="
  if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY RUN: nothing will be written to the drives."
  fi
  log "Config file: ${CONFIG_FILE:-none (script defaults)}"
  log "Run log: $LOG_FILE"
  log "Run dir: $RUN_DIR"
  keep_awake

  init_ssh_opts
  detect_rsync
  check_local_tools
  check_ssh
  check_remote_sources
  check_dump

  # Drive availability.
  if drive_ready A "$DRIVE_A"; then DRIVE_A_OK=1; fi
  if drive_ready B "$DRIVE_B"; then DRIVE_B_OK=1; fi
  if [[ $DRIVE_A_OK -eq 0 && $DRIVE_B_OK -eq 0 ]]; then
    die "Neither $DRIVE_A nor $DRIVE_B is mounted. Aborting."
  fi

  # Source size + headroom. Each drive only needs room for what it doesn't
  # already hold (plus headroom), not for the whole library again.
  log "Computing remote source size (sudo du -sb)..."
  local src_bytes
  if ! src_bytes="$(remote_source_bytes)" || [[ ! "$src_bytes" =~ ^[0-9]+$ ]]; then
    die "Couldn't size the remote sources with 'sudo du' (see $LOG_FILE). Aborting."
  fi
  log "Remote source size:                $(human_bytes "$src_bytes")"

  if [[ $DRIVE_A_OK -eq 1 ]] && ! drive_has_room "Drive A" "$DRIVE_A" "$src_bytes"; then
    DRIVE_A_OK=0
  fi
  if [[ $DRIVE_B_OK -eq 1 ]] && ! drive_has_room "Drive B" "$DRIVE_B" "$src_bytes"; then
    DRIVE_B_OK=0
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
  log "  Dump:             ${DUMP_PATH}"
  log "  Max deletions:    ${MAX_DELETE} per rsync call"
  hr
}

main() {
  parse_args "$@"
  load_config
  finalize_config

  trap 'on_err $LINENO' ERR
  trap cleanup_eject EXIT

  acquire_lock
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
  if [[ $DRY_RUN -eq 1 ]]; then
    # Drive A wasn't actually updated, so a dry A->B comparison would show
    # stale differences. Skip it.
    log "Dry run: skipping the A -> B mirror."
  elif [[ "$SSH_LEG_DRIVE" == "$DRIVE_A" && $DRIVE_B_OK -eq 1 ]]; then
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

# Run only when executed, not when sourced (the tests source this file).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
