# usb.sh - Deferred Items, Monitoring & Feedback

Post-implementation tracking document. Review weekly during daily use.
Update inline as items resolve or new friction surfaces.

---

## Deferred Features

Items decided but not yet implemented. Each has a trigger condition
for when to pick it up.

### -h flag for all usb_ functions
**Status:** deferred
**Scope:** small (one commit)
**Functions:** usb_sync, usb_eject, usb_check, usb_new_project, usb_status, usb_refresh
**Pattern:** `if [[ "$1" == "-h" || "$1" == "--help" ]]; then echo "usage: ..."; return 0; fi`
**Trigger:** next time you forget a function's arguments and have to read the source

### Dry-run flag for usb_sync
**Status:** deferred from Phase 8
**Scope:** medium
**Behavior:** show what would sync without copying. Print each file that would be copied, skip the cp.
**Trigger:** first time you're unsure what usb_sync will do and hesitate to run it. Or first time sync_dirs copies something unexpected.
**Note:** usb_status + usb_check + sync log may be sufficient. Track whether you actually feel the need.

### Mirror-mode condition for sync_dirs
**Status:** deferred
**Scope:** medium (contained change to _usb_run_sync_dirs)
**Behavior:** new condition value "mirror" alongside "newer". Uses rsync --delete or equivalent find-based delete of dest files not in source.
**Trigger:** first time you delete files from a source dir and need the dest to reflect the deletion. If this never happens, don't build it.

### Parser extraction into shared function
**Status:** deferred
**Scope:** medium
**Current consumers:** LOAD section, usb_check, usb_new_project (lighter validation)
**Trigger:** a fourth consumer of the full conf parser appears. Two full parsers (LOAD, usb_check) is acceptable. Three is the threshold.

### USB backup to secondary drive
**Status:** deferred (design notes exist)
**Scope:** medium-large
**Design summary:**
- Local config `~/.config/usb-sh/backup.conf` with `backup_target=/path`
- Manifest-declared `backup_dir` keys for what to back up
- `usb_backup` command, manual trigger, rsync --update
- Always include .usb-manifest and .usb-projects/
**Trigger:** first time you worry about USB data loss or want a second copy
**Watch out for:** backup drive with .usb-manifest getting detected as primary USB

### Centralize usb-sh repo path
**Status:** deferred
**Scope:** small
**Problem:** modules hardcode `$HOME/personal_repos/usb-sh/usb.sh` in the integration check
**Solution:** single variable in infrastructure wrapper (bash/06_usb.sh), modules reference the variable
**Trigger:** repo location changes, or third module added with same hardcoded path

### Document loading architecture in usb-setup.md
**Status:** deferred
**Scope:** small
**What to document:** bash/ chain load order, how 06_usb.sh wraps usb.sh, why modules don't source usb.sh directly, the USB_INITIALIZED check
**Trigger:** before onboarding the setup to another machine or explaining it to someone

---

## Things to Monitor (first 2 weeks)

Track these during daily use. Note observations in the friction log
or inline below.

### Phase assignments
**Question:** are your sync entries on the right phase?
**Watch for:** entries on `auto` that you wish were `manual` (syncing too often, slow startup). Entries on `manual` that you keep forgetting to trigger.
**Log format:** `[date] sync_file X: wanted phase Y, had phase Z`

### usb_check usefulness
**Question:** does usb_check give you enough to debug setup problems?
**Watch for:** times you run usb_check then immediately do manual `ls`, `cat`, or `find` to get info usb_check didn't show. That's a signal usb_check needs more output.
**Log format:** `[date] usb_check missed: needed to manually check X`

### sync_dirs logging verbosity
**Question:** is the summary-only log line enough?
**Watch for:** times you need to know which specific files were copied and have to dig through timestamps or check manually. If this happens more than twice, add a verbose flag.
**Log format:** `[date] sync_dirs: needed per-file detail for X`

### usb_new_project scaffold
**Question:** are the defaults and template comments useful?
**Watch for:** how much you edit after the scaffold opens. If you change the same things every time (different base path, different repo structure), update the defaults.
**Log format:** `[date] usb_new_project: changed X from default`

### Push/pull boilerplate
**Question:** should git push/pull be in usb.sh itself?
**Watch for:** writing the same `git push "$USB_MOUNT_POINT/$USB_*_REPO_PATH" master` pattern in multiple modules. If three modules have it, extract to `usb_push <project>` and `usb_pull <project>`.
**Log format:** `[date] wrote git push/pull boilerplate in X module`

### Sync direction
**Question:** do you need local-to-USB sync?
**Watch for:** currently all sync entries go USB -> local. If you find yourself manually copying files from local to USB, that's a signal for bidirectional support or a reverse sync_file entry.
**Log format:** `[date] manually copied local -> USB: file X`

### Startup time
**Question:** does usb.sh add noticeable delay to shell startup?
**Watch for:** perceptible lag when opening a new terminal. The powershell.exe call for USB detection on WSL is the slowest part. Cache should mitigate. If startup feels slow, time it: `time source ~/.config/mc_extensions/usb.sh force`
**Log format:** `[date] startup felt slow, measured Xms`

---

## Patterns to Track

Recurring patterns that might indicate a design change is needed.

### Pattern: "I keep forgetting to run X"
If you forget usb_sync before unplugging, or forget usb_eject: consider adding a reminder to PS1 when USB is connected, or a pre-eject hook.

### Pattern: "I edited the conf but forgot to re-source"
If this happens repeatedly: consider a file watcher or a check in usb_sync that compares conf mtime against last-load time.

### Pattern: "I want different sync behavior per machine"
If the same conf needs different phases or paths on different machines: the current design is one conf per project on the USB. Machine-specific overrides would need a local overlay mechanism. Track if this actually comes up.

### Pattern: "usb.sh broke and I don't know what changed"
If debugging is hard after a change: consider adding a `usb_version` or `usb_debug` command that prints the git hash of the usb-sh repo, loaded conf checksums, and environment info.

---

## Metrics (check monthly)

- Number of loaded projects (growth rate)
- Total sync_file + sync_dir entries across all projects
- usb_check error rate (how often it finds real problems vs. all-clear)
- Sync log size and entry count (is it growing unmanageably?)
- Number of modules using the integration pattern
- Times usb_eject reported drive still busy (Windows eject reliability)

---

## Resolution Log

Record when deferred items get implemented or deliberately dropped.

| Date | Item | Action | Notes |
|------|------|--------|-------|
|      |      |        |       |
