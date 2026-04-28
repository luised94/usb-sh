# usb.sh - Design Document


## Purpose

A reusable shell module that manages USB detection, project configuration
loading, file synchronization, and shared git operations. It knows nothing
about any specific project (kbd, finances, SM2, etc.).

usb.sh is sourced once by `.bashrc`. It exports `USB_*` variables into
the shell environment. Project modules (kbd.sh, finances.sh, etc.) are
sourced separately by `.bashrc` after usb.sh and read those exported
variables - they do not source usb.sh themselves.

Extracted from `kbd.sh` to support multiple projects sharing a single
USB without duplicating infrastructure.

---


## Ownership Boundary

**usb.sh owns:**

- USB hardware detection (WSL fast/slow path, Linux scan)
- Parsing `.usb-manifest` and `.usb-projects/*.conf` (as data, not sourced as bash)
- Token resolution in conf entries
- Exporting project metadata into `USB_<PROJECT>_*` namespace
- Executing `sync_file` entries (condition-gated `cp`)
- Executing `sync_dir` entries (per-file newer check via find)
- Generic bare-repo git operations (`usb_push`, `usb_pull`, `usb_init_bare`)
- Health checks (`usb_check`: mount, manifest, confs, remotes, branch consistency)
- PS1 integration: USB connectivity indicator
- Eject: pre-eject sync, unmount, PowerShell eject (WSL), state cleanup

**usb.sh does NOT own:**

- Project-specific git operations (commit strategy, add patterns) - project modules do this
- Multi-hop syncs (e.g. Zotero  USB) - project modules do this
- Project-specific aliases, functions, or prompt customization

---

## USB File Structure

```
USB_ROOT/
|-- .usb-manifest                  # detection marker + global config
|-- .usb-projects/                 # per-project conf files
³   |-- kbd.conf
³   ÀÄÄ finances.conf
|-- personal_repos/                # bare git repos
³   |-- kbd.git
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
|-- usb.sh
|-- README.md
|-- docs/
    |-- design.md          # this document
    |-- usb-setup.md       # reference copies of manifest + confs
```

Delivery: `~/.config/mc_extensions/usb.sh` symlinks to `~/personal_repos/usb-sh/usb.sh`. The mc_extensions directory is managed by the user's config repo, designed to be extensible via symlinks.

---

## .usb-manifest Schema

Lives at USB root. Parsed as data (while-read loop), not sourced as
bash. Two roles: detection marker (its presence identifies a managed USB)
and global configuration (settings that apply across all projects).

.usb-manifest
VERSION=1
LABEL=luised94-usb
DEFAULT_PHASE=auto
SYNC_LOG=.usb-sync.log

| Key on disk | Exported as | Type | Purpose |
|-------------|-------------|------|---------|
| `VERSION` | `USB_MANIFEST_VERSION` | integer | Format version for forward-compat |
| `LABEL` | `USB_LABEL` | string | Human-readable identifier, appears in logs |
| `DEFAULT_PHASE` | `USB_DEFAULT_PHASE` | string enum: `auto\|manual\|always` | Fallback phase for sync entries that omit it |
| `SYNC_LOG` | `USB_SYNC_LOG` | string, relative path | Log file for sync operations on USB |

---

## Project Conf Schema

Lives at `.usb-projects/<name>.conf` on USB. Parsed as data (while-read
loop), not sourced as bash. Plain key-value format with repeated keys for
multi-value fields. The parser ignores blank lines and lines starting
with `#`. Unknown keys produce a warning.

.usb-projects/kbd.conf
local_dir={HOME}/personal_repos/kbd
repo_path=personal_repos/kbd.git
sync_file={USB_ROOT}/shared/kbd_zotero_library.bib:{LOCAL_DIR}/zotero_library.bib:newer:auto
sync_dir=

| Key | Type | Purpose |
|-----|------|---------|
| `local_dir` | string, path with `{HOME}` token | Local project root. Required. Validated on load - warn and skip if missing. |
| `repo_path` | string, relative to USB root | Bare git repo location. Required. Used by `usb_push`/`usb_pull`/`usb_init_bare`. |
| `sync_file` | string, repeated key | File sync entries. One per line, repeat the key. Format below. |
| `sync_dir` | string, repeated key | Directory sync entries. One per line, repeat the key. Format below. |

### sync_file Entry Format

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

### sync_dir Entry Format

src_dir:dest_dir:condition:phase


| Field | Type | Values | Notes |
|-------|------|--------|-------|
| `src_dir` | string, path | May contain `{USB_ROOT}`, `{LOCAL_DIR}` tokens | Source directory. Must exist. |
| `dest_dir` | string, path | May contain `{USB_ROOT}`, `{LOCAL_DIR}` tokens | Destination directory. Top-level must exist (setup error if missing). Subdirectories created as needed. |
| `condition` | string enum | `newer` | Per-file `-nt` check via `find -type f`. Copies files newer than dest counterpart. Does not delete files missing from source. Symlinks skipped with warning. |
| `phase` | string enum | `auto\|manual\|always` | When this entry runs. Defaults to `USB_DEFAULT_PHASE` from manifest if omitted. |

Parsed via: `IFS=: read -r src_dir dest_dir condition phase <<< "$entry"`

Path safety: destination file paths are validated to stay within the declared `dest_dir`. Entries that would write outside `dest_dir` are rejected with an error.

### Token Resolution

Tokens are resolved in two stages during conf parsing:

1. **`{HOME}` in `local_dir`:** resolved immediately when the `local_dir`
   line is parsed, before any other processing.
