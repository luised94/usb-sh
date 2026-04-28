> **Status: All phases completed.** Implementation diverged from this plan in several areas - see [deferred-and-monitoring.md](deferred-and-monitoring.md) for ongoing tracking.

# usb.sh - Implementation Plan

Work phase by phase. Verify each phase before proceeding. Each commit is atomic - one logical change, system does not break.

---

## Phase 1: USB File Structure

Prepare the USB itself. No code yet - just files on the drive.

**Commit 1.1 - Create `.usb-manifest` on USB root.**
Write the file with: `USB_MANIFEST_VERSION=1`, `USB_LABEL="luised94-usb"`, `USB_DEFAULT_PHASE="auto"`, `USB_SYNC_LOG=".usb-sync.log"`. Verify: open a shell, `source /mnt/<drive>/.usb-manifest`, confirm all four variables resolve.

**Commit 1.2 - Create `.usb-projects/kbd.conf` on USB.**
Create the `.usb-projects/` directory. Write `kbd.conf` with: `local_dir="$HOME/personal_repos/kbd"`, `repo_path="personal_repos/kbd.git"`, `sync_files=("{USB_ROOT}/shared/kbd_zotero_library.bib:{LOCAL_DIR}/zotero_library.bib:newer:auto")`, `sync_dirs=()`. Verify: `source` the file in a shell, confirm `local_dir`, `sync_files` are set.

**Commit 1.3 - Create `shared/` directory and move bib file.**
Create `shared/` at USB root. Copy `zotero_library.bib` from USB root to `shared/kbd_zotero_library.bib`. Keep the original in place temporarily (kbd.sh still references it). Remove original only after Phase 6 is verified.

**Verification gate:** `.usb-manifest` and `.usb-projects/kbd.conf` both source cleanly. `shared/kbd_zotero_library.bib` exists.

Note: Phase 1 commits are USB filesystem operations, not git commits. They're listed here for tracking. Git commits begin in Phase 2.

---

## Phase 2: Repository Setup

Initialize the usb-sh repo locally. Skeleton only - no functional code yet.

**Commit 2.1 - Init repo with usb.sh skeleton.**
`git init ~/personal_repos/usb-sh`. Create `usb.sh` containing: file header comment, schema comment block listing all exported variables (copy from design doc Variable Namespace section), empty FIND/LOAD/SYNC phase sections delimited by comments, empty function stubs for `usb_sync` and `usb_eject`. The script should be sourceable without error and without side effects. Commit message: `init: usb.sh skeleton with schema and phase structure`.

**Commit 2.2 - Add documentation.**
Create `docs/design.md` (the design document). Create `docs/usb-setup.md` containing reference copies of `.usb-manifest` content and `kbd.conf` content, plus the USB directory structure diagram. Create `README.md` with a one-paragraph description and pointer to docs. Commit message: `docs: design doc, usb-setup reference, README`.

**Commit 2.3 - Create symlink.**
Symlink `~/.config/mc_extensions/usb.sh`  `~/personal_repos/usb-sh/usb.sh`. This is a filesystem operation, not committed to usb-sh. If mc_extensions is tracked by your config repo, commit the symlink there.

**Verification gate:** `source ~/.config/mc_extensions/usb.sh` runs without error. No variables exported (skeleton is inert).

---

## Phase 3: FIND Phase

USB detection logic. Transplanted from `kbd.sh` with marker name and variable names changed.

**Commit 3.1 - Environment detection and variable initialization.**
At top of FIND section: set `USB_CONNECTED=false`, `unset USB_MOUNT_POINT`. Handle `force` argument: `[[ "$1" == "force" ]] && rm -f "$CACHE_FILE"`. Detect WSL vs Linux, set `USB_ENV`. Cache file path: `CACHE_FILE="/tmp/usb_drive_cache"`. Commit message: `find: environment detection and state init`.

