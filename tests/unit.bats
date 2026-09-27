#!/usr/bin/env bats
#
# Unit tests for immich-backup.sh functions. No network, no root, no drives.
# Runs on Linux and on macOS (CI runs it under macOS /bin/bash 3.2 with the
# BSD awk/xargs/touch, which is the main point: see .github/workflows/ci.yml).
#
#   bats tests/unit.bats
#
# shellcheck disable=SC2034  # vars set here are read by the sourced functions
# shellcheck disable=SC1091,SC2012

bats_require_minimum_version 1.5.0

setup() {
  # Sourcing runs the top-level code (defaults, strict mode, IFS=$'\n\t') but
  # not main(): the script only calls main when executed directly.
  # shellcheck source=../immich-backup.sh
  source "${BATS_TEST_DIRNAME}/../immich-backup.sh"
  set +u   # bats internals aren't written for nounset
  T="$BATS_TEST_TMPDIR"
  LOG_FILE="${T}/run.log"; : > "$LOG_FILE"
  RUN_DIR="${T}/run"; mkdir -p "$RUN_DIR"
}

# --- parse_bytes_transferred ------------------------------------------------

@test "parse_bytes: comma thousands separator" {
  printf 'Total transferred file size: 6,000,005 bytes\n' > "$T/l"
  [ "$(parse_bytes_transferred "$T/l")" = "6000005" ]
}

@test "parse_bytes: period thousands separator (some locales)" {
  printf 'Total transferred file size: 6.000.005 bytes\n' > "$T/l"
  [ "$(parse_bytes_transferred "$T/l")" = "6000005" ]
}

@test "parse_bytes: unit suffix is base 1000, decimal comma accepted" {
  printf 'Total transferred file size: 1.50G bytes\n' > "$T/l"
  [ "$(parse_bytes_transferred "$T/l")" = "1500000000" ]
  printf 'Total transferred file size: 1,50G bytes\n' > "$T/l"
  [ "$(parse_bytes_transferred "$T/l")" = "1500000000" ]
}

@test "parse_bytes: no stats line gives empty output" {
  printf 'nothing here\n' > "$T/l"
  [ -z "$(parse_bytes_transferred "$T/l")" ]
}

# --- itemize parsing ----------------------------------------------------------

itemize_fixture() {
  cat > "$T/rsync.log" <<'EOF'
receiving incremental file list
cd+++++++++ 2024/
>f+++++++++ 2024/new file.jpg
>f+++++++++ 2024/é名.jpg
>fc.t...... 2024/changed-content.jpg
>f.s....... 2024/changed-size.jpg
>f..t...... 2024/changed-mtime.jpg
>f.....p... 2024/perms-only.jpg
.d..t...... 2024/
*deleting   2024/gone.jpg
cL+++++++++ link -> target
      1,234,567 100%  1.00MB/s    0:00:01 (xfr#5, to-chk=0/9)

Total transferred file size: 1,234,567 bytes
EOF
}

@test "extract_transferred_relpaths: new + c/s/t changes only, names intact" {
  itemize_fixture
  run bash -c 'source "$1"; extract_transferred_relpaths "$2" | tr "\0" "\n"' _ \
    "${BATS_TEST_DIRNAME}/../immich-backup.sh" "$T/rsync.log"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "2024/new file.jpg" ]
  [ "${lines[1]}" = "2024/é名.jpg" ]
  [ "${lines[2]}" = "2024/changed-content.jpg" ]
  [ "${lines[3]}" = "2024/changed-size.jpg" ]
  [ "${lines[4]}" = "2024/changed-mtime.jpg" ]
  [ "${#lines[@]}" -eq 5 ]    # perms-only, dirs, symlinks, deletions excluded
}

@test "tally_itemize: counts go to the right leg" {
  itemize_fixture
  tally_itemize "$T/rsync.log" ssh
  [ "$FILES_NEW" -eq 2 ]; [ "$FILES_UPDATED" -eq 4 ]; [ "$FILES_DELETED" -eq 1 ]
  [ "$MIRROR_NEW" -eq 0 ]
  tally_itemize "$T/rsync.log" mirror
  [ "$MIRROR_NEW" -eq 2 ]; [ "$MIRROR_UPDATED" -eq 4 ]; [ "$MIRROR_DELETED" -eq 1 ]
  [ "$FILES_NEW" -eq 2 ]
}

# --- small helpers ------------------------------------------------------------

