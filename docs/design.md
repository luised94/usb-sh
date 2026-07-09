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
|   |-- design.md                    # this document
|   |-- usb-setup.md                 # operational reference
|   |-- module-template.sh           # integration template for new modules
|   |-- implementation-plan.md       # historical: original build plan
|   \-- deferred-and-monitoring.md   # active: deferred items, monitoring
\-- configs/
    |-- kbd.conf.reference           # reference copy of kbd conf
    \-- finances.conf.reference      # reference copy of finances conf
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
SYNC_LOG=.usb-sync.log

| Key on disk | Exported as | Type | Purpose |
|-------------|-------------|------|---------|
| `VERSION` | `USB_MANIFEST_VERSION` | integer | Format version for forward-compat |
| `LABEL` | `USB_LABEL` | string | Human-readable identifier, appears in logs |
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


### Sync Entry Format

Both `sync_file` and `sync_dir` entries use the same four-field format:

source:destination:condition

| Field | Type | Values | Notes |
|-------|------|--------|-------|
| `source` | string, path | May contain `{USB_ROOT}`, `{LOCAL_DIR}` tokens | File path or directory path |
| `destination` | string, path | May contain `{USB_ROOT}`, `{LOCAL_DIR}` tokens | File path or directory path |
| `condition` | string enum | `newer` | How to decide whether to copy. Extensible - add conditions as needed. |

Parsed via: `IFS=: read -r source destination condition <<< "$entry"`

**sync_file** (`newer` condition): copy if source file is newer than
destination (bash `-nt` test). Destination directory must exist.

**sync_dir** (`newer` condition): walk source tree via `find -type f`.
For each file, copy if newer than its destination counterpart. Top-level
destination directory must exist (setup error if missing). Subdirectories
within destination created as needed. Symlinks skipped with warning.
Destination paths validated to stay within the declared destination
directory.

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
| `USB_SCRIPT_PATH` | string, absolute path | Always (source time) |
| `USB_CONNECTED` | string: `true\|false` | Always |
| `USB_MOUNT_POINT` | string, absolute path | USB found |
| `USB_DRIVE_LETTER` | string, single letter | USB found, WSL only |
| `USB_ENV` | string: `wsl\|linux` | Always |
| `USB_LABEL` | string | USB found, from manifest |
| `USB_MANIFEST_VERSION` | integer | USB found, from manifest |
| `USB_SYNC_LOG` | string, absolute path | USB found, resolved from manifest |
| `USB_LOADED_PROJECTS` | bash indexed array | USB found, after LOAD |
| `USB_INITIALIZED` | `true` | After successful initialization |

`USB_SCRIPT_PATH` is used by `usb_refresh` to re-source the script.
`USB_DRIVE_LETTER` is used by `usb_eject` for the PowerShell eject verb.
`USB_INITIALIZED` is checked by module guards and by usb.sh itself to
prevent double-initialization.


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

## Startup Procedure


Linear, not wrapped in functions. Four sections delimited by comments.
Section order is FIND  LOAD  FUNCTIONS  SYNC. FUNCTIONS must precede
SYNC because the SYNC section calls `_usb_run_sync` at source time -
bash requires a function to be defined before the line that calls it.

### FIND

1. Set `USB_CONNECTED=false`, unset `USB_MOUNT_POINT`.
2. If `force` argument passed, delete cache file.
3. Detect environment  set `USB_ENV`.
4. **WSL fast path:** read the cached drive letter from `$USB_CACHE_FILE` (`${XDG_CACHE_HOME:-$HOME/.cache}/usb-sh/`). If the cached drive letter's mount point contains `.usb-manifest`, set `USB_MOUNT_POINT`, `USB_CONNECTED=true`.
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

For each project in `USB_LOADED_PROJECTS`, call `_usb_run_sync`, which:

1. Processes each `sync_file` entry:
   a. For each `sync_file` entry, parse `src:dest:condition`.
   b. If condition is `newer`, test `[[ "$src" -nt "$dest" ]]`. If true,
      `cp "$src" "$dest"`.
   c. Log the operation to `USB_SYNC_LOG`.