**Commit 3.2 - WSL fast path.**
Read `$CACHE_FILE`. If cached drive letter exists, construct mount point, test for `.usb-manifest`. If found: set `USB_MOUNT_POINT`, `USB_CONNECTED=true`. If stale: delete cache, fall through. Commit message: `find: WSL fast path via cache`.

**Commit 3.3 - WSL slow path.**
PowerShell `Get-Volume` scan looking for `.usb-manifest` (not `.kbd-usb-marker`). If found: set drive letter, mount point, `USB_CONNECTED=true`, write cache. Mount logic: `mkdir -p`, `mount -t drvfs` with metadata option, error handling. Commit message: `find: WSL slow path via PowerShell`.

**Commit 3.4 - Linux path scan.**
Loop over `/mnt/*`, `/media/$USER/*`, `/run/media/$USER/*`. Test each for `.usb-manifest`. If found: set `USB_MOUNT_POINT`, `USB_CONNECTED=true`, break. Commit message: `find: Linux path scan`.

**Verification gate:** Source `usb.sh` with USB plugged in - `USB_CONNECTED=true`, `USB_MOUNT_POINT` set correctly. Source with USB unplugged - `USB_CONNECTED=false`. Test cache: source again, confirm fast path hits. Run with `force` argument, confirm slow path runs.

---

## Phase 4: LOAD Phase

Conf loading and variable export. Depends on FIND having set `USB_CONNECTED=true`.

**Commit 4.1 - Source manifest and set global config.**
Guard: `[[ "$USB_CONNECTED" != true ]] && return` (or skip block). Source `$USB_MOUNT_POINT/.usb-manifest`. Resolve `USB_SYNC_LOG` to absolute path: `USB_SYNC_LOG="$USB_MOUNT_POINT/$USB_SYNC_LOG"`. Initialize `USB_LOADED_PROJECTS=()`. Commit message: `load: source manifest and init globals`.

**Commit 4.2 - Project conf loading loop.**
`for conf_file in "$USB_MOUNT_POINT/.usb-projects/"*.conf; do`. Extract project name: `name=$(basename "$conf_file" .conf)`. Source conf file. Validate `local_dir` - if directory doesn't exist, echo warning with project name and `continue`. Uppercase: `proj_upper="${name^^}"`. Commit message: `load: conf discovery and validation loop`.

**Commit 4.3 - Token resolution and variable export.**
Inside the loop body after validation: iterate `sync_files` array, resolve `{USB_ROOT}` and `{LOCAL_DIR}` tokens via bash parameter expansion into a new resolved array. Export `USB_${proj_upper}_LOCAL_DIR`, `USB_${proj_upper}_REPO_PATH`, `USB_${proj_upper}_SYNC_FILES` (resolved), `USB_${proj_upper}_SYNC_DIRS` (resolved). Append `$name` to `USB_LOADED_PROJECTS`. Use `declare -n` (nameref) or `eval "export USB_${proj_upper}_LOCAL_DIR=..."` - pick one approach and be consistent. `eval` is acceptable here because the variable name is constructed from a filename you control, not user input. Echo summary: loaded project count and names. Commit message: `load: token resolution and variable export`.

**Verification gate:** Source `usb.sh`. Confirm `USB_KBD_LOCAL_DIR`, `USB_KBD_REPO_PATH`, `USB_KBD_SYNC_FILES` are set with correct resolved paths. Confirm `USB_LOADED_PROJECTS` contains `kbd`. Test with a second dummy conf pointing to a nonexistent `local_dir` - confirm warning, confirm it's skipped, confirm kbd still loads.

---

## Phase 5: SYNC Phase and Functions

File sync execution and the two user-facing functions.

**Commit 5.1 - Sync execution helper.**
Write a function `_usb_run_sync_files` that takes a project name and a trigger label (one of `startup`, `sync`, `eject`). It retrieves the project's `SYNC_FILES` array, parses each entry, checks if the entry's phase matches the trigger (startup runs `auto`+`always`; sync runs `manual`+`always`; eject runs `auto`+`always`), applies the condition test, copies if met, and appends a timestamped line to `$USB_SYNC_LOG`. This is the only place sync execution logic lives. Commit message: `sync: file sync execution helper`.

