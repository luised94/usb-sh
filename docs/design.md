# usb.sh - Design Document

## Purpose

A reusable shell module that manages USB detection, project configuration loading, and file synchronization. It knows nothing about any specific project (kbd, finances, SM2, etc.). Projects source `usb.sh` and compose on top of it.

Extracted from `kbd.sh` to support multiple projects sharing a single USB without duplicating infrastructure.

---

## Ownership Boundary

**usb.sh owns:**
- USB hardware detection (WSL fast/slow path, Linux scan)
- Sourcing `.usb-manifest` and `.usb-projects/*.conf`
- Token resolution in conf entries
- Exporting project metadata into `USB_<PROJECT>_*` namespace
- Executing `sync_files` entries (condition-gated `cp`)
- Eject: pre-eject sync, unmount, PowerShell eject (WSL), state cleanup

**usb.sh does NOT own:**
- Git operations (push, pull, commit) - project modules do this
- Multi-hop syncs (e.g. Zotero  USB) - project modules do this
- Project-specific aliases, functions, or PS1 formatting
- Directory sync execution - declared in schema, not implemented yet

---

## USB File Structure

```
USB_ROOT/
ÃÄÄ .usb-manifest                  # detection marker + global config
ÃÄÄ .usb-projects/                 # per-project conf files
³   ÃÄÄ kbd.conf
³   ÀÄÄ finances.conf
ÃÄÄ personal_repos/                # bare git repos
³   ÃÄÄ kbd.git
³   ÀÄÄ finances.git
ÀÄÄ shared/                        # cross-project artifacts, non-git
    ÀÄÄ kbd_zotero_library.bib
```

`personal_repos/` holds bare git repos - things that are authored and versioned. `shared/` holds generated artifacts and file-copy targets - things that flow onto the USB from external sources (Zotero, exports, etc.).

**Naming convention in `shared/`:** files are prefixed with the name of the project responsible for placing them on the USB. `kbd_zotero_library.bib` means kbd owns that file - `kbib_sync` puts it there. Other projects may read from it via their own `sync_files` entries pointing at the same path. The prefix marks ownership, not exclusive access. usb.sh does not parse or act on the prefix - it is a human-readable convention only. The confs are the machine-readable source of truth for which projects use which files.

---

## Local File Structure

```
~/personal_repos/usb-sh/
ÃÄÄ usb.sh
ÃÄÄ README.md
ÀÄÄ docs/
    ÃÄÄ design.md          # this document
    ÀÄÄ usb-setup.md       # reference copies of manifest + confs
```

Delivery: `~/.config/mc_extensions/usb.sh` symlinks to `~/personal_repos/usb-sh/usb.sh`. The mc_extensions directory is managed by the user's config repo, designed to be extensible via symlinks.

---

## .usb-manifest Schema

Lives at USB root. Sourced as bash. Two roles: detection marker (its presence identifies a managed USB) and global configuration (settings that apply across all projects).

```bash
# .usb-manifest
USB_MANIFEST_VERSION=1
USB_LABEL="luised94-usb"
USB_DEFAULT_PHASE="auto"
USB_SYNC_LOG=".usb-sync.log"    # path relative to USB root
```

| Key | Type | Purpose |
|-----|------|---------|
| `USB_MANIFEST_VERSION` | integer | Format version for forward-compat |
| `USB_LABEL` | string | Human-readable identifier, appears in logs |
| `USB_DEFAULT_PHASE` | string enum: `auto\|manual\|always` | Fallback phase for sync entries that omit it |
| `USB_SYNC_LOG` | string, relative path | Log file for sync operations on USB |

---

## Project Conf Schema

Lives at `.usb-projects/<name>.conf` on USB. Sourced as bash. Restricted vocabulary - only these keys are valid:

```bash
# .usb-projects/kbd.conf
local_dir="$HOME/personal_repos/kbd"
repo_path="personal_repos/kbd.git"

sync_files=(
    "{USB_ROOT}/shared/kbd_zotero_library.bib:{LOCAL_DIR}/zotero_library.bib:newer:auto"
)

sync_dirs=()
```

| Key | Type | Purpose |
|-----|------|---------|
| `local_dir` | string, absolute path | Local project root. Validated on load - warn and skip project if missing. |
| `repo_path` | string, relative to USB root, optional | Bare git repo location. Metadata only - usb.sh does not act on it. Project module reads `USB_<PROJECT>_REPO_PATH` for git operations. |
| `sync_files` | bash array of strings | File sync entries. Format below. |
| `sync_dirs` | bash array of strings | Directory sync entries. Placeholder - declared in schema, not processed by usb.sh yet. |

No other shell code should appear in conf files. This is convention, not enforcement.

### sync_files Entry Format

```
src:dest:condition:phase
```

| Field | Type | Values | Notes |
|-------|------|--------|-------|
| `src` | string, path | May contain `{USB_ROOT}`, `{LOCAL_DIR}` tokens | Source file path |
| `dest` | string, path | May contain `{USB_ROOT}`, `{LOCAL_DIR}` tokens | Destination file path |
| `condition` | string enum | `newer` | `newer`  bash `-nt` test: copy only if src is newer than dest. Extensible - add conditions as needed. |
| `phase` | string enum | `auto\|manual\|always` | When this entry runs. Defaults to `USB_DEFAULT_PHASE` from manifest if omitted. |