2. Processes each `sync_dir` entry:
   a. For each `sync_dir` entry, parse `src_dir:dest_dir:condition`.
   b. If condition is `newer`, walk source tree via `find -type f`, copy
      files newer than dest counterpart. Create subdirectories as needed.
   d. Log summary (copied count, error count) to `USB_SYNC_LOG`.

---

## Functions

All public functions support `-h`/`--help` for usage information.
Internal functions (underscore prefix) are not user-facing.

### `usb_verify_connected`

Check USB is still physically connected. Returns 0 if connected, 1 if
not. If `USB_CONNECTED` is true but the manifest file is no longer
accessible, updates `USB_CONNECTED` to false (stale state recovery).
Used internally by other `usb_` functions as a pre-flight check.


### usb_push <project|all>

Push local git repo to USB bare repo. Auto-commits uncommitted changes
with a timestamped message (project: sync YYYY-MM-DD.HHMM) -- for a
meaningful commit message, run git commit first. Uses git -C throughout
(does not change the working directory). Validates: project is loaded,
local dir is a git repo, bare repo exists on USB, branch is not detached.
With "all", iterates all loaded projects using skip-and-continue:
failures in one project do not stop others. Prints summary with
success/fail counts.

### usb_pull <project|all>

Pull from USB bare repo to local git repo. Refuses if uncommitted
changes exist -- commit or stash first. Uses git -C throughout.
Same validation sequence as usb_push. With "all", iterates all loaded
projects using skip-and-continue. Prints summary with success/fail
counts.

### `usb_init_bare <project>`

Create bare repo on USB for a loaded project. The project must have a
conf file and `local_dir` must be a git repo. Refuses if bare repo
already exists on USB. WSL: uses PowerShell git to create the bare repo
(avoids cross-filesystem issues with `git init --bare`), adds
`safe.directory`, pushes initial content. Linux: uses `git clone --bare`
(copies content in one step).

### `usb_clone_all`

Clone all bare repos from USB to local directories. For new machine
setup. Iterates `.usb-projects/*.conf` on USB, parses `local_dir` and
`repo_path`. Skips projects where `local_dir` already exists or bare
repo is missing on USB. Does NOT modify `USB_LOADED_PROJECTS` or export
variables - run `usb_refresh` after to reload. WSL: adds
`safe.directory` for each cloned repo.

### `usb_sync [project]`

Manually trigger file and directory sync. If project given, sync that
project only. Otherwise, sync all loaded projects. Calls
`_usb_run_sync` for the target project(s).

### `usb_eject`

1. Run sync entries for all loaded projects.
2. If current directory is under `USB_MOUNT_POINT`, `cd ~`.
3. Unmount `USB_MOUNT_POINT` if mounted.
4. **WSL only:** remove empty mount directory, PowerShell eject verb,
   verify drive is gone.
5. **State cleanup:** unset all `USB_${proj}_*` per-project variables,
   unset global USB variables, set `USB_CONNECTED=false`, unset
   `USB_INITIALIZED`, delete cache file.

Functions and the PS1 hook intentionally persist after eject (they are
not part of the drive-scope sweep), so `usb_refresh` still works while
the USB is disconnected.

### `usb_refresh`

Re-source usb.sh with `force` argument to bypass the drive cache. Uses
`USB_SCRIPT_PATH` (set at source time) to locate the script file.
Reports connection state after reload.

### `usb_status`

Print diagnostic information about USB state. Shows: connection state,
environment, mount point, drive letter (WSL), manifest version, label,
sync log path. For each loaded project: `local_dir`,
`repo_path`, sync_files count, sync_dirs count. Safe to call regardless
of connection state - prints minimal info when disconnected.