2. **`{USB_ROOT}` and `{LOCAL_DIR}` in sync entries:** resolved after
   `local_dir` is known, applied to both `sync_file` and `sync_dir`
   entries using bash parameter expansion:

```bash
entry="$${entry//\{USB_ROOT\}/$$USB_MOUNT_POINT}"
entry="$${entry//\{LOCAL_DIR\}/$$usb_parsed_local_dir}"
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


Linear, not wrapped in functions. Four sections delimited by comments.
Section order is FIND  LOAD  FUNCTIONS  SYNC. FUNCTIONS must precede
SYNC because the SYNC section calls `_usb_run_sync_files` at source time -
bash requires a function to be defined before the line that calls it.

### FIND

1. Set `USB_CONNECTED=false`, unset `USB_MOUNT_POINT`.
2. If `force` argument passed, delete cache file.
3. Detect environment  set `USB_ENV`.
4. **WSL fast path:** read `/tmp/usb_drive_cache`. If cached drive letter's mount point contains `.usb-manifest`, set `USB_MOUNT_POINT`, `USB_CONNECTED=true`.
5. **WSL slow path:** if fast path missed, run PowerShell `Get-Volume` scan looking for `.usb-manifest`. If found, set drive letter, mount if needed, update cache.
6. **Linux path:** scan `/mnt/*`, `/media/$USER/*`, `/run/media/$USER/*` for `.usb-manifest`.

### LOAD

Runs only if `USB_CONNECTED=true`.

1. Parse `.usb-manifest` from `$USB_MOUNT_POINT/.usb-manifest` using a
   while-read loop. Each `key=value` line is read; keys are mapped to
   `USB_*` global variables (e.g. `VERSION`  `USB_MANIFEST_VERSION`).
2. Resolve `USB_SYNC_LOG` to absolute path: `$USB_MOUNT_POINT/$USB_SYNC_LOG`.
3. Initialize `USB_LOADED_PROJECTS=()`.
4. For each `.conf` file in `$USB_MOUNT_POINT/.usb-projects/`:
   a. Extract project name from filename (strip path and `.conf` suffix).
   b. Parse the conf file using a while-read loop. Each `key=value` line
      populates local variables (`local_dir`, `repo_path`) or accumulates
      into local arrays (`sync_file` entries  array, `sync_dir` entries
       array).
    c. Resolve {HOME} token in local_dir.
    d. Validate local_dir and repo_path are present. Validate
        local_dir directory exists. If not, warn and skip this project.
    e. Uppercase project name: proj_upper="${name^^}".
    f. Resolve {USB_ROOT} and {LOCAL_DIR} tokens in each sync_file
    and sync_dir entry.
    g. Export: USB_${proj_upper}_LOCAL_DIR, USB_${proj_upper}_REPO_PATH,
    USB_${proj_upper}_SYNC_FILES (array),
    USB_${proj_upper}_SYNC_DIRS (array).
    h. Append project name to USB_LOADED_PROJECTS.

5. Report loaded projects.

### SYNC

Runs only if `USB_CONNECTED=true` and `USB_LOADED_PROJECTS` is non-empty.

For each project in `USB_LOADED_PROJECTS`:

1. Run `_usb_run_sync_files` with trigger `startup`:
   a. For each `sync_file` entry, parse `src:dest:condition:phase`.
   b. If phase is empty, use `USB_DEFAULT_PHASE`.
   c. If phase is `auto` or `always`, execute the sync.
   d. If condition is `newer`, test `[[ "$src" -nt "$dest" ]]`. If true,
      `cp "$src" "$dest"`.
   e. Log the operation to `USB_SYNC_LOG`.
2. Run `_usb_run_sync_dirs` with trigger `startup`:
   a. For each `sync_dir` entry, parse `src_dir:dest_dir:condition:phase`.
   b. Same phase filtering as sync_files.
   c. If condition is `newer`, walk source tree via `find -type f`, copy
      files newer than dest counterpart. Create subdirectories as needed.
   d. Log summary (copied count, error count) to `USB_SYNC_LOG`.

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

## Module Integration

Project modules (kbd.sh, finances.sh, etc.) integrate with usb.sh by
reading the exported `USB_*` variables. They do NOT source usb.sh - they
are sourced separately by `.bashrc` after usb.sh has run.

The module guard checks `USB_INITIALIZED` and degrades gracefully if
usb.sh has not run - local features (aliases, navigation, project-specific
scripts) remain available regardless of USB state. Only USB operations
(push, pull, sync) require `USB_CONNECTED=true`, and those checks happen
inside the `usb_` functions themselves.

See `docs/module-template.sh` for the canonical integration pattern,
including the guard, directory fallback, alias definitions, function
wrappers around `usb_push`/`usb_pull`, and the `-h`/`--help` convention.

---

## Deferred Decisions

- **Multiple USB drives.** Single drive assumed. `{USB_ROOT}` tokens
  keep confs drive-letter-agnostic so adding a second drive is a policy
  decision, not a structural rewrite.
- **Condition types beyond `newer`.** The condition field in both
  `sync_file` and `sync_dir` entries is extensible. `newer` is the only
  implemented condition. Add `always`, `missing`, `checksum`, etc. as
  needed. Mirror-mode for sync_dirs (delete dest files not in source)
  is tracked in `deferred-and-monitoring.md`.
- **envsubst for token resolution.** Rejected - pure bash parameter
  expansion is sufficient and dependency-free.

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