Parsed via: `IFS=: read -r src dest condition phase <<< "$entry"`

### sync_dirs Entry Format (placeholder)

```
src_dir:dest_dir:method:phase
```

| Field | Type | Values |
|-------|------|--------|
| `src_dir` | string, path | Source directory |
| `dest_dir` | string, path | Destination directory |
| `method` | string enum | `update` (rsync, no delete) \| `mirror` (rsync --delete) |
| `phase` | string enum | `auto\|manual\|always` |

Not implemented. Declared here so the schema is complete and confs can include entries without breaking the parser.

### Token Resolution

After sourcing a conf, usb.sh resolves tokens in all `sync_files` and `sync_dirs` entries:

```bash
entry="${entry//\{USB_ROOT\}/$USB_MOUNT_POINT}"
entry="${entry//\{LOCAL_DIR\}/$resolved_local_dir}"
```

Pure bash parameter expansion. No external dependencies.

---

## Variable Namespace

### Global (set by usb.sh startup)

| Variable | Type | Set When |
|----------|------|----------|
| `USB_CONNECTED` | string: `true\|false` | Always |
| `USB_MOUNT_POINT` | string, absolute path | USB found |
| `USB_ENV` | string: `wsl\|linux` | Always |
| `USB_LABEL` | string | USB found, from manifest |
| `USB_MANIFEST_VERSION` | integer | USB found, from manifest |
| `USB_DEFAULT_PHASE` | string | USB found, from manifest |
| `USB_SYNC_LOG` | string, absolute path | USB found, resolved from manifest |
| `USB_LOADED_PROJECTS` | bash indexed array | USB found, after LOAD |

### Per-Project (set during LOAD phase)

For a project named `kbd`, the conf exports:

| Variable | Source |
|----------|--------|
| `USB_KBD_LOCAL_DIR` | `local_dir` from conf |
| `USB_KBD_REPO_PATH` | `repo_path` from conf |
| `USB_KBD_SYNC_FILES` | `sync_files` from conf, tokens resolved |
| `USB_KBD_SYNC_DIRS` | `sync_dirs` from conf, tokens resolved |

Project name is uppercased via `${name^^}`.

---

## Phase Model

Three phases govern when sync entries execute:

| Phase | Triggers | Use Case |
|-------|----------|----------|
| `auto` | Startup (USB detection) and eject | Files you always want current. Default. |
| `manual` | Only when `usb_sync <project>` is explicitly called | Slow, risky, or timing-sensitive syncs |
| `always` | All triggers: startup, manual, eject | Files that must be current no matter what |

### Trigger  Phase Mapping

| Trigger | Runs phases |
|---------|------------|
| Startup (SYNC phase of usb.sh init) | `auto`, `always` |
| `usb_sync [project]` | `manual`, `always` |
| `usb_eject` (pre-unmount) | `auto`, `always` |

---

## Startup Procedure

Linear, not wrapped in functions. Three phases delimited by comments.

### FIND

1. Set `USB_CONNECTED=false`, unset `USB_MOUNT_POINT`.
2. If `force` argument passed, delete cache file.
3. Detect environment  set `USB_ENV`.
4. **WSL fast path:** read `/tmp/usb_drive_cache`. If cached drive letter's mount point contains `.usb-manifest`, set `USB_MOUNT_POINT`, `USB_CONNECTED=true`.
5. **WSL slow path:** if fast path missed, run PowerShell `Get-Volume` scan looking for `.usb-manifest`. If found, set drive letter, mount if needed, update cache.
6. **Linux path:** scan `/mnt/*`, `/media/$USER/*`, `/run/media/$USER/*` for `.usb-manifest`.

### LOAD

Runs only if `USB_CONNECTED=true`.

1. Source `.usb-manifest` from `$USB_MOUNT_POINT/.usb-manifest`. Exports global config variables.
2. Resolve `USB_SYNC_LOG` to absolute path: `$USB_MOUNT_POINT/$USB_SYNC_LOG`.
3. Initialize `USB_LOADED_PROJECTS=()`.
4. For each `.conf` file in `$USB_MOUNT_POINT/.usb-projects/`:
   a. Extract project name from filename (strip path and `.conf` suffix).
   b. Source the conf file (sets `local_dir`, `repo_path`, `sync_files`, `sync_dirs` as local variables).
   c. Validate `local_dir` exists. If not, warn and skip this project.
   d. Uppercase project name: `proj_upper="${name^^}"`.
   e. Resolve tokens in each `sync_files` entry.
   f. Export: `USB_${proj_upper}_LOCAL_DIR`, `USB_${proj_upper}_REPO_PATH`, `USB_${proj_upper}_SYNC_FILES`, `USB_${proj_upper}_SYNC_DIRS`.
   g. Append project name to `USB_LOADED_PROJECTS`.
5. Report loaded projects.

### SYNC

Runs only if `USB_CONNECTED=true` and `USB_LOADED_PROJECTS` is non-empty.

