# Testing

There is no automated test suite and no CI. This page explains what can
be checked, and where.

## What you can and can't test in a Linux container

You **can** run the whole script end-to-end on Linux (see "End-to-end
harness" below): GNU `df`/`du`, Perl `shasum`, rsync 3.x and a local sshd
stand in for the Mac and the server. What you **can't** test there:

- Bash 3.2 (the macOS `/bin/bash`). Its source download was blocked in the
  cloud test environment. If you can get it, build it and run the harness with
  it. Otherwise review against the rules in `AGENTS.md`.
- BSD `xargs`/`du`/`df`/`awk` differences, and a real `diskutil`.
- A real Immich host (Docker-owned files, the real dump filenames).

Say which parts you exercised, and where.

## Static checks

```sh
bash -n immich-backup.sh
shellcheck -s bash immich-backup.sh
```

Current shellcheck baseline (keep it from growing):

| Code | Where | Note |
|---|---|---|
| SC2034 ×4 | `DB_CONTAINER`, `DB_USER`, `DB_NAME`, `C_GRN` | Unused placeholders |
| SC2029 ×1 | `remote_ssh` | Intentional: command string is built locally |

## Testing individual functions against real rsync output

The parsers are pure functions over an rsync log file, so you can test them on
Linux with real rsync 3.x (`apt-get install rsync`).

```sh
S=$(mktemp -d); cd "$S"
mkdir -p src/sub dst
for i in $(seq 1 30); do head -c 200000 /dev/urandom > "src/sub/f$i.bin"; done
echo hi > "src/é名.txt"; echo x > "src/sp ace.txt"

# Same flags as RSYNC_BASE_FLAGS, then the same \r→\n normalisation.
LANG=C.UTF-8 rsync -aH -8 --delete --partial --info=progress2 \
  --itemize-changes --stats src/ dst/ 2>&1 | tr '\r' '\n' > rsync.log

# Pull just the functions you need out of the script and source them.
sed -n '/^parse_bytes_transferred()/,/^}/p
        /^extract_transferred_relpaths()/,/^}/p' \
  /path/to/immich-backup.sh > fns.sh
source fns.sh

parse_bytes_transferred rsync.log; echo
extract_transferred_relpaths rsync.log | tr '\0' '\n'
```

Useful variations:

- Change a file with the same size (`touch -d …`, rewrite bytes) and re-run to
  see `>f..t……` and `>fc…` lines.
- Delete a source file to see `*deleting` lines (`tally_itemize`).
- Use `LANG=C` to see escaped non-ASCII names (KNOWN_ISSUES #5).
- Use `prune_old_logs` with a fake `LOG_DIR` containing N `*.log` files plus N
  run directories (KNOWN_ISSUES #10).

## End-to-end harness (Linux, as root)

This is how phase A+B+C was tested. It's a few minutes to set up.

**1. A local "Immich server" over SSH** (port 2222, user `immich`):

```sh
apt-get install -y rsync openssh-server sudo shellcheck
useradd -m -s /bin/bash immich
echo 'immich ALL=(ALL) NOPASSWD: /usr/bin/rsync, /usr/bin/du, /usr/bin/sha256sum' \
  > /etc/sudoers.d/immich && chmod 440 /etc/sudoers.d/immich
mkdir -p /run/sshd && ssh-keygen -A
printf 'Port 2222\nListenAddress 127.0.0.1\n' >> /etc/ssh/sshd_config && /usr/sbin/sshd
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519 -q
install -d -o immich -m 700 /home/immich/.ssh
install -o immich -m 600 ~/.ssh/id_ed25519.pub /home/immich/.ssh/authorized_keys
printf 'Host immichtest\n HostName 127.0.0.1\n Port 2222\n StrictHostKeyChecking no\n UserKnownHostsFile /dev/null\n LogLevel ERROR\n' >> ~/.ssh/config
```

**2. A fake Immich tree**, root-owned like Docker leaves it: `upload/`,
`library/`, `profile/` (mode 700, a few random `.jpg` files each), `backups/`
(755) with a fresh `*.sql.gz` and an older one (`touch -d '3 days ago'`), and
`~/photos/2024/` including a non-ASCII name such as `é名 photo.jpg`.

**3. Fake drives and `diskutil`**: `mkdir -p $H/Volumes/BackupA $H/Volumes/BackupB`,
plus a `$H/bin/diskutil` script that appends its arguments to a file and
exits 0.

**4. A patched copy of the script** (never edit the real config for tests):

```sh
sed -e 's|^REMOTE_USER=.*|REMOTE_USER="immich"|' \
    -e 's|^REMOTE_HOST=.*|REMOTE_HOST="immichtest"|' \
    -e "s|^DRIVE_A=.*|DRIVE_A=\"$H/Volumes/BackupA\"|" \
    -e "s|^DRIVE_B=.*|DRIVE_B=\"$H/Volumes/BackupB\"|" \
    -e "s|^LOG_DIR=.*|LOG_DIR=\"$H/logs\"|" \
    immich-backup.sh > $H/t.sh
PATH="$H/bin:$PATH" bash $H/t.sh; echo "exit $?"
```

**5. Scenarios that were run, with their expected results:**

| Scenario | Expected |
|---|---|
| First run | exit 0, every file verified (incl. non-ASCII name), both drives "ejected" |
| Re-run, no changes | exit 0, 0 transferred, "needs 0 B" on both drives |
| `~/photos` emptied | exit 1 in pre-flight, both drives untouched |
| `~/photos` removed | exit 1 in pre-flight ("missing or unreadable") |
| `REMOTE_MOUNTPOINTS=("/home/immich/photos")` | exit 1 ("not a mount point") |
| Dump 2 days old | exit 1; with `DUMP_MAX_AGE_HOURS=0` exit 0 |
| No dump | exit 1 |
| 5 photos deleted, `MAX_DELETE=3` | exit 1, ≤3 deleted on A, B untouched; `MAX_DELETE=unlimited` → exit 0 |
| sudoers with rsync only | exit 1 naming the missing command and the sudoers line |
| Local `shasum` wrapper corrupts one hash | exit 2, file in `verification-failures.txt` |
| Local `shasum` wrapper omits a destination file | exit 2 ("missing or unreadable on destination") |
| `VERIFY_LOCAL_MIRROR=1`, wrapper omits a Drive A file | exit 3, file in `unverified.txt` |
| 40 old runs in `LOG_DIR` | 30 logs + 30 run dirs kept |

To simulate hashing failures, put a `shasum` wrapper first on `PATH` that runs
`/usr/bin/shasum "$@"` and drops or alters lines matching a pattern.

To unit-test single functions, source the script without its last line
(`sed '$d' t.sh > lib.sh; source lib.sh`) and call them directly, for example
`parse_bytes_transferred`, `drive_needed_bytes`, `_rsync_rc`, `prune_old_logs`.

## If a test suite is added

[bats-core](https://github.com/bats-core/bats-core) fits the codebase. To make
the functions sourceable without running `main`, guard the last line:

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
```