@test "drive_needed_bytes: only what's missing, plus headroom, never negative" {
  HEADROOM_PCT=10
  [ "$(drive_needed_bytes 1000 0)" = "1100" ]
  [ "$(drive_needed_bytes 1000 400)" = "660" ]
  [ "$(drive_needed_bytes 1000 5000)" = "0" ]
}

@test "human_bytes" {
  [ "$(human_bytes 0)" = "0.00 B" ]
  [ "$(human_bytes 1536)" = "1.50 KB" ]
}

@test "_rsync_rc: 24 is a warning, 25 and others fail" {
  run _rsync_rc 0 x;  [ "$status" -eq 0 ]
  _rsync_rc 24 x;     [ "$RSYNC_WARNINGS" -eq 1 ]
  run _rsync_rc 25 x; [ "$status" -eq 25 ]; [[ "$output" == *"deletion limit"* ]]
  run _rsync_rc 23 x; [ "$status" -eq 23 ]
}

@test "mount_point_of: / is its own mount point, a temp dir usually isn't" {
  [ "$(mount_point_of /)" = "/" ]
  mkdir -p "$T/sub"
  [ "$(mount_point_of "$T/sub")" != "$T/sub" ]
}

# --- verification -------------------------------------------------------------

@test "_compare_sums: classifies every expected file, order-independent" {
  printf '%s\n' "a.jpg" "b.jpg" "c.jpg" "d.jpg" "e.jpg" > "$T/exp"
  cat > "$T/src" <<'EOF'
2222  /srv/x y/b.jpg
1111  /srv/x y/a.jpg
3333  /srv/x y/c.jpg
\5555  /srv/x y/e.jpg
EOF
  cat > "$T/dst" <<'EOF'
1111  /Volumes/A/a.jpg
9999  /Volumes/A/b.jpg
4444  /Volumes/A/d.jpg
5555 */Volumes/A/e.jpg
EOF
  run _compare_sums "$T/exp" "$T/src" "/srv/x y/" "$T/dst" "/Volumes/A/"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'OK\ta.jpg')" ]
  [ "${lines[1]}" = "$(printf 'MISMATCH\tb.jpg\t2222\t9999')" ]
  [ "${lines[2]}" = "$(printf 'NODST\tc.jpg')" ]
  [ "${lines[3]}" = "$(printf 'NOSRC\td.jpg')" ]
  [ "${lines[4]}" = "$(printf 'OK\te.jpg')" ]   # GNU "\" prefix and "*" binary marker handled
}

@test "_compare_sums: a file on neither side is NONE" {
  printf 'ghost.jpg\n' > "$T/exp"; : > "$T/src"; : > "$T/dst"
  run _compare_sums "$T/exp" "$T/src" "/s/" "$T/dst" "/d/"
  [ "$output" = "$(printf 'NONE\tghost.jpg')" ]
}

@test "_hash_list local: a missing file is skipped, not fatal (BSD and GNU xargs)" {
  echo hello > "$T/ok.txt"
  printf '%s\0' "$T/ok.txt" "$T/missing.txt" > "$T/list"
  run _hash_list local "$T/list" "$T/sums"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$T/sums" | tr -d ' ')" = "1" ]
  grep -q "ok.txt" "$T/sums"
}

verify_fixture() {
  mkdir -p "$T/src/d" "$T/dst/d"
  echo one > "$T/src/d/one.jpg";   cp "$T/src/d/one.jpg" "$T/dst/d/"
  echo two > "$T/src/d/two é.jpg"; cp "$T/src/d/two é.jpg" "$T/dst/d/"
  printf '>f+++++++++ d/one.jpg\n>f+++++++++ d/two é.jpg\n' > "$T/rsync.log"
}

@test "verify_leg local: all good" {
  verify_fixture
  verify_leg "test" local "$T/src/" "$T/dst/" "$T/rsync.log"
  [ "$VERIFY_CHECKED" -eq 2 ]; [ "$VERIFY_PASSED" -eq 2 ]
  [ "$VERIFY_FAILED" -eq 0 ];  [ "$VERIFY_UNVERIFIED" -eq 0 ]
  [ ! -e "$RUN_DIR/.src-sums.txt" ]   # temp files cleaned up
}

@test "verify_leg local: corrupted copy fails and is listed" {
  verify_fixture
  echo tampered > "$T/dst/d/one.jpg"
  verify_leg "test" local "$T/src/" "$T/dst/" "$T/rsync.log"
  [ "$VERIFY_FAILED" -eq 1 ]; [ "$VERIFY_PASSED" -eq 1 ]
  grep -q "one.jpg" "$RUN_DIR/verification-failures.txt"
}

