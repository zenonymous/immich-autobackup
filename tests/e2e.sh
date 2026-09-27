#!/usr/bin/env bash
#
# End-to-end tests for immich-backup.sh on Linux.
#
# Builds a throwaway "Immich server" reachable over SSH on 127.0.0.1:2223
# (its own sshd, a dedicated user, a root-owned fake library), two tmpfs
# "drives", and a stub diskutil, then runs the real script through a list
# of scenarios and checks exit codes, output and the drives' contents.
#
# Needs: root (useradd, sudoers, mount, sshd), rsync, openssh-server, sudo,
# shasum (perl). Run: sudo tests/e2e.sh   (CI does exactly this.)
# Leaves the system as it found it (user, sudoers file, mounts, sshd removed).
#
# What it can't cover: macOS Bash 3.2, BSD tools, real diskutil. The macOS
# CI job runs the unit tests for that.

set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${IMMICH_BACKUP_SCRIPT:-${REPO}/immich-backup.sh}"   # override to test a modified copy
E2E_USER="immich-e2e"
PORT=2223
W="$(mktemp -d /tmp/immich-e2e.XXXXXX)"
R="/home/${E2E_USER}"
A="${W}/Volumes/BackupA"
B="${W}/Volumes/BackupB"
OUT="${W}/out.txt"
PASS=0
FAIL=0
FAILED_NAMES=()

if [[ $EUID -ne 0 ]]; then
  echo "run as root (sudo $0)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

teardown() {
  set +e
  [[ -f "${W}/sshd.pid" ]] && kill "$(cat "${W}/sshd.pid")" 2>/dev/null
  umount "$A" 2>/dev/null
  umount "$B" 2>/dev/null
  rm -f "/etc/sudoers.d/${E2E_USER}"
  if id "$E2E_USER" >/dev/null 2>&1; then userdel -r "$E2E_USER" >/dev/null 2>&1; fi
  rm -rf "$W"
}
trap teardown EXIT

setup() {
  id "$E2E_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$E2E_USER"
  # "*" = no password but not locked; sshd refuses keys for locked accounts
  # when PAM is off (our minimal sshd_config).
  usermod -p '*' "$E2E_USER"
  set_sudoers "/usr/bin/rsync, /usr/bin/du, /usr/bin/sha256sum"

  mkdir -p /run/sshd "${W}/bin"
  ssh-keygen -A >/dev/null
  ssh-keygen -t ed25519 -N '' -q -f "${W}/id"
  install -d -o "$E2E_USER" -m 700 "${R}/.ssh"
  install -o "$E2E_USER" -m 600 "${W}/id.pub" "${R}/.ssh/authorized_keys"
  cat > "${W}/sshd_config" <<EOF
Port ${PORT}
ListenAddress 127.0.0.1
HostKey /etc/ssh/ssh_host_ed25519_key
PidFile ${W}/sshd.pid
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers ${E2E_USER}
EOF
  /usr/sbin/sshd -f "${W}/sshd_config"

  # Stub diskutil: record the call, don't unmount (tests reuse the drives).
  cat > "${W}/bin/diskutil" <<EOF
#!/bin/sh
echo "\$*" >> "${W}/diskutil.calls"
EOF
  chmod +x "${W}/bin/diskutil"

  mkdir -p "$A" "$B"
  mount -t tmpfs -o size=64m tmpfs "$A"
  mount -t tmpfs -o size=64m tmpfs "$B"

  write_config ""
  # Wait for sshd.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ssh -i "${W}/id" -p "$PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
         -o UserKnownHostsFile="${W}/known_hosts" -o LogLevel=ERROR \
         "${E2E_USER}@127.0.0.1" true 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  echo "sshd didn't come up" >&2
  exit 1
}

set_sudoers() {
  echo "${E2E_USER} ALL=(ALL) NOPASSWD: $1" > "/etc/sudoers.d/${E2E_USER}"
  chmod 440 "/etc/sudoers.d/${E2E_USER}"
}

