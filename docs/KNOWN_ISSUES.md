# Known issues and risks

Found during a code review in September 2026. Nothing here has been fixed in
the script yet. The owner wants fixes pitched before they're implemented.

Status meanings:
- **Confirmed** — reproduced with real rsync / bash in a Linux container.
- **By inspection** — follows from the code; the effect depends on the
  owner's setup, which hasn't been checked on the real machines.

Severity is about the backup's integrity, not about how much code a fix takes.

---

## High

### 1. Remote `sudo du` and `sudo xargs sha256sum` aren't covered by the documented sudoers line
*By inspection. Depends on the remote user's real sudo rights.*

The README tells you to add only `user ALL=(ALL) NOPASSWD: /usr/bin/rsync`.
The script also runs:

- `sudo du -sb …` in `remote_source_bytes` (free-space pre-flight)
- `sudo xargs -0 sha256sum --` in `verify_ssh_leg` (verification)

Over non-interactive SSH, both fail with "a terminal is required". The effects:

- `remote_source_bytes`: stderr goes to `/dev/null` and `awk` prints `0`, so the
  source size is 0 and **the free-space check always passes**.
- `verify_ssh_leg`: logs "remote sha256sum failed; skipping verification of
  this batch" and returns 1. The caller ignores that with `|| true`, so
  `VERIFY_FAILED` stays 0 and **the run ends with `BACKUP COMPLETE` even though
  nothing was verified**. The only visible sign is `Verification checked: 0`.

If the remote user has full passwordless sudo, none of this happens, but
issue #2 does.

### 2. Free-space check ignores data already on the drive
*By inspection.*

`preflight` requires `free ≥ total_source × 1.1`. On every run after the first,
most of the source is already on the drive, so the real requirement is the
delta. Once the library is bigger than about 48% of the drive, the drive gets
rejected on every run even though the backup would fit. With both drives the
same size, the run then aborts with "No drive has enough free space". This is
currently hidden if issue #1 makes the source size 0.

### 3. `--delete` with no guard can wipe both drives in one run
*By inspection.*

If a source directory on the server is empty or unexpectedly missing, for
example when `~/photos` is a mount that didn't come up after a reboot or
someone moved it, then:

- if the directory is empty, `rsync --delete` empties the matching folder on
  Drive A, and the A→B mirror then empties it on Drive B **in the same run**;
- if the path doesn't exist, rsync errors and the run aborts, which is safe.

Nothing limits the damage: there's no `--max-delete` and no check for a
missing or unmounted source. Deletions or ransomware-encrypted files on the
server reach both drives the same way, because there's no versioning (see
README Non-goals).

---

## Medium

### 4. Verification is all-or-nothing per batch
*By inspection.*

`verify_ssh_leg` hashes a batch with `xargs … sha256sum`. If **any** file fails
to hash (it was deleted on the server after rsync copied it, or it has a bad
path, see #5), `xargs` exits 123 and the whole batch is skipped with no
per-file results. The lockstep comparison also assumes exactly one output line
per input. If one line were missing, every later file would be reported as
mismatched.

### 5. Non-UTF-8 locale breaks verification for non-ASCII filenames
*Confirmed.*

rsync escapes filename bytes it can't print in the current locale:

```
$ LANG=C rsync -a --itemize-changes src/ dst/
>f+++++++++ \#303\#251\#345\#220\#215.txt      # real name: é名.txt
```

The script feeds these escaped names to `sha256sum`/`shasum` as paths. They
don't exist, so the batch fails (#4). Terminal.app normally sets a UTF-8
locale. `launchd`, `cron` and some SSH contexts often don't. That matters if
the script is ever scheduled.

### 6. The exit code doesn't reflect verification failures or skipped verification
*By inspection.*

`print_summary` prints `BACKUP FINISHED WITH VERIFICATION FAILURES`, but the
exit code is still 0. Skipped verification (#1, #4) isn't reported as a
problem at all. A wrapper that alerts on a non-zero exit won't catch either.

### 7. rsync exit 24 ("some files vanished") aborts the run
*By inspection.*

If Immich deletes or moves a file while rsync is scanning, which is normal on
a live server, rsync exits 24. `rsync_ssh_leg` treats any non-zero exit as
fatal, so the remaining sources and the A→B mirror are skipped.

### 8. A missing or stale DB dump is only a warning
*By inspection.*

If no `*.sql.gz` is found, the run continues and can finish with
`BACKUP COMPLETE`. That happens when the backup job is disabled, when the
unprivileged `ls` in `find_latest_dump` can't read the directory, or when the
path is wrong. The dump's age isn't checked either, so a months-old dump is
treated the same as last night's. Without the DB, the photos come back but
albums, people, faces and metadata don't.

---

## Low

### 9. Byte totals use 1024-based units, but rsync `--human-readable` uses 1000
*Confirmed.* rsync reported `6.00M` for 6,000,005 bytes, and
`parse_bytes_transferred` turned that into 6,291,456 (+4.9%). The error is
+7.4% at G and +10% at T. It only affects the summary.

### 10. Log retention keeps about half as many run directories as intended
*Confirmed.* In `prune_old_logs`, the glob `[0-9]*_*` matches both the `.log`
files and the run directories, so `tail -n +31` counts them together. With 40
runs present, it kept 30 logs and only 15 directories.

### 11. File counters count both legs
`FILES_NEW/UPDATED/DELETED` add the SSH leg and the mirror leg together. One
new photo shows up as "Files new: 2". The dump counts as a file too.

### 12. Case-insensitive APFS
Default APFS is case-insensitive. Linux paths that differ only by case
(`IMG_1.JPG` and `img_1.jpg` in the same directory) collide on the drive. One
overwrites the other, and every run re-transfers them. This is unlikely under
Immich's own `upload/` and `library/`, but possible in `~/photos`. Formatting
the drives as *APFS (Case-sensitive)* avoids it.

### 13. `drive_ready` doesn't check that the path is a mounted volume
It only checks that the path is a directory and is writable. macOS
permissions on `/Volumes` normally make this safe for a non-root user. Under
`sudo`, a missing drive would mean writing to the boot disk. There's also no
check that it's the *right* drive, such as a marker file.

### 14. The Mac can sleep during a long first run
Nothing prevents idle sleep (for example with `caffeinate`).

### 15. Other edge cases
- GNU `sha256sum` prefixes the line with `\` for names containing a backslash
  or newline, so those files would be reported as mismatched.
- Two `SOURCES` entries with the same basename write to the same
  `rsync-<tag>.log`.
- `main "$@"` ignores all arguments. There's no `--help` or `--dry-run`.
- There's no lock against two runs at once.

---

## Restore-related notes (not bugs)

- `thumbs/` and `encoded-video/` aren't backed up. After a restore, Immich has
  to regenerate them (thumbnail and transcode jobs). Recent Immich versions
  also check for `.immich` marker files in each media folder at startup. Check
  the current Immich restore docs for how to recreate the empty folders.
- There's only one dump on the drives. If that dump is bad, no older one is
  available.