Trigger-to-phase mapping implemented inside the helper:
```
startup  run if phase is auto or always
sync     run if phase is manual or always
eject    run if phase is auto or always
```

**Commit 5.2 - Startup SYNC invocation.**
In the SYNC section of the linear startup procedure: iterate `USB_LOADED_PROJECTS`, call `_usb_run_sync_files "$project" startup` for each. Commit message: `sync: run auto+always entries on startup`.

**Commit 5.3 - `usb_sync` function.**
If project argument given, validate it's in `USB_LOADED_PROJECTS` (error if not). Call `_usb_run_sync_files "$project" sync`. If no argument, iterate all loaded projects and call for each. Commit message: `func: usb_sync with optional project filter`.

**Commit 5.4 - `usb_eject` function.**
Step 1: iterate all loaded projects, call `_usb_run_sync_files "$project" eject`. Step 2: if `$PWD` is under `$USB_MOUNT_POINT`, `cd ~`. Step 3: unmount if mounted (`mountpoint -q` test, `sudo umount`, error handling with `lsof`). Step 4 (WSL only): `rmdir` empty mount point, PowerShell eject with `Shell.Application` COM, sleep + verify. Step 5: iterate `USB_LOADED_PROJECTS`, unset all `USB_${proj_upper}_*` variables for each project. Unset `USB_MOUNT_POINT`, `USB_LABEL`, `USB_SYNC_LOG`, `USB_LOADED_PROJECTS`. Set `USB_CONNECTED=false`. Delete `$CACHE_FILE`. Commit message: `func: usb_eject with pre-eject sync and full cleanup`.

**Commit 5.5 - `usb_refresh` function.**
Re-sources the entire `usb.sh` with `force` argument to bypass cache. Prints summary. Commit message: `func: usb_refresh for re-detection`.

**Verification gate:** Source `usb.sh`, confirm bib syncs on startup (if USB version is newer). Place a test file in `shared/`, add a temporary sync_files entry in kbd.conf pointing to it, run `usb_sync kbd`, confirm it copies. Run `usb_eject`, confirm all `USB_*` variables are cleaned. Re-plug, run `usb_refresh`, confirm detection works.

---

## Phase 6: kbd.sh Refactor

Migrate kbd.sh to source usb.sh and strip USB infrastructure. kbd.sh remains functional throughout - the old code is removed only after the new path is verified.

**Commit 6.1 - Add `source usb.sh` and parallel variable setup.**
At top of kbd.sh, add `source "$HOME/.config/mc_extensions/usb.sh"`. Below existing USB detection block, add: `KBD_DIR="${USB_KBD_LOCAL_DIR:-$HOME/personal_repos/kbd}"`. Do NOT remove old detection yet. Both paths coexist. Verify: source kbd.sh, confirm both old (`KBD_USB_CONNECTED`) and new (`USB_CONNECTED`) variables are set. Commit message: `kbd: source usb.sh alongside existing detection`.

**Commit 6.2 - Migrate aliases to use `KBD_DIR`.**
Change alias definitions from `$KBD_LOCAL_DIR` to `$KBD_DIR`. `KBD_DIR` falls back to the hardcoded path if USB isn't connected (via the `:-` default). Verify: aliases still work with and without USB. Commit message: `kbd: aliases use KBD_DIR from usb.sh`.

**Commit 6.3 - Rewrite `kpull`.**
New implementation: guard on `USB_CONNECTED`, `cd` to `KBD_DIR`, git pull using `USB_KBD_REPO_PATH` for the remote, then `usb_sync kbd`. Remove the old bib sync logic from kpull - it's now handled by the sync_files entry. Remove the old remote validation block - re-implement using `USB_KBD_REPO_PATH` if needed. Verify: `kpull` fetches from USB repo and syncs bib. Commit message: `kbd: rewrite kpull to use usb_sync`.

