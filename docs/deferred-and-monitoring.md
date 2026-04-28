# usb.sh - Deferred Items, Monitoring & Feedback

Post-implementation tracking document. Review weekly during daily use.
Update inline as items resolve or new friction surfaces.

---

## Deferred Features

Items decided but not yet implemented. Each has a trigger condition
for when to pick it up.

### Branch rename procedure automation
- **Status:** Deferred
- **Description:** Branch renames require a manual multi-step procedure
  (local rename, bare repo HEAD update, tracking reference update).
  A usb_rename_branch function could automate this.
- **Trigger:** Second time a manual branch rename is performed.
- **Notes:** First instance was the kbd main/master rename.

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

## Things to Monitor

Track these during daily use. Note observations in the friction log
or inline below.

> **Observation period complete (5+ weeks).** Main friction was standardizing
> the USB for multiple repos and remembering how to start new projects.
> Startup time and daily workflow are fine. Items marked [closed] below.

- **Phase assignments** - No friction observed in 5+ weeks. [closed]
- **usb_check usefulness** - Validated. Branch consistency check was added
  in response to the kbd rename issue. [closed]
- **sync_dirs logging verbosity** - No sync_dir entries in active use yet.
  _usb_run_sync_dirs implemented with per-entry summary logging. [open -
  evaluate when first sync_dir is actively used]
- **usb_new_project scaffold** - Used once (finances). User reports
  forgetting how to start new projects, confirming the scaffold's value.
  -h flag and README quick reference now improve discoverability. [closed]
- **Sync direction** - No local-to-USB sync friction reported. [closed]
- **Startup time** - No perceived lag. [closed]
- **Push/pull boilerplate** - Resolved. See Resolution Log. [closed]

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
### -h flag for all usb_ functions
- **Original status:** Deferred
- **Resolved:** Implemented in usb.sh. Every public function
  (usb_verify_connected, usb_push, usb_pull, usb_init_bare, usb_clone_all,
  usb_sync, usb_eject, usb_refresh, usb_status, usb_check, usb_new_project)
  supports -h/--help.

### Document loading architecture in usb-setup.md
- **Original status:** Deferred
- **Resolved:** usb-setup.md has a "Loading Architecture" section covering the
  .bashrc -> usb.sh -> module chain, why modules don't source usb.sh, and the
  USB_INITIALIZED guard pattern.

### Push/pull boilerplate centralization
- **Original status:** Monitoring item
- **Resolved:** Implemented as usb_push and usb_pull in usb.sh. Module
  template updated to use these instead of raw git commands.
