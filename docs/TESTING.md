# Testing

There is no automated test suite and no CI. This page explains what can
be checked, and where.

## What you can't test in a Linux container

The full run needs macOS (`diskutil`, `/Volumes`, BSD `shasum`/`df`), two
mounted drives, and a reachable Immich host with the sudoers entry. Don't claim
end-to-end verification from a container. Say which parts you exercised.

## Static checks

```sh
bash -n immich-backup.sh
shellcheck -s bash immich-backup.sh
```

Current shellcheck baseline (keep it from growing):

| Code | Where | Note |
|---|---|---|
| SC2034 | `DB_CONTAINER`, `DB_USER`, `DB_NAME`, `C_GRN` | Unused placeholders |
| SC2029 | `remote_ssh` | Intentional: command string is built locally |
| SC2010, SC2012 | `prune_old_logs` | `ls \| grep`, safe for the timestamped names used |
| SC2086 | `return $rc` in rsync wrappers | Harmless |

Bash 3.2 compatibility isn't something shellcheck checks. If you have a Mac,
run `/bin/bash -n immich-backup.sh`. Otherwise, review against the list in
`AGENTS.md`.

## Testing individual functions against real rsync output

The parsers are pure functions over an rsync log file, so you can test them on
Linux with real rsync 3.x (`apt-get install rsync`).

```sh
S=$(mktemp -d); cd "$S"
mkdir -p src/sub dst
for i in $(seq 1 30); do head -c 200000 /dev/urandom > "src/sub/f$i.bin"; done
echo hi > "src/é名.txt"; echo x > "src/sp ace.txt"

# Same flags as RSYNC_BASE_FLAGS, then the same \r→\n normalisation.
LANG=C.UTF-8 rsync -aH --delete --partial --info=progress2 --human-readable \
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

## Simulating the remote

You can point the SSH leg at `localhost` in a container with `openssh-server`,
a user with a `NOPASSWD: /usr/bin/rsync` sudoers entry, and a fake
`~/immich-app/library` tree. That exercises `check_ssh`, `rsync_ssh_leg`,
`verify_ssh_leg` and `remote_source_bytes` against realistic sudo behaviour.
`diskutil` has to be stubbed (for example, a `diskutil` script on `PATH` that
prints and exits 0), and `DRIVE_A`/`DRIVE_B` pointed at temp dirs.

## If a test suite is added

[bats-core](https://github.com/bats-core/bats-core) fits the codebase. To make
the functions sourceable without running `main`, guard the last line:

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
```