1. For each project in `USB_LOADED_PROJECTS`:
   a. Retrieve that project's `SYNC_FILES` array.
   b. For each entry, parse `src:dest:condition:phase`.
   c. If phase is empty, use `USB_DEFAULT_PHASE`.
   d. If phase is `auto` or `always`, execute the sync.
   e. Execute: if condition is `newer`, test `[[ "$src" -nt "$dest" ]]`. If true, `cp "$src" "$dest"`.
   f. Log the operation to `USB_SYNC_LOG` with timestamp, project, src, dest, result.

---

## Functions

### `usb_sync [project]`

If `project` given: filter to that project. Otherwise: all loaded projects.

For each matching project, run `sync_files` entries where phase is `manual` or `always`. Same execution logic as startup SYNC. Log results.

### `usb_eject`

1. Run `sync_files` entries where phase is `auto` or `always` for all loaded projects (the exit sync).
2. If current directory is under `USB_MOUNT_POINT`, `cd ~`.
3. Unmount `USB_MOUNT_POINT` if mounted.
4. **WSL only:** remove empty mount directory, PowerShell eject, verify.
5. **State cleanup:** iterate `USB_LOADED_PROJECTS`, unset all `USB_${proj_upper}_*` variables. Unset global USB variables. Set `USB_CONNECTED=false`.
6. Delete `/tmp/usb_drive_cache`.

---

## How kbd.sh Changes Post-Refactor

```bash
source "$HOME/.config/mc_extensions/usb.sh"

KBD_DIR="${USB_KBD_LOCAL_DIR:-$HOME/personal_repos/kbd}"

# Aliases - always available
alias kj='nvim "$KBD_DIR/journal.txt"'
# ...etc

# ksync: git ops + file sync
ksync() {
    # git add/commit/push (kbd-specific logic)
    usb_sync kbd
}

# kpull: git pull + file sync
kpull() {
    # git pull (kbd-specific logic)
    usb_sync kbd
}

# kbib_sync: Zotero  USB (three-hop first leg, kbd-specific)
kbib_sync() {
    local src="/mnt/c/Users/${MC_WINDOWS_USER:-Luised94}/Zotero/zotero_library.bib"
    local dest="$USB_MOUNT_POINT/shared/kbd_zotero_library.bib"
    [[ "$src" -nt "$dest" ]] && cp "$src" "$dest"
}

# PS1: reads USB_CONNECTED, formats kbd-specific
kbd_origin_indicator() {
    [[ "$USB_CONNECTED" == true ]] && echo "kbd[O]" || echo "kbd[ ]"
}
```

Git remote validation, commit strategy, and all git operations stay in kbd.sh. `kusboff` is replaced by `usb_eject` (or aliased if preferred).

---

## Deferred Decisions

- **Multiple USB drives.** Single drive assumed. `{USB_ROOT}` tokens keep confs drive-letter-agnostic so adding a second drive is a policy decision, not a structural rewrite.
- **sync_dirs implementation.** Schema declared, not processed. Implement when a concrete directory sync use case arrives.
- **Condition types beyond `newer`.** The condition field is extensible. Add `always`, `missing`, `checksum`, etc. as needed.
- **envsubst for token resolution.** Rejected - pure bash parameter expansion is sufficient and dependency-free.

---

## Post-Implementation Notes

### USB_DRIVE_LETTER Added to Global Schema
`USB_DRIVE_LETTER` was not in the original variable table. It is set during FIND (WSL path only) and holds the Windows drive letter (e.g. "D"). It is required by `usb_eject` to invoke the PowerShell eject verb. It is unset on eject along with the other global USB vars.

Full entry for the global variable table:

| Variable | Type | Set When |
|----------|------|----------|
| `USB_DRIVE_LETTER` | string, single letter | USB found on WSL |

### FUNCTIONS Section Moved Before SYNC
The original design implied section order: FIND -> LOAD -> SYNC -> FUNCTIONS. The implemented order is FIND -> LOAD -> FUNCTIONS -> SYNC. The SYNC section calls `_usb_run_sync_files` at source time, not inside a deferred function. Bash requires a function to be defined before the line that calls it is reached. Moving FUNCTIONS above SYNC resolves the forward-reference without any behavioral change.

### Array Write: eval + printf %q in LOAD
Bash arrays cannot be exported via the `export` builtin -- only scalar variables can be exported to the environment. Per-project arrays are assigned into the global scope using eval with printf %q quoting:
```
eval "USB_${upper}_SYNC_FILES=($(printf '%q ' "${entries[@]}"))"
```

printf %q quotes each entry safely, handling paths with spaces or special characters. No external dependencies.

### Array Read: declare -n Nameref in Functions
Inside `_usb_run_sync_files`, the per-project array is read via a declare -n nameref rather than eval-by-index:
```
declare -n usb_sync_files_array_ref="$usb_sync_files_variable_name"
```

Namerefs are cleaner than eval for reading and require bash 4.3+, which is confirmed on the target system. Namerefs are used for reading only -- writing through a nameref to a dynamically-named global is less predictable and is avoided.
```

---