**Commit 6.4 - Rewrite `ksync`.**
New implementation: guard on `USB_CONNECTED`, `cd` to `KBD_DIR`, git add/commit/push, then `usb_sync kbd`. This fixes the bib sync inconsistency - ksync now runs sync_files via usb_sync. Verify: edit a file, `ksync`, confirm git push works and sync_files execute. Commit message: `kbd: rewrite ksync to use usb_sync`.

**Commit 6.5 - Update `kbib_sync` destination path.**
Change the destination from `$KBD_MOUNT_POINT/zotero_library.bib` to `$USB_MOUNT_POINT/shared/kbd_zotero_library.bib`. Update the source variable references if needed. Verify: run `kbib_sync`, confirm file lands in `shared/`. Commit message: `kbd: kbib_sync targets shared/kbd_zotero_library.bib`.

**Commit 6.6 - Replace `kusboff` with `usb_eject`.**
Remove `kusboff` function. Add `alias kusboff=usb_eject` if you want backward compat, or just drop the old name. Verify: `usb_eject` unmounts, ejects, cleans state. Commit message: `kbd: replace kusboff with usb_eject`.

**Commit 6.7 - Replace PS1 indicator.**
Remove `kbd_usb_indicator`. Add `kbd_origin_indicator`: returns `kbd[O]` if `USB_CONNECTED == true`, `kbd[ ]` otherwise. Update `MC_PS1` construction to use the new function. Verify: prompt shows correct indicator. Commit message: `kbd: origin indicator reads USB_CONNECTED`.

**Commit 6.8 - Strip old USB detection logic.**
Remove the entire FIND block (WSL fast path, slow path, Linux scan, marker variable, cache variable). Remove old Phase 2 execution block (bib sync, `KBD_ORIGIN_DIR` construction). Remove `KBD_USB_MARKER`, `KBD_USB_CONNECTED`, `KBD_MOUNT_POINT`, `KBD_USB_DRIVE`, `CACHE_FILE` declarations. Remove `kbd_refresh` - replaced by `usb_refresh` from usb.sh (or add `alias kbd_refresh=usb_refresh`). Verify: source kbd.sh cleanly. Full workflow: startup detection, kpull, edit, ksync, usb_eject. Commit message: `kbd: remove legacy USB detection - usb.sh owns this now`.

**Commit 6.9 - Clean up old bib file on USB.**
Remove `USB_ROOT/zotero_library.bib` (the original at root). Only `shared/kbd_zotero_library.bib` remains. This is a USB filesystem operation, not a git commit. Verify: startup sync still works (conf points to `shared/`).

**Verification gate:** Full end-to-end test. Source kbd.sh in a fresh shell. USB detected. Bib syncs on startup. `kpull` works. Edit a file, `ksync` works. `kbib_sync` updates `shared/kbd_zotero_library.bib`. `usb_eject` cleans everything. Unplug, re-plug, `usb_refresh` re-detects.

---

## Phase 7: Documentation Finalization

**Commit 7.1 - Update `docs/usb-setup.md` with final conf content.**
Now that the refactor is verified, update the reference copies to match exactly what's on the USB. Commit message: `docs: finalize usb-setup reference copies`.

**Commit 7.2 - Add kbd-specific notes to design doc if needed.**
Any lessons learned or adjustments made during implementation. Commit message: `docs: post-implementation notes`.

---

## Summary

| Phase | Commits | Where |
|-------|---------|-------|
| 1. USB file structure | 1.1-1.3 | USB filesystem |
| 2. Repo setup | 2.1-2.3 | usb-sh repo |
| 3. FIND | 3.1-3.4 | usb-sh repo |
| 4. LOAD | 4.1-4.3 | usb-sh repo |
| 5. SYNC + functions | 5.1-5.5 | usb-sh repo |
| 6. kbd.sh refactor | 6.1-6.9 | kbd repo |
| 7. Documentation | 7.1-7.2 | usb-sh repo |

Total: 24 atomic steps across 7 phases. kbd.sh stays functional throughout - old code coexists with new until Phase 6 commit 6.8.