### usb_check
Validate conf files, check all referenced paths, and detect config drift.
Re-reads and parses conf files independently (same while-read pattern as
LOAD -- does not use cached variables). Checks performed per project:
local_dir present and directory exists, repo_path present and bare repo
exists on USB, branch consistency (local HEAD matches bare repo HEAD),
each sync_file source file exists and dest directory exists, each
sync_dir source directory and dest directory exist. After per-project
checks, compares configs/*.conf.reference against live USB copies and
.usb-manifest.reference against the live manifest using cmp. Reports
all issues. Returns non-zero if any check fails.

### `usb_ps1_indicator`

PS1 rendering helper. Returns `usb[O]` when USB is connected, `usb[ ]`
when not. Called via `$()` substitution in the prompt string - not a
user command. Does not support `-h` (runs on every prompt render and
must be zero-overhead).

usb.sh integrates this into the prompt via `MC_PS1` at the end of
startup. The contains-check prevents duplicate prepending on
`usb_refresh`.

### `usb_new_project <name>`

Create new project conf via editor. Name must be a valid bash identifier
component: starts with a lowercase letter, contains only lowercase
letters, digits, and underscores (becomes part of `USB_<NAME>_*`
variable names). Writes a scaffold to `.usb-projects/<name>.conf.tmp`
on USB, opens `$EDITOR`, validates required keys (`local_dir`,
`repo_path`) after editor exits. Atomic move from `.tmp` to `.conf` on
success. Run `usb_refresh` to load the new project.

### `_usb_run_sync <project_name>`

Internal. Executes all `sync_file` entries (individual file copies) and
then all `sync_dir` entries (directory tree walks) for one project. Every
call runs all of the project's entries unconditionally. It is invoked from
three contexts: at source time for each loaded project (startup), from
`usb_sync`, and from `usb_eject` before unmount.

For each `sync_file` entry: parse `source:dest:condition`. For the `newer`
condition, copy only when the source is newer than the dest (`-nt`, which
also copies when the dest is missing); otherwise skip. Copies and errors
are logged to `USB_SYNC_LOG`.

For each `sync_dir` entry: parse `source_dir:dest_dir:condition`. For
`newer`, walk the source tree via `find -type f`, copy files newer than
their dest counterpart, and create subdirectories within `dest_dir` as
needed (top-level `dest_dir` must exist). Dest paths are validated to stay
within the declared `dest_dir`; symlinks are skipped with a count and
warning. A per-entry summary (copied count, error count) is logged.

Per-project arrays are read via a `declare -n` nameref.

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

## Invariants and Guards

This registry is the single source of truth for the assumptions usb.sh
relies on and where each is defended. Guard types:

- **enforced** - code actively rejects or corrects a violation at runtime.
- **checked** - `usb_check` (or an audit) reports a violation but does not
  block; the operator acts on it.
- **documented-only** - relied upon but not verified in code. When accepted
  as a known gap, the row is tagged `UNGUARDED: accepted because ...`.

Rule: any commit that introduces a new assumption adds a row here in the
same commit. Rows for assumptions introduced by later refactor commits land
with those commits, not in advance.

| Assumption | Guard location | Guard type |
|---|---|---|
| bash >= 4.3 (namerefs, `${var^^}`) | startup version check near top of usb.sh | enforced |
| Secrets decrypted via `/dev/shm` + gpg loopback; `~/.gnupg` perms sane | keys init/load paths | enforced |
| `MC_WINDOWS_USER` names the Windows user; `$USER` is the fallback | detection/env setup, with a warning when the fallback is taken | documented + warned |
| Loaded API keys are visible to child-process environments | keys load path | documented-only; UNGUARDED: accepted because keys are meant to reach child tools (git, CLIs) |
| Editor invoked on decrypted keys must not leak plaintext to persistent tmp | editor-safety audit around `usb_edit_keys` | checked |
| Every public `usb_*` function has a `-h` heredoc whose first line is `<funcname> - ...` | `dev/docs-sync.sh --check` (run by the pre-commit hook) errors on any missing heredoc, wrong first-line format, or name mismatch | checked |
| Loaded-keys bookkeeping survives `usb_refresh` (force re-source) | conditional top-level init of `USB_KEYS_LOADED` / `_USB_LOADED_KEY_NAMES` | enforced |
| Secret values preserve a trailing `=` (base64 padding) on load | first-`=` expansion split at the three keys parse sites (init/edit/load) | enforced |
| Every eject exit leaves only machine-scope globals; drive-scope state is swept in exactly one place | `_usb_clear_state`, called from all three `usb_eject` exit paths | enforced |
| Filesystem write buffers are flushed before unmount (drvfs/VFAT write-cache risk on removable media) | `sync` between cwd-escape and umount in `usb_eject` | documented-only |
| Bare-repo divergence is rejected without data loss; reconciliation is explicit | plain (non-force) `git push` non-fast-forward refusal in `usb_push`; `usb_pull` uses `--rebase` | enforced (by git) |
| Conf and manifest values preserve a trailing `=`; keys match a fixed whitelist | first-`=` expansion split + key regex (`^[a-z][a-z0-9_]*$` conf, `^[A-Z][A-Z0-9_]*$` manifest) at all six non-secret parse sites | enforced |
| Sync entries are `src:dest:condition` only; a 4th (phase) field is invalid | phase model excised from parser/template/docs; `usb_check` warns on any extra field | enforced (check) |
| PowerShell interop reports honest exit codes and cannot hang the shell indefinitely | `_usb_ps` wrapper: `$ErrorActionPreference='Stop'` + try/catch (PS-side errors -> rc 1), native callers append `; exit $LASTEXITCODE`, `timeout 10` maps interop hang -> rc 124 | enforced |
| At most one manifest-bearing WSL volume; ambiguity is never resolved by guessing | detection counts drive letters returned by `_usb_ps`; more than one aborts the source with an error, one per line (decision 5) | enforced |
| Drive-letter cache lives under a per-user XDG path, not a predictable world-readable `/tmp` location | `USB_CACHE_FILE` = `${XDG_CACHE_HOME:-$HOME/.cache}/usb-sh/drive_letter`; parent dir created before the write | enforced |
| Stale `safe.directory` entries for a repo under a prior mount are removed when it remounts elsewhere | `_usb_ensure_safe_directory` strips the mount prefix for WSL (`/mnt/*/`) and udisks (`/media/*/*/`, `/run/media/*/*/`), then unsets entries sharing the repo suffix but a different full path | enforced |
| Keys section is a self-contained module: its only external inputs are USB_MOUNT_POINT (read exactly once, to derive USB_KEYS_FILE) and usb_verify_connected; keys state is declared and owned within the section | KEYS header documents the contract; USB_KEYS_FILE derived once at the section head and swept as drive-scope in _usb_clear_state; the single USB_MOUNT_POINT read is grep-assertable | documented |
| Diagnostics go to stderr and data to stdout: non-data messages emit via _usb_msg / _usb_warn / _usb_err (all stderr); usb_status, usb_keys_status, usb_ps1_indicator, and captured-stdout helpers write data to stdout | emitters defined just after the version check; all non-data usb: / usb[WARN]: / usb[ERROR]: messages route through them (a literal-tilde help set and the usb[ps]: interop lines are documented exceptions) | convention + emitters |

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

## Implementation Notes

### Array Write: eval + printf %q in LOAD

Bash arrays cannot be exported via the `export` builtin - only scalar
variables can be exported to the environment. Per-project arrays are
assigned into the global scope using eval with printf %q quoting:

```bash
eval "USB_$${upper}_SYNC_FILES=($$(printf '%q ' "${entries[@]}"))"
```
printf %q quotes each entry safely, handling paths with spaces or special
characters. No external dependencies.

Array Read: declare -n Nameref in Functions
Inside _usb_run_sync, the per-project
array is read via a declare -n nameref rather than eval-by-index:

```bash
declare -n usb_sync_files_array_ref="$usb_sync_files_variable_name"
```

Namerefs are cleaner than eval for reading and require bash 4.3+, which
is confirmed on the target system. Namerefs are used for reading only -
writing through a nameref to a dynamically-named global is less
predictable and is avoided.
