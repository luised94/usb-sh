# usb.sh Setup Reference

## USB Directory Structure
```
<USB_ROOT>/
  .usb-manifest              # USB identity and global settings
  .usb-sync.log              # Sync activity log
  .usb-projects/
    kbd.conf                  # Per-project configuration
    _template.conf.example    # Template for new projects
  personal_repos/
    kbd.git/                  # Bare git repositories
  shared/                     # Shared files synced between machines
```

## Manifest Format

File: `.usb-manifest`. Plain key-value, one per line.
```
VERSION=1
LABEL=luised94-usb
SYNC_LOG=.usb-sync.log
DEFAULT_PHASE=auto
```

Required keys: VERSION, LABEL. SYNC_LOG and DEFAULT_PHASE are optional
but expected.

## Conf Format

File: `.usb-projects/<project_name>.conf`. Plain key-value, one per
line. Not sourced -- parsed as data.
```
local_dir={HOME}/personal_repos/myproject
repo_path=personal_repos/myproject.git
sync_file={USB_ROOT}/shared/data.txt:{LOCAL_DIR}/data.txt:newer:auto
sync_dir={USB_ROOT}/shared/docs:{LOCAL_DIR}/docs:newer:auto
```

Required keys: local_dir, repo_path. Repeated sync_file and sync_dir
keys add multiple entries.

### Tokens

| Token       | Resolved to                        | Used in     |
|-------------|------------------------------------|-------------|
| {HOME}      | Runtime value of $HOME             | local_dir   |
| {USB_ROOT}  | USB mount point                    | sync_file, sync_dir |
| {LOCAL_DIR} | Resolved local_dir for the project | sync_file, sync_dir |

Resolution order: {HOME} resolves first (local_dir depends on it),
then {USB_ROOT} and {LOCAL_DIR} resolve after the conf is fully parsed.

## Sync Entry Format

Both sync_file and sync_dir use: `src:dest:condition:phase`

**condition** controls when a file is copied:
- `newer` -- copy if source is newer than dest (uses bash -nt test).
  A missing dest file is treated as older, so the file is copied.

**phase** controls which triggers run the entry:
- `auto` -- runs on startup and eject
- `manual` -- runs on explicit usb_sync call only
- `always` -- runs on every trigger

If phase is omitted, DEFAULT_PHASE from the manifest applies.

## How Sync Works

Sync runs at three trigger points. Each trigger runs entries matching
specific phases:

| Trigger | When                         | Phases run       |
|---------|------------------------------|------------------|
| startup | usb.sh is sourced            | auto, always     |
| sync    | usb_sync called explicitly   | manual, always   |
| eject   | usb_eject called             | auto, always     |

**sync_file** copies a single file if the source is newer than the
dest. The dest directory must already exist -- a missing dest directory
is a setup error (prevents silent writes to wrong locations).

**sync_dir** walks the source directory tree and copies each file that
is newer than its counterpart in the dest tree. The top-level dest
directory must exist, but subdirectories are created as needed.
Symlinks in the source are skipped with a warning. Files deleted from
the source are not removed from the dest -- sync_dir copies, it does
not mirror.

## How to Add a New Project

1. Create a bare repo on the USB (if using git):
   `git clone --bare /path/to/repo <USB_ROOT>/personal_repos/myproject.git`

2. Copy the template and fill in values:
   `cp <USB_ROOT>/.usb-projects/_template.conf.example <USB_ROOT>/.usb-projects/myproject.conf`

3. Edit myproject.conf with the correct local_dir and repo_path.

4. Ensure local_dir exists on the local machine.

5. Re-source usb.sh: `source ~/.config/mc_extensions/usb.sh force`

6. Verify: `usb_status` should show the new project.

## How to Add Sync Entries

Add sync_file or sync_dir lines to the project's conf file. One entry
per line using the `src:dest:condition:phase` format.

Example -- sync a single file from USB to local on startup and eject:
```
sync_file={USB_ROOT}/shared/data.csv:{LOCAL_DIR}/data.csv:newer:auto
```

Example -- sync an entire directory, manual trigger only:
```
sync_dir={USB_ROOT}/shared/references:{LOCAL_DIR}/references:newer:manual
```

After editing, re-source usb.sh with `source ~/.config/mc_extensions/usb.sh force`
and run `usb_status` to confirm the new entry count.

## Maintenance Commands

| Command          | Purpose                              |
|------------------|--------------------------------------|
| usb_status       | Print connection state and config    |
| usb_sync [proj]  | Manually trigger sync (manual phase) |
| usb_eject        | Sync, unmount, eject                 |
| usb_refresh      | Re-source usb.sh with force          |
| usb_check        | Validate conf paths and entries      |