@test "verify_leg local: vanished source is unverified, not failed" {
  verify_fixture
  rm "$T/src/d/two é.jpg"
  verify_leg "test" local "$T/src/" "$T/dst/" "$T/rsync.log"
  [ "$VERIFY_UNVERIFIED" -eq 1 ]; [ "$VERIFY_FAILED" -eq 0 ]; [ "$VERIFY_PASSED" -eq 1 ]
  grep -q "two é.jpg" "$RUN_DIR/unverified.txt"
}

@test "verify_leg: nothing transferred is a no-op" {
  printf '.d..t...... d/\n' > "$T/rsync.log"
  verify_leg "test" local "$T/src/" "$T/dst/" "$T/rsync.log"
  [ "$VERIFY_CHECKED" -eq 0 ]
}

# --- logs -------------------------------------------------------------------

@test "prune_old_logs: keeps LOG_RETENTION logs AND run dirs, and latest.log" {
  LOG_DIR="$T/logs"; LOG_RETENTION=30; mkdir -p "$LOG_DIR"
  local i name
  for i in $(seq 10 49); do
    name="2026-01-${i}_000000"
    mkdir "$LOG_DIR/$name"; : > "$LOG_DIR/$name.log"
    # POSIX touch -t (BSD has no -d): one minute apart, 00:10 .. 00:49.
    touch -t "2026010100${i}" "$LOG_DIR/$name" "$LOG_DIR/$name.log"
  done
  ln -s "$LOG_DIR/2026-01-49_000000.log" "$LOG_DIR/latest.log"
  prune_old_logs
  [ "$(ls "$LOG_DIR"/2026-*.log | wc -l | tr -d ' ')" = "30" ]
  [ "$(find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = "30" ]
  [ -L "$LOG_DIR/latest.log" ]
}

# --- arguments and config -------------------------------------------------------

@test "parse_args: flags" {
  parse_args --dry-run --config /tmp/x
  [ "$DRY_RUN" -eq 1 ]; [ "$CONFIG_FILE" = "/tmp/x" ]
  CONFIG_FILE=""; parse_args --config=/tmp/y -n
  [ "$CONFIG_FILE" = "/tmp/y" ]
}

@test "parse_args: unknown flag exits 64, --help exits 0" {
  run parse_args --nope;  [ "$status" -eq 64 ]
  run parse_args --help;  [ "$status" -eq 0 ]; [[ "$output" == *"Usage:"* ]]
  run parse_args --config; [ "$status" -eq 64 ]
}

# has_flag FLAG — is FLAG an element of RSYNC_BASE_FLAGS?
has_flag() {
  local f
  for f in "${RSYNC_BASE_FLAGS[@]}"; do [ "$f" = "$1" ] && return 0; done
  return 1
}

write_conf() { printf '%s\n' "$@" > "$T/conf"; chmod 600 "$T/conf"; CONFIG_FILE="$T/conf"; }

@test "config: derived paths follow REMOTE_USER from the config file" {
  write_conf 'REMOTE_USER="alice"' 'REMOTE_HOST="nas"'
  load_config; finalize_config
  [ "$REMOTE_HOME" = "/home/alice" ]
  [ "$DUMP_REMOTE_DIR" = "/home/alice/immich-app/library/backups" ]
  [ "${#SOURCES[@]}" -eq 4 ]
  [ "${SOURCES[3]}" = "/home/alice/photos/:external-library/photos/" ]
  has_flag --max-delete=1000
}

@test "config: env override beats config file" {
  write_conf 'REMOTE_HOST="nas"' 'MAX_DELETE=5'
  ENV_MAX_DELETE="unlimited"
  load_config; finalize_config
  [ "$MAX_DELETE" = "unlimited" ]
  run ! has_flag --max-delete=5
  run ! has_flag --max-delete=unlimited
}

@test "config: dry run adds --dry-run to rsync flags" {
  write_conf 'REMOTE_HOST="nas"'
  DRY_RUN=1; load_config; finalize_config
  has_flag --dry-run
}

@test "config: validation errors" {
  write_conf 'REMOTE_HOST="nas"' 'MAX_DELETE=lots'
  run bash -c 'source "$1"; CONFIG_FILE="$2"; load_config; finalize_config' _ \
    "${BATS_TEST_DIRNAME}/../immich-backup.sh" "$T/conf"
  [ "$status" -eq 1 ]; [[ "$output" == *"MAX_DELETE must be"* ]]

  write_conf 'REMOTE_HOST="nas"' 'SOURCES=("/srv/photos:photos/")'
  run bash -c 'source "$1"; CONFIG_FILE="$2"; load_config; finalize_config' _ \
    "${BATS_TEST_DIRNAME}/../immich-backup.sh" "$T/conf"
  [ "$status" -eq 1 ]; [[ "$output" == *"Bad SOURCES entry"* ]]

  write_conf 'REMOTE_HOST="nas"' 'SSH_EXTRA_OPTS=("-o Port=22")'
  run bash -c 'source "$1"; CONFIG_FILE="$2"; load_config; finalize_config' _ \
    "${BATS_TEST_DIRNAME}/../immich-backup.sh" "$T/conf"
  [ "$status" -eq 1 ]; [[ "$output" == *"contains whitespace"* ]]

  write_conf 'REMOTE_USER="bob"'
  run bash -c 'source "$1"; CONFIG_FILE="$2"; load_config; finalize_config' _ \
    "${BATS_TEST_DIRNAME}/../immich-backup.sh" "$T/conf"
  [ "$status" -eq 1 ]; [[ "$output" == *"placeholder"* ]]
}

@test "config: writable-by-others config file is refused" {
  write_conf 'REMOTE_HOST="nas"'
  chmod 666 "$T/conf"
  run load_config
  [ "$status" -eq 1 ]; [[ "$output" == *"writable by group/others"* ]]
}

@test "config: default location is optional, explicit one isn't" {
  XDG_CONFIG_HOME="$T/xdg"; IMMICH_BACKUP_CONFIG=""; CONFIG_FILE=""
  load_config
  [ -z "$CONFIG_FILE" ]
  CONFIG_FILE="$T/missing"
  run load_config
  [ "$status" -eq 1 ]; [[ "$output" == *"not found"* ]]
}

# --- lock -------------------------------------------------------------------

@test "lock: acquire, release" {
  LOG_DIR="$T/logs"; LOCK_DIR="$LOG_DIR/.lock"
  acquire_lock
  [ "$(cat "$LOCK_DIR/pid")" = "$$" ]
  release_lock
  [ ! -e "$LOCK_DIR" ]
}

@test "lock: live holder blocks, stale holder is replaced" {
  LOG_DIR="$T/logs"; LOCK_DIR="$LOG_DIR/.lock"; mkdir -p "$LOCK_DIR"
  sleep 60 & local holder=$!
  echo "$holder" > "$LOCK_DIR/pid"
  run acquire_lock
  [ "$status" -eq 1 ]; [[ "$output" == *"in progress"* ]]
  kill "$holder"; wait "$holder" 2>/dev/null || true
  acquire_lock
  [ "$(cat "$LOCK_DIR/pid")" = "$$" ]
}

# --- drives -------------------------------------------------------------------

@test "drive_ready: tags an untagged drive, accepts its own tag" {
  REQUIRE_DRIVE_MOUNT=0; DRY_RUN=0; mkdir -p "$T/A"
  drive_ready A "$T/A"
  [ "$(cat "$T/A/.immich-backup-drive")" = "A" ]
  drive_ready A "$T/A"
}

@test "drive_ready: dry run doesn't tag" {
  REQUIRE_DRIVE_MOUNT=0; DRY_RUN=1; mkdir -p "$T/A"
  drive_ready A "$T/A"
  [ ! -e "$T/A/.immich-backup-drive" ]
}

@test "drive_ready: swapped tag dies" {
  REQUIRE_DRIVE_MOUNT=0; mkdir -p "$T/A"; echo B > "$T/A/.immich-backup-drive"
  run drive_ready A "$T/A"
  [ "$status" -eq 1 ]; [[ "$output" == *"tagged as drive 'B'"* ]]
}

@test "drive_ready: missing or not-a-mount is skipped (return 1), not fatal" {
  REQUIRE_DRIVE_MOUNT=1; mkdir -p "$T/A"
  run drive_ready A "$T/A"
  [ "$status" -eq 1 ]; [[ "$output" == *"isn't a mounted volume"* ]]
  run drive_ready A "$T/nope"
  [ "$status" -eq 1 ]; [[ "$output" == *"missing"* ]]
}