# write_config EXTRA_LINES
write_config() {
  cat > "${W}/config" <<EOF
REMOTE_USER="${E2E_USER}"
REMOTE_HOST="127.0.0.1"
SSH_KEY="${W}/id"
SSH_EXTRA_OPTS=(-p ${PORT} -o UserKnownHostsFile=${W}/known_hosts -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o IdentitiesOnly=yes)
DRIVE_A="${A}"
DRIVE_B="${B}"
LOG_DIR="${W}/logs"
$1
EOF
  chmod 600 "${W}/config"
}

# Fake Immich library, root-owned like Docker leaves it.
reset_remote() {
  rm -rf "${R}/immich-app" "${R}/photos"
  local lib="${R}/immich-app/library" d i
  mkdir -p "${lib}/backups" "${lib}/thumbs" "${R}/photos/2024"
  for d in upload library profile; do
    mkdir -p "${lib}/${d}/u1"
    for i in 1 2 3; do head -c 50000 /dev/urandom > "${lib}/${d}/u1/IMG_${i}.jpg"; done
  done
  echo hi > "${R}/photos/2024/é名 photo.jpg"
  for i in 1 2 3 4 5; do head -c 20000 /dev/urandom > "${R}/photos/2024/p${i}.jpg"; done
  echo old | gzip > "${lib}/backups/immich-db-backup-old.sql.gz"
  touch -d '3 days ago' "${lib}/backups/immich-db-backup-old.sql.gz"
  echo new | gzip > "${lib}/backups/immich-db-backup-new.sql.gz"
  chown -R root:root "${R}/immich-app" "${R}/photos"
  chmod 700 "${lib}/upload" "${lib}/library" "${lib}/profile"
}

# Empty both drives and the logs.
reset_drives() {
  find "$A" "$B" -mindepth 1 -delete
  rm -rf "${W}/logs" "${W}/diskutil.calls"
}

fresh() {
  reset_remote
  reset_drives
  write_config ""
  set_sudoers "/usr/bin/rsync, /usr/bin/du, /usr/bin/sha256sum"
  rm -f "${W}/bin/shasum"
}

# run [ENV=VAL ...] [-- script args]; sets RC, output in $OUT.
run() {
  local envs=() args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  if [[ $# -gt 0 ]]; then shift; args=("$@"); fi
  RC=0
  env PATH="${W}/bin:${PATH}" ${envs[@]+"${envs[@]}"} \
    bash "$SCRIPT" --config "${W}/config" ${args[@]+"${args[@]}"} > "$OUT" 2>&1 || RC=$?
}

# ---------------------------------------------------------------------------
# Assertions (record, don't abort)
# ---------------------------------------------------------------------------

CURRENT=""
CUR_OK=1
begin() { CURRENT="$1"; CUR_OK=1; }
fail()  { CUR_OK=0; echo "    ✗ $*"; }
end() {
  if [[ $CUR_OK -eq 1 ]]; then
    PASS=$((PASS + 1)); echo "ok   $CURRENT"
  else
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$CURRENT"); echo "FAIL $CURRENT"
    echo "    --- script output (last 25 lines) ---"
    tail -n 25 "$OUT" | sed 's/^/    | /'
  fi
}
expect_rc()   { [[ "$RC" == "$1" ]] || fail "exit code $RC, expected $1"; }
expect_out()  { grep -qE -- "$1" "$OUT" || fail "output doesn't match: $1"; }
expect_no_out() { ! grep -qE -- "$1" "$OUT" || fail "output unexpectedly matches: $1"; }
count_files() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }
expect_count() { local n; n="$(count_files "$1")"; [[ "$n" == "$2" ]] || fail "$1 has $n files, expected $2"; }
expect_file() { [[ -f "$1" ]] || fail "missing file $1"; }
expect_no_file() { [[ ! -e "$1" ]] || fail "unexpected file $1"; }

# A shasum wrapper that alters (corrupt:PAT) or drops (omit:PAT) matching lines.
fake_shasum() {
  cat > "${W}/bin/shasum" <<EOF
#!/bin/bash
/usr/bin/shasum "\$@" | while IFS= read -r l; do
  case "\$l" in
    *"$2"*) if [ "$1" = corrupt ]; then echo "deadbeef\${l#????????}"; fi ;;
    *) echo "\$l" ;;
  esac
done
EOF
  chmod +x "${W}/bin/shasum"
}

PH="external-library/photos/2024"   # photos subdir on the drives
TOTAL_FILES=17                       # 9 Immich + 6 photos + 1 dump + 1 marker

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

scenarios() {
  begin "cli: --help exits 0"
  run -- --help; expect_rc 0; expect_out "Usage: immich-backup.sh"; end

  begin "cli: unknown argument exits 64"
  run -- --bogus; expect_rc 64; end

  begin "config: placeholder REMOTE_HOST refused"
  printf 'LOG_DIR="%s/logs"\n' "$W" > "${W}/bare.conf"; chmod 600 "${W}/bare.conf"
  RC=0; env PATH="${W}/bin:${PATH}" bash "$SCRIPT" --config "${W}/bare.conf" > "$OUT" 2>&1 || RC=$?
  expect_rc 1; expect_out "placeholder"; end

  begin "config: group/world-writable config refused"
  chmod 666 "${W}/config"; run; chmod 600 "${W}/config"
  expect_rc 1; expect_out "writable by group/others"; end

  begin "config: explicit missing config file refused"
  RC=0; env PATH="${W}/bin:${PATH}" bash "$SCRIPT" --config "${W}/nope" > "$OUT" 2>&1 || RC=$?
  expect_rc 1; expect_out "Config file not found"; end

  begin "config: invalid MAX_DELETE refused"
  run MAX_DELETE=lots; expect_rc 1; expect_out "MAX_DELETE must be"; end

  fresh
  begin "dry run on empty drives writes nothing"
  run -- --dry-run
  expect_rc 0; expect_out "DRY RUN COMPLETE"; expect_out "would tag"
  expect_count "$A" 0; expect_count "$B" 0; expect_no_file "${W}/diskutil.calls"; end

  begin "first real run: everything copied, verified, tagged, ejected"
  run
  expect_rc 0; expect_out "BACKUP COMPLETE"
  expect_out "Verification checked: +16$"; expect_out "Verification passed: +16$"
  expect_count "$A" "$TOTAL_FILES"
  end

  begin "first real run: Drive B mirrors Drive A, both tagged and ejected"
  expect_count "$B" "$TOTAL_FILES"
  expect_file "${B}/immich-backup/${PH}/é名 photo.jpg"
  [[ "$(cat "${A}/.immich-backup-drive")" == A ]] || fail "Drive A marker"
  [[ "$(cat "${B}/.immich-backup-drive")" == B ]] || fail "Drive B marker"
  grep -q "eject ${A}" "${W}/diskutil.calls" || fail "A not ejected"
  grep -q "eject ${B}" "${W}/diskutil.calls" || fail "B not ejected"
  expect_no_file "${W}/logs/.lock"
  end

  begin "re-run with no changes: nothing transferred, nothing needed"
  run
  expect_rc 0; expect_out "SSH leg files new/upd/del: +0 / 0 / 0"; expect_out "needs 0\\.00 B"; end

  begin "dry run shows pending changes without applying them"
  rm -f "${R}/photos/2024/p1.jpg"; head -c 1234 /dev/urandom > "${R}/photos/2024/new.jpg"
  run -- -n
  expect_rc 0; expect_out "SSH leg files new/upd/del: +1 / 0 / 1"
  expect_file "${A}/immich-backup/${PH}/p1.jpg"; expect_no_file "${A}/immich-backup/${PH}/new.jpg"
  end

  fresh; run
  begin "empty source aborts in pre-flight, drives untouched"
  rm -rf "${R}/photos/2024"
  run; expect_rc 1; expect_out "is empty"; expect_count "${A}/immich-backup/${PH}" 6; end

  begin "missing source aborts in pre-flight"
  rm -rf "${R}/photos"
  run; expect_rc 1; expect_out "missing or unreadable"; end

  fresh
  begin "REMOTE_MOUNTPOINTS: unmounted path aborts"
  write_config "REMOTE_MOUNTPOINTS=(\"${R}/photos\")"
  run; expect_rc 1; expect_out "is not a mount point"; expect_count "$A" 0; end

  fresh
  begin "stale dump aborts; DUMP_MAX_AGE_HOURS=0 overrides"
  touch -d '2 days ago' "${R}"/immich-app/library/backups/*.sql.gz
  run; expect_rc 1; expect_out "Newest dump is 4[78]h old"
  run DUMP_MAX_AGE_HOURS=0; expect_rc 0; end

  fresh
  begin "config value used, env override wins over it"
  write_config "DUMP_MAX_AGE_HOURS=0"
  touch -d '2 days ago' "${R}"/immich-app/library/backups/*.sql.gz
  run; expect_rc 0
  run DUMP_MAX_AGE_HOURS=5; expect_rc 1; end

  fresh
  begin "no dump aborts"
  rm -f "${R}"/immich-app/library/backups/*
  run; expect_rc 1; expect_out "No \\*\\.sql\\.gz dump found"; end

  fresh; run
  begin "deletion limit stops the run; Drive B untouched"
  rm -f "${R}"/photos/2024/p*.jpg
  run MAX_DELETE=3
  expect_rc 1; expect_out "deletion limit"
  expect_count "${A}/immich-backup/${PH}" 3; expect_count "${B}/immich-backup/${PH}" 6
  run MAX_DELETE=unlimited; expect_rc 0; expect_count "${B}/immich-backup/${PH}" 1
  end

  fresh
  begin "sudoers allowing only rsync is caught in pre-flight"
  set_sudoers "/usr/bin/rsync"
  run; expect_rc 1; expect_out "sudo -n /usr/bin/du' failed"; expect_count "$A" 0; end

  fresh; run
  begin "hash mismatch -> exit 2 and verification-failures.txt"
  head -c 20000 /dev/urandom > "${R}/photos/2024/p2.jpg"
  fake_shasum corrupt p2.jpg
  run; expect_rc 2; expect_out "VERIFY MISMATCH"
  grep -q "p2.jpg" "${W}"/logs/*/verification-failures.txt || fail "not listed"; end

  begin "copied file unreadable on drive -> exit 2"
  head -c 999 /dev/urandom > "${R}/photos/2024/p3.jpg"
  fake_shasum omit p3.jpg
  run; expect_rc 2; expect_out "missing or unreadable on destination"; end

  fresh; run
  begin "unhashable source (mirror leg) -> exit 3 and unverified.txt"
  rm -f "${B}/immich-backup/originals/upload/u1/IMG_2.jpg"
  fake_shasum omit "BackupA/immich-backup/originals/upload/u1/IMG_2.jpg"
  run VERIFY_LOCAL_MIRROR=1; expect_rc 3; expect_out "COULD NOT BE VERIFIED"
  grep -q "IMG_2.jpg" "${W}"/logs/*/unverified.txt || fail "not listed"; end

  fresh
  begin "lock held by a live process -> refuses to run"
  mkdir -p "${W}/logs/.lock"; sleep 300 & local holder=$!
  echo "$holder" > "${W}/logs/.lock/pid"
  run; expect_rc 1; expect_out "in progress \\(pid ${holder}\\)"
  [[ -d "${W}/logs/.lock" ]] || fail "someone else's lock was removed"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  end

  begin "stale lock is cleared and the run proceeds"
  run; expect_rc 0; expect_out "Removing stale lock"; expect_no_file "${W}/logs/.lock"; end

  begin "swapped drives are refused"
  echo B > "${A}/.immich-backup-drive"
  run; expect_rc 1; expect_out "tagged as drive 'B'"; echo A > "${A}/.immich-backup-drive"; end

  begin "drive folder that isn't a mount is skipped"
  umount "$B"
  run; expect_rc 0; expect_out "isn't a mounted volume"; expect_out "Only one drive used"
  mount -t tmpfs -o size=64m tmpfs "$B"; end
}

setup
echo "== immich-backup e2e ($(bash --version | head -n 1)) =="
scenarios
echo "== ${PASS} passed, ${FAIL} failed =="
if [[ $FAIL -gt 0 ]]; then
  printf '   failed: %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
