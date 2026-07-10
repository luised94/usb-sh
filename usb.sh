#!/usr/bin/env bash
# usb.sh -- USB detection, project configuration, file synchronization, and shared functions.
# Source this file. Do not execute directly.
# Sourced once by .bashrc. Exports USB_* variables that project modules read.
# Project modules do not source this file; they are sourced separately by .bashrc.
# Note: FUNCTIONS section must precede SYNC section because SYNC calls
# _usb_run_sync at source time.
#
# Usage:
#   source /path/to/usb.sh [force]
#   force -- bypass cache and re-run USB detection
#
# =============================================================================
# EXPORTED VARIABLE SCHEMA
# =============================================================================
#
# Global variables set during startup:
#
#   USB_SCRIPT_PATH      -- absolute path to this file, set at source time
#   USB_CONNECTED        -- "true" or "false"
#   USB_MOUNT_POINT      -- absolute path to USB mount point, set if USB found
#   USB_ENV              -- "wsl" or "linux"
#   USB_LABEL            -- human-readable USB label, from .usb-manifest
#   USB_MANIFEST_VERSION -- integer format version, from .usb-manifest
#   USB_SYNC_LOG         -- absolute path to sync log file, from .usb-manifest
#   USB_LOADED_PROJECTS  -- indexed array of loaded project names
#   USB_DRIVE_LETTER     -- Windows drive letter for WSL eject, set if USB found on WSL
#   USB_INITIALIZED      -- "true" after successful init, checked by module guards
#
# Per-project variables set during LOAD phase.
# Replace KBD with the uppercased project name (e.g. FINANCES, SM2).
#
#   USB_KBD_LOCAL_DIR    -- absolute path to local project directory
#   USB_KBD_REPO_PATH    -- relative path to bare git repo on USB, metadata only
#   USB_KBD_SYNC_FILES   -- indexed array of resolved sync_files entries
#   USB_KBD_SYNC_DIRS    -- indexed array of resolved sync_dirs entries
#
# sync_files entry format: src:dest:condition
#   condition -- "newer" (copy if src is newer than dest) or
#                "differs" (copy if src and dest differ, cmp -s)
# Make new git repo:
# Connect the appropriate usb (with the file marker) and source this file.
#   1) Create the directory for the new git repo and initialize. Use mkdir and git init or via the code module's own logic.
#   2) Run usb_new_project <module_name>. Remove boiler plate comments and confirm locations are correct.
#   3) Run usb_refresh function. The project should show up as loaded.
#   4) Run usb_init_bare function. Should initialize the bare git repo and push the commit.
#   5) Test usb_pull, usb_push and usb_commit
#   6) Use as intended. Sync using the usb functions only.
# NOTES: Each commit is ammended since git is mostly used for per day history and multi-machine syncing, not per-operation due to the types of repos that are usually synced via the usb.
#
# =============================================================================

if [[ "${BASH_VERSINFO[0]}" -lt 4 || ( "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -lt 3 ) ]]; then
    echo "usb[ERROR]: bash 4.3+ required (found ${BASH_VERSION})"
    return 1 2>/dev/null || exit 1
fi

# Diagnostic emitters (commit 13): stdout is data, stderr is diagnostics.
# Non-data "usb: ..." / "usb[WARN]: ..." / "usb[ERROR]: ..." messages route
# through these. Data producers (usb_status, usb_keys_status, usb_ps1_indicator,
# and captured-stdout helpers) keep writing to stdout directly. See the
# stdout-is-data contract row in docs/design.md.
_usb_msg()  { echo "usb: $*" >&2; }
_usb_warn() { echo "usb[WARN]: $*" >&2; }
_usb_err()  { echo "usb[ERROR]: $*" >&2; }

USB_SCRIPT_PATH="${BASH_SOURCE[0]}"
if [[ "$USB_INITIALIZED" == true && "$1" != "force" ]]; then
    _usb_warn "already initialized (connected=$USB_CONNECTED, source=$(caller 0 2>/dev/null || echo unknown))"
    _usb_warn "usb.sh should be sourced once from bash/06_usb.sh, use 'force' to re-run"
    return 0
fi

# =============================================================================
# FIND -- USB hardware detection
# Sets: USB_CONNECTED, USB_MOUNT_POINT, USB_ENV, USB_DRIVE_LETTER
# =============================================================================

USB_CACHE_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/usb-sh/drive_letter"
USB_MANIFEST_FILENAME=".usb-manifest"
# Machine-scope tunable: a "differs" entry whose source exceeds this many bytes
# draws a usb_check advisory, since differs runs a full cmp on every sync.
# Default 10 MiB; override by setting USB_DIFFERS_SIZE_WARN before sourcing.
USB_DIFFERS_SIZE_WARN="${USB_DIFFERS_SIZE_WARN:-10485760}"
export USB_CONNECTED=false
unset USB_MOUNT_POINT
unset USB_DRIVE_LETTER

# _USB_PS_AVAILABLE (machine-scope): is Windows PowerShell interop present?
# Memoized once per source and gated on by _usb_ps and its WSL callers.
# Machine-scope: NOT swept by _usb_clear_state -- interop availability is a
# property of the host, not the mounted drive.
_USB_PS_AVAILABLE=false
command -v powershell.exe >/dev/null 2>&1 && _USB_PS_AVAILABLE=true

# _usb_ps -- run a PowerShell script with honest exit codes.
# stdout: command output, CRLF-stripped. stderr: diagnostics on failure.
# rc: 0 success; 1 PS-side failure; 124 interop hang (timeout);
#     127 powershell.exe unavailable.
# Callers running native commands (git) must append '; exit $LASTEXITCODE'
# to their script argument.
_usb_ps() {
    local _usb_ps_script="$1" _usb_ps_out _usb_ps_rc
    if [[ "$_USB_PS_AVAILABLE" != true ]]; then
        echo "usb[ps]: powershell.exe not available" >&2
        return 127
    fi
    # cd is subshell-scoped (inside $()): caller cwd untouched, no
    # cd-back needed. /mnt/c avoids the UNC-path interop warning.
    _usb_ps_out=$(cd /mnt/c 2>/dev/null || cd /; timeout 10 \
        powershell.exe -NoProfile -NonInteractive -Command \
        "\$ErrorActionPreference='Stop'; try { $_usb_ps_script } catch { [Console]::Error.WriteLine(\$_); exit 1 }" \
        2>&1)
    _usb_ps_rc=$?
    _usb_ps_out=${_usb_ps_out//$'\r'/}
    if [[ $_usb_ps_rc -eq 124 ]]; then
        echo "usb[ps]: Windows interop not responding (timeout)" >&2
        return 124
    fi
    if [[ $_usb_ps_rc -ne 0 ]]; then
        echo "usb[ps]: failed (rc=$_usb_ps_rc): $_usb_ps_out" >&2
        return "$_usb_ps_rc"
    fi
    printf '%s\n' "$_usb_ps_out"
    return 0
}

if [[ "$1" == "force" ]]; then
    rm -f "$USB_CACHE_FILE"
fi

if [[ -n "$WSL_DISTRO_NAME" ]]; then
    export USB_ENV="wsl"
else
    export USB_ENV="linux"
fi


if [[ "$USB_ENV" == "wsl" ]]; then

    if [[ -f "$USB_CACHE_FILE" ]]; then
        _usb_msg "cache hit  $USB_CACHE_FILE"
        USB_CACHED_DRIVE_LETTER=$(cat "$USB_CACHE_FILE")
        USB_POTENTIAL_MOUNT_POINT="/mnt/${USB_CACHED_DRIVE_LETTER,,}"

        if [[ -f "$USB_POTENTIAL_MOUNT_POINT/$USB_MANIFEST_FILENAME" ]]; then
            export USB_DRIVE_LETTER="$USB_CACHED_DRIVE_LETTER"
            export USB_MOUNT_POINT="$USB_POTENTIAL_MOUNT_POINT"
            export USB_CONNECTED=true

        else

            _usb_warn "cache stale, removing"
            rm -f "$USB_CACHE_FILE"
        fi
    fi

    if [[ "$USB_CONNECTED" == false ]]; then
        if [[ "$_USB_PS_AVAILABLE" == true ]]; then
            # Intentional quote-break: splicing $USB_MANIFEST_FILENAME into single-quoted PowerShell block
            # shellcheck disable=SC2016,SC1003
            USB_DETECTED_DRIVE_LETTER=$(_usb_ps '
                Get-Volume | Where-Object {
                  $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\'"$USB_MANIFEST_FILENAME"'")
                } | Select-Object -ExpandProperty DriveLetter
            ')

            # Multi-volume hard error (decision 5): more than one manifest-bearing
            # volume means we cannot know which to mount. This runs at source time,
            # so returning here aborts the source; the user removes a drive and
            # re-sources. A _usb_ps failure yields an empty result and falls through
            # (USB stays disconnected), preserving the prior best-effort behavior.
            USB_DETECTED_DRIVE_LETTER=$(printf '%s\n' "$USB_DETECTED_DRIVE_LETTER" | sed '/^$/d')
            if [[ $(printf '%s\n' "$USB_DETECTED_DRIVE_LETTER" | wc -l) -gt 1 ]]; then
                _usb_err "multiple manifest-bearing volumes detected:"
                printf '%s\n' "$USB_DETECTED_DRIVE_LETTER" >&2
                _usb_err "refusing to guess; remove one and re-source"
                return 1
            fi

            if [[ -n "$USB_DETECTED_DRIVE_LETTER" ]]; then
                export USB_DRIVE_LETTER="$USB_DETECTED_DRIVE_LETTER"
                export USB_MOUNT_POINT="/mnt/${USB_DETECTED_DRIVE_LETTER,,}"
                mkdir -p "${USB_CACHE_FILE%/*}" 2>/dev/null
                echo "$USB_DETECTED_DRIVE_LETTER" > "$USB_CACHE_FILE"

                if [[ ! -d "$USB_MOUNT_POINT" ]]; then
                    _usb_msg "mkdir ${USB_MOUNT_POINT}: requires sudo..."
                    sudo mkdir -p "$USB_MOUNT_POINT"
                fi

                if [[ ! -f "$USB_MOUNT_POINT/$USB_MANIFEST_FILENAME" ]]; then
                    _usb_msg "mounting ${USB_DETECTED_DRIVE_LETTER}: ..."
                    if sudo mount -t drvfs "${USB_DETECTED_DRIVE_LETTER}:" "$USB_MOUNT_POINT" -o metadata; then
                        export USB_CONNECTED=true
                    else
                        _usb_err "mount failed"
                        unset USB_MOUNT_POINT
                        unset USB_DRIVE_LETTER
                        rm -f "$USB_CACHE_FILE"
                    fi
                else
                    export USB_CONNECTED=true
                fi
            fi
        fi
    fi
else

    for usb_candidate_path in /mnt/* /media/"$USER"/* /run/media/"$USER"/*; do
        if [[ -f "$usb_candidate_path/$USB_MANIFEST_FILENAME" ]]; then
            export USB_MOUNT_POINT="$usb_candidate_path"
            export USB_CONNECTED=true
            _usb_msg "USB connected at $USB_MOUNT_POINT"
            break
        fi
    done

fi
# Resolve Windows username for cross-platform sync paths.
# Source: MC_WINDOWS_USER from my_config repo (expected interface).
# Fallback: current $USER (works on single-user WSL setups).
# Non-WSL machines: variable is set but unused (sync entries referencing
# Windows paths will skip naturally via -nt check on missing source).
if [[ -n "${MC_WINDOWS_USER:-}" ]]; then
    USB_WINDOWS_USER="$MC_WINDOWS_USER"
elif [[ -n "${USER:-}" ]]; then
    _usb_warn "MC_WINDOWS_USER not set, falling back to \$USER ('$USER')"
    _usb_warn "set MC_WINDOWS_USER in my_config if this is incorrect"
    USB_WINDOWS_USER="$USER"
else
    _usb_warn "MC_WINDOWS_USER and USER both unset, Windows sync paths will fail"
    USB_WINDOWS_USER=""
fi
export USB_WINDOWS_USER

# =============================================================================
# LOAD -- Parse .usb-manifest and .usb-projects/*.conf
# Requires: USB_CONNECTED=true
# Sets: USB_LABEL, USB_MANIFEST_VERSION, USB_SYNC_LOG,
#       USB_LOADED_PROJECTS, USB_<PROJECT>_* per loaded project
# =============================================================================
if [[ "$USB_CONNECTED" == true ]]; then

    # Parse .usb-manifest as plain key-value data. File is not sourced.
    # Expected format: KEY=value, one per line. No quotes or brackets. Comments (#) and blank lines skipped.
    while IFS= read -r usb_manifest_line; do
        usb_manifest_line="${usb_manifest_line%$'\r'}"
        if [[ -z "$usb_manifest_line" || "$usb_manifest_line" == \#* ]]; then
            continue
        fi
        if [[ "$usb_manifest_line" != *=* ]]; then
            _usb_warn "skipping malformed manifest line (no '='): $usb_manifest_line"
            continue
        fi
        usb_manifest_key="${usb_manifest_line%%=*}"
        usb_manifest_value="${usb_manifest_line#*=}"
        if [[ ! "$usb_manifest_key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            _usb_warn "skipping invalid manifest key: $usb_manifest_key"
            continue
        fi
        case "$usb_manifest_key" in
            VERSION)       USB_MANIFEST_VERSION="$usb_manifest_value" ;;
            LABEL)         USB_LABEL="$usb_manifest_value" ;;
            SYNC_LOG)      USB_SYNC_LOG="$USB_MOUNT_POINT/$usb_manifest_value" ;;
            *)             echo "usb[WARN]: unknown manifest key: $usb_manifest_key" ;;
        esac
    done < "$USB_MOUNT_POINT/$USB_MANIFEST_FILENAME"
    unset usb_manifest_key
    unset usb_manifest_value
    unset usb_manifest_line
    if [[ -z "$USB_LABEL" || -z "$USB_MANIFEST_VERSION" ]]; then
        _usb_err "manifest missing required keys (LABEL, VERSION)"
        export USB_CONNECTED=false
        return 1
    fi

    export USB_MANIFEST_VERSION
    export USB_LABEL
    export USB_SYNC_LOG

    USB_LOADED_PROJECTS=()

    for usb_conf_file_path in "$USB_MOUNT_POINT/.usb-projects/"*.conf; do

        if [[ ! -f "$usb_conf_file_path" ]]; then
            break
        fi

        usb_parsed_local_dir=""
        usb_parsed_repo_path=""
        usb_parsed_sync_files=()
        usb_parsed_sync_dirs=()

        usb_project_name=$(basename "$usb_conf_file_path" .conf)

        # Parse conf as plain key-value data. File is not sourced.
        # Token {HOME} is replaced with the runtime value of $HOME during parsing.
        # Tokens {USB_ROOT} and {LOCAL_DIR} are resolved after the loop
        # once local_dir is known.
        while IFS= read -r usb_conf_line; do
            usb_conf_line="${usb_conf_line%$'\r'}"
            if [[ -z "$usb_conf_line" || "$usb_conf_line" == \#* ]]; then
                continue
            fi
            if [[ "$usb_conf_line" != *=* ]]; then
                _usb_warn "conf '$usb_project_name' skipping malformed line (no '='): $usb_conf_line"
                continue
            fi
            usb_conf_key="${usb_conf_line%%=*}"
            usb_conf_value="${usb_conf_line#*=}"
            if [[ ! "$usb_conf_key" =~ ^[a-z][a-z0-9_]*$ ]]; then
                _usb_warn "conf '$usb_project_name' skipping invalid key: $usb_conf_key"
                continue
            fi
            case "$usb_conf_key" in
                local_dir)
                    usb_parsed_local_dir="${usb_conf_value//\{HOME\}/$HOME}"
                    usb_parsed_local_dir="${usb_parsed_local_dir//\{WINDOWS_USER\}/$USB_WINDOWS_USER}"
                    ;;
                repo_path)
                    usb_parsed_repo_path="$usb_conf_value"
                    ;;
                sync_file)
                    usb_parsed_sync_files+=("$usb_conf_value")
                    ;;
                sync_dir)
                    usb_parsed_sync_dirs+=("$usb_conf_value")
                    ;;
                *)
                    _usb_warn "conf '$usb_project_name' unknown key: $usb_conf_key"
                    ;;
            esac
        done < "$usb_conf_file_path"

        if [[ -z "$usb_parsed_local_dir" ]]; then
            _usb_err "conf '$usb_project_name' missing required key: local_dir"
            continue
        fi
        if [[ -z "$usb_parsed_repo_path" ]]; then
            _usb_err "conf '$usb_project_name' missing required key: repo_path"
            continue
        fi

        if [[ ! -d "$usb_parsed_local_dir" ]]; then
            _usb_warn "project '$usb_project_name' not cloned locally, run usb_clone_all"
            continue
        fi

        usb_project_name_upper="${usb_project_name^^}"


        # Resolve {USB_ROOT}, {LOCAL_DIR}, and {WINDOWS_USER} tokens in sync_file entries
        USB_RESOLVED_SYNC_FILES=()
        for usb_raw_sync_entry in "${usb_parsed_sync_files[@]}"; do
            usb_raw_sync_entry="${usb_raw_sync_entry//\{USB_ROOT\}/$USB_MOUNT_POINT}"
            usb_raw_sync_entry="${usb_raw_sync_entry//\{LOCAL_DIR\}/$usb_parsed_local_dir}"
            usb_raw_sync_entry="${usb_raw_sync_entry//\{WINDOWS_USER\}/$USB_WINDOWS_USER}"
            USB_RESOLVED_SYNC_FILES+=("$usb_raw_sync_entry")
        done

        # Resolve {USB_ROOT}, {LOCAL_DIR}, and {WINDOWS_USER} tokens in sync_dir entries
        USB_RESOLVED_SYNC_DIRS=()
        for usb_raw_sync_entry in "${usb_parsed_sync_dirs[@]}"; do
            usb_raw_sync_entry="${usb_raw_sync_entry//\{USB_ROOT\}/$USB_MOUNT_POINT}"
            usb_raw_sync_entry="${usb_raw_sync_entry//\{LOCAL_DIR\}/$usb_parsed_local_dir}"
            usb_raw_sync_entry="${usb_raw_sync_entry//\{WINDOWS_USER\}/$USB_WINDOWS_USER}"
            USB_RESOLVED_SYNC_DIRS+=("$usb_raw_sync_entry")
        done

        export "USB_${usb_project_name_upper}_LOCAL_DIR=$usb_parsed_local_dir"
        export "USB_${usb_project_name_upper}_REPO_PATH=$usb_parsed_repo_path"

        # Copy the resolved arrays into the per-project globals via namerefs.
        # A nameref assigns array elements directly, so entries containing spaces
        # or shell metacharacters need no quoting; this replaces the former
        # eval + printf %q string-building. (Arrays still cannot be export-ed
        # across subshells, but a nameref assignment in this top-level scope
        # creates the global array in place.)
        declare -n usb_sync_files_target="USB_${usb_project_name_upper}_SYNC_FILES"
        # shellcheck disable=SC2034  # nameref out-param: written through, not read here
        usb_sync_files_target=("${USB_RESOLVED_SYNC_FILES[@]}")
        unset -n usb_sync_files_target

        declare -n usb_sync_dirs_target="USB_${usb_project_name_upper}_SYNC_DIRS"
        # shellcheck disable=SC2034  # nameref out-param: written through, not read here
        usb_sync_dirs_target=("${USB_RESOLVED_SYNC_DIRS[@]}")
        unset -n usb_sync_dirs_target

        USB_LOADED_PROJECTS+=("$usb_project_name")
    done


    unset usb_parsed_local_dir
    unset usb_parsed_repo_path
    unset usb_parsed_sync_files
    unset usb_parsed_sync_dirs
    unset usb_conf_key
    unset usb_conf_value
    unset usb_conf_line
    unset usb_conf_file_path
    unset usb_project_name
    unset usb_project_name_upper
    unset USB_RESOLVED_SYNC_FILES
    unset USB_RESOLVED_SYNC_DIRS
    unset usb_raw_sync_entry

    _usb_msg "loaded ${#USB_LOADED_PROJECTS[@]} project(s): ${USB_LOADED_PROJECTS[*]}"

fi

# =============================================================================
# FUNCTIONS
# =============================================================================
# =============================================================
# _usb_ensure_safe_directory
# Ensures git safe.directory is set for a bare repo path at
# the current mount point. Removes stale entries for the same
# repo_path under different mount points (drive letter changed).
# Call from LOAD after projects are loaded, or after init_bare.
#
# Arguments:
#   bare_repo_path -- absolute path to bare repo (e.g. /mnt/d/repos/lab.git)
# =============================================================
_usb_ensure_safe_directory() {
    local usb_esd_bare_repo_path="$1"
    local usb_esd_repo_suffix
    local usb_esd_existing_entry
    local usb_esd_already_set

    if [[ -z "$usb_esd_bare_repo_path" ]]; then
        return 1
    fi

    # extract the repo-relative portion after the mount prefix for stale
    # detection. Three mount shapes: WSL /mnt/<letter>/, udisks
    # /media/<user>/<label>/, and /run/media/<user>/<label>/. Only the
    # matching prefix strips (the others are no-ops), so a drive that
    # remounts under any of these forms is still recognized as the same repo.
    # e.g. /mnt/d/repos/lab.git -> repos/lab.git
    usb_esd_repo_suffix="$usb_esd_bare_repo_path"
    usb_esd_repo_suffix="${usb_esd_repo_suffix#/mnt/*/}"
    usb_esd_repo_suffix="${usb_esd_repo_suffix#/media/*/*/}"
    usb_esd_repo_suffix="${usb_esd_repo_suffix#/run/media/*/*/}"

    # remove stale entries pointing to same repo under different mount
    while IFS= read -r usb_esd_existing_entry; do
        if [[ -z "$usb_esd_existing_entry" ]]; then
            continue
        fi
        # same suffix but different full path = stale
        if [[ "$usb_esd_existing_entry" == *"$usb_esd_repo_suffix" \
           && "$usb_esd_existing_entry" != "$usb_esd_bare_repo_path" ]]; then
            git config --global --unset-all safe.directory "$usb_esd_existing_entry" 2>/dev/null
        fi
    done < <(git config --global --get-all safe.directory 2>/dev/null)

    # check if current path already set
    usb_esd_already_set=false
    while IFS= read -r usb_esd_existing_entry; do
        if [[ "$usb_esd_existing_entry" == "$usb_esd_bare_repo_path" ]]; then
            usb_esd_already_set=true
            break
        fi
    done < <(git config --global --get-all safe.directory 2>/dev/null)

    if [[ "$usb_esd_already_set" == false ]]; then
        git config --global --add safe.directory "$usb_esd_bare_repo_path"
    fi
}

# =============================================================
# _usb_ensure_all_safe_directories
# Iterates loaded projects, ensures safe.directory for each.
# Call at end of LOAD, after all projects are loaded.
# @@TODO: Need to consolidate into the first one. Could use recursion.
# =============================================================
_usb_ensure_all_safe_directories() {
    local usb_easd_project_name
    local usb_easd_project_name_upper
    local usb_easd_repo_path_var
    local usb_easd_bare_repo_path

    for usb_easd_project_name in "${USB_LOADED_PROJECTS[@]}"; do
        usb_easd_project_name_upper="${usb_easd_project_name^^}"
        usb_easd_repo_path_var="USB_${usb_easd_project_name_upper}_REPO_PATH"
        if [[ -n "${!usb_easd_repo_path_var}" ]]; then
            usb_easd_bare_repo_path="$USB_MOUNT_POINT/${!usb_easd_repo_path_var}"
            if [[ -d "$usb_easd_bare_repo_path" ]]; then
                _usb_ensure_safe_directory "$usb_easd_bare_repo_path"
            fi
        fi
    done
}

# =============================================================
# _usb_check_windows_git
# Add before usb_init_bare. Checks if git is available via
# PowerShell. Returns 0 if available, 1 if not.
# @@TODO: Need to convert into accessed variable. Shouldnt change all the time.
# =============================================================
_usb_check_windows_git() {
    local usb_cwg_result
    # Probe: git may legitimately be absent on Windows, so suppress the
    # wrapper's failure diagnostic here; an empty result means "return 1".
    usb_cwg_result=$(_usb_ps "git --version; exit \$LASTEXITCODE" 2>/dev/null)
    if [[ -z "$usb_cwg_result" ]]; then
        return 1
    fi
    return 0
}

# usb_verify_connected -- check USB is still physically connected
# Returns 0 if connected, 1 if not. Updates USB_CONNECTED on stale state.
# $1 is checked for -h/--help by design; callers are users at the shell, not other functions
# shellcheck disable=SC2120
usb_verify_connected() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_verify_connected - check USB is still physically connected
Usage:
  usb_verify_connected
Returns 0 if connected, 1 if not. Updates USB_CONNECTED on stale state.
EOF
        return 0
    fi
    if [[ "$USB_CONNECTED" != true ]]; then
        return 1
    fi
    if [[ ! -f "$USB_MOUNT_POINT/$USB_MANIFEST_FILENAME" ]]; then
        _usb_warn "USB appears disconnected (manifest not found)"
        export USB_CONNECTED=false
        return 1
    fi
    return 0
}

# usb_commit -- stage and commit changes in a loaded project
# Arguments:
#   project_name -- name of the project, or "all" for all loaded projects
# Commits with a daily sync message: "project: sync YYYY-MM-DD".
# If the last commit already matches today's message, amends it.
# This accumulates a day's changes into a single commit.
# Local-only operation -- does not require USB to be connected.
# "all" mode uses skip-and-continue: failures in one project do not stop others.
usb_commit() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_commit - stage and commit changes in a loaded project
Usage:
  usb_commit <project>    commit a specific project
  usb_commit all          commit all loaded projects
Stages all changes and commits with a timestamped sync message
(<project>: sync YYYY-MM-DD HH:MM). Always creates a new commit.
Skips projects with no changes.
Does not require USB to be connected (local repos only).
EOF
        return 0
    fi
    local usb_commit_project_name="$1"
    if [[ "$usb_commit_project_name" == "all" ]]; then
        # Build project list from in-memory loaded projects if available.
        # Fall back to discovering projects from config files on disk.
        # NOTE/TODO: This config-discovery pattern parallels the single-project
        # config fallback below. If more functions need this, centralize.
        local usb_commit_all_project_names=()

        if [[ ${#USB_LOADED_PROJECTS[@]} -gt 0 ]]; then
            usb_commit_all_project_names=("${USB_LOADED_PROJECTS[@]}")
        else
            local usb_commit_all_config_dir
            usb_commit_all_config_dir="$(dirname "$USB_SCRIPT_PATH")/configs"
            local usb_commit_all_config_file
            for usb_commit_all_config_file in "$usb_commit_all_config_dir"/*.conf.reference; do
                if [[ ! -f "$usb_commit_all_config_file" ]]; then
                    continue
                fi
                local usb_commit_all_config_basename
                usb_commit_all_config_basename="$(basename "$usb_commit_all_config_file")"
                local usb_commit_all_discovered_name="${usb_commit_all_config_basename%.conf.reference}"
                usb_commit_all_project_names+=("$usb_commit_all_discovered_name")
            done
            if [[ ${#usb_commit_all_project_names[@]} -gt 0 ]]; then
                _usb_msg "discovered ${#usb_commit_all_project_names[@]} project(s) from config files (none loaded in memory)"
            fi
        fi

        if [[ ${#usb_commit_all_project_names[@]} -eq 0 ]]; then
            _usb_msg "no projects loaded and no config files found"
            return 0
        fi

        local usb_commit_all_project_name
        local usb_commit_success_count=0
        local usb_commit_fail_count=0
        for usb_commit_all_project_name in "${usb_commit_all_project_names[@]}"; do
            _usb_msg "--- commit $usb_commit_all_project_name ---"
            if usb_commit "$usb_commit_all_project_name"; then
                usb_commit_success_count=$((usb_commit_success_count + 1))
            else
                usb_commit_fail_count=$((usb_commit_fail_count + 1))
            fi
        done
        _usb_msg "commit all complete: $usb_commit_success_count succeeded, $usb_commit_fail_count failed"
        if [[ "$usb_commit_fail_count" -gt 0 ]]; then
            _usb_err "commit all finished with $usb_commit_fail_count failure(s)"
            return 1
        fi
        return 0
    fi

    # --- Single project mode ---

    if [[ -z "$usb_commit_project_name" ]]; then
        _usb_err "argument required: usb_commit <project|all>"
        _usb_msg "loaded projects: ${USB_LOADED_PROJECTS[*]}"
        return 1
    fi

    # --- Phase 1: Resolve local directory ---
    # Try in-memory variable first (set when project is loaded).
    # Fall back to config file on disk if not available.
    # NOTE/TODO: This fallback-from-config pattern is a local fix for usb_commit.
    # If other functions need the same resilience, centralize into a shared resolver.

    local usb_commit_local_dir=""
    local usb_commit_project_name_upper="${usb_commit_project_name^^}"
    local usb_commit_local_dir_variable_name="USB_${usb_commit_project_name_upper}_LOCAL_DIR"

    if [[ -n "${!usb_commit_local_dir_variable_name}" ]]; then
        usb_commit_local_dir="${!usb_commit_local_dir_variable_name}"
    else
        # Fall back to reading local_dir from the config file on disk
        local usb_commit_config_dir
        usb_commit_config_dir="$(dirname "$USB_SCRIPT_PATH")/configs"
        local usb_commit_config_file_path="$usb_commit_config_dir/${usb_commit_project_name}.conf.reference"

        if [[ ! -f "$usb_commit_config_file_path" ]]; then
            _usb_err "project '$usb_commit_project_name' is not loaded and no config found at $usb_commit_config_file_path"
            return 1
        fi

        local usb_commit_conf_key
        local usb_commit_conf_value
        local usb_commit_conf_line
        while IFS= read -r usb_commit_conf_line; do
            usb_commit_conf_line="${usb_commit_conf_line%$'\r'}"
            if [[ -z "$usb_commit_conf_line" || "$usb_commit_conf_line" == \#* ]]; then
                continue
            fi
            if [[ "$usb_commit_conf_line" != *=* ]]; then
                _usb_warn "skipping malformed line (no '='): $usb_commit_conf_line"
                continue
            fi
            usb_commit_conf_key="${usb_commit_conf_line%%=*}"
            usb_commit_conf_value="${usb_commit_conf_line#*=}"
            if [[ ! "$usb_commit_conf_key" =~ ^[a-z][a-z0-9_]*$ ]]; then
                _usb_warn "skipping invalid key: $usb_commit_conf_key"
                continue
            fi
            case "$usb_commit_conf_key" in
                local_dir)
                    usb_commit_local_dir="${usb_commit_conf_value//\{HOME\}/$HOME}"
                    usb_commit_local_dir="${usb_commit_local_dir//\{WINDOWS_USER\}/$USB_WINDOWS_USER}"
                    ;;
            esac
        done < "$usb_commit_config_file_path"

        if [[ -z "$usb_commit_local_dir" ]]; then
            _usb_err "could not resolve local_dir for project '$usb_commit_project_name' from config"
            return 1
        fi

        _usb_msg "[$usb_commit_project_name] resolved local dir from config (project not loaded in memory)"
    fi

    # --- Phase 2: Stage and commit ---

    if [[ ! -d "$usb_commit_local_dir/.git" ]]; then
        _usb_err "$usb_commit_local_dir is not a git repo"
        return 1
    fi

    if [[ -z "$(git -C "$usb_commit_local_dir" status --porcelain 2>/dev/null)" ]]; then
        _usb_msg "[$usb_commit_project_name] nothing to commit"
        return 0
    fi

    git -C "$usb_commit_local_dir" add -A

    local usb_commit_today
    usb_commit_today="$(date '+%Y-%m-%d %H:%M')"
    local usb_commit_expected_message="$usb_commit_project_name: sync $usb_commit_today"

    git -C "$usb_commit_local_dir" commit -m "$usb_commit_expected_message"
    _usb_msg "[$usb_commit_project_name] committed: $usb_commit_expected_message"
}


# usb_push -- push local git repo to USB bare repo
# Arguments:
#   project_name -- name of the project, or "all" for all loaded projects
# Transport only -- refuses if uncommitted changes exist.
# Run usb_commit first to stage and commit.
# Plain push (no --force): git's native non-fast-forward refusal rejects a
# push when the bare repo has commits the local branch lacks. On failure we
# suggest usb_pull to reconcile.
# Uses git -C throughout.
# "all" mode uses skip-and-continue: failures in one project do not stop others.
usb_push() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_push - push local git repo to USB bare repo
Usage:
  usb_push <project>    push a specific project
  usb_push all          push all loaded projects
Refuses if there are uncommitted changes. Run usb_commit first.
If the bare repo has commits not in your local branch, git refuses
the non-fast-forward push. Run usb_pull first to reconcile, then push.
EOF
        return 0
    fi

    local usb_push_project_name="$1"

    if [[ "$usb_push_project_name" == "all" ]]; then
        if ! usb_verify_connected; then
            _usb_err "USB not connected"
            return 1
        fi
        if [[ ${#USB_LOADED_PROJECTS[@]} -eq 0 ]]; then
            _usb_msg "no projects loaded"
            return 0
        fi
        local usb_push_all_project_name
        local usb_push_success_count=0
        local usb_push_fail_count=0
        for usb_push_all_project_name in "${USB_LOADED_PROJECTS[@]}"; do
            _usb_msg "--- push $usb_push_all_project_name ---"
            if usb_push "$usb_push_all_project_name"; then
                usb_push_success_count=$((usb_push_success_count + 1))
            else
                usb_push_fail_count=$((usb_push_fail_count + 1))
            fi
        done
        _usb_msg "push all complete: $usb_push_success_count succeeded, $usb_push_fail_count failed"
        if [[ "$usb_push_fail_count" -gt 0 ]]; then
            _usb_err "push all finished with $usb_push_fail_count failure(s)"
            return 1
        fi
        return 0
    fi

    local usb_push_project_name_upper
    local usb_push_local_dir_variable_name
    local usb_push_repo_path_variable_name
    local usb_push_project_is_loaded
    local usb_push_loaded_project_name
    local usb_push_branch
    local usb_push_bare_repo_path
    local usb_push_rc

    if [[ -z "$usb_push_project_name" ]]; then
        _usb_err "argument required: usb_push <project|all>"
        _usb_msg "loaded projects: ${USB_LOADED_PROJECTS[*]}"
        return 1
    fi

    if ! usb_verify_connected; then
        _usb_err "USB not connected"
        return 1
    fi

    usb_push_project_is_loaded=false
    for usb_push_loaded_project_name in "${USB_LOADED_PROJECTS[@]}"; do
        if [[ "$usb_push_loaded_project_name" == "$usb_push_project_name" ]]; then
            usb_push_project_is_loaded=true
            break
        fi
    done
    if [[ "$usb_push_project_is_loaded" == false ]]; then
        _usb_err "project '$usb_push_project_name' is not loaded"
        _usb_msg "loaded projects: ${USB_LOADED_PROJECTS[*]}"
        return 1
    fi

    usb_push_project_name_upper="${usb_push_project_name^^}"
    usb_push_local_dir_variable_name="USB_${usb_push_project_name_upper}_LOCAL_DIR"
    usb_push_repo_path_variable_name="USB_${usb_push_project_name_upper}_REPO_PATH"
    declare -n usb_push_local_dir_ref="$usb_push_local_dir_variable_name"
    declare -n usb_push_repo_path_ref="$usb_push_repo_path_variable_name"

    if [[ ! -e "$usb_push_local_dir_ref/.git" ]]; then
        _usb_err "$usb_push_local_dir_ref is not a git repo"
        unset -n usb_push_local_dir_ref
        unset -n usb_push_repo_path_ref
        return 1
    fi

    usb_push_bare_repo_path="$USB_MOUNT_POINT/$usb_push_repo_path_ref"
    if [[ ! -d "$usb_push_bare_repo_path" ]]; then
        _usb_err "bare repo not found on USB: $usb_push_bare_repo_path"
        unset -n usb_push_local_dir_ref
        unset -n usb_push_repo_path_ref
        return 1
    fi

    usb_push_branch=$(git -C "$usb_push_local_dir_ref" symbolic-ref --short HEAD 2>/dev/null)
    if [[ -z "$usb_push_branch" ]]; then
        _usb_err "could not detect branch in $usb_push_local_dir_ref (detached HEAD?)"
        unset -n usb_push_local_dir_ref
        unset -n usb_push_repo_path_ref
        return 1
    fi

    if [[ -n "$(git -C "$usb_push_local_dir_ref" status --porcelain 2>/dev/null)" ]]; then
        _usb_err "uncommitted changes in $usb_push_local_dir_ref"
        _usb_msg "run usb_commit $usb_push_project_name first"
        unset -n usb_push_local_dir_ref
        unset -n usb_push_repo_path_ref
        return 1
    fi

    # No hand-rolled divergence guard: a plain (non-force) push makes git
    # refuse a non-fast-forward update natively. On any push failure, suggest
    # usb_pull to reconcile. Capture git's real exit code directly -- inside
    # the then-block of `if ! cmd`, $? would already be reset to 0.
    git -C "$usb_push_local_dir_ref" push "$usb_push_bare_repo_path" "$usb_push_branch"
    usb_push_rc=$?
    if [[ "$usb_push_rc" -ne 0 ]]; then
        _usb_err "push failed for $usb_push_project_name"
        _usb_msg "if the bare repo is ahead, run usb_pull $usb_push_project_name first, then push again"
        unset -n usb_push_local_dir_ref
        unset -n usb_push_repo_path_ref
        return "$usb_push_rc"
    fi
    unset -n usb_push_local_dir_ref
    unset -n usb_push_repo_path_ref
    return 0
}

# usb_pull -- pull from USB bare repo to local git repo
# Arguments:
#   project_name -- name of the project, or "all" for all loaded projects
# Refuses if uncommitted changes exist. Commit or stash manually first.
# Uses --rebase to reconcile local and bare divergence cleanly.
# Uses git -C throughout.
# "all" mode uses skip-and-continue: failures in one project do not stop others.
usb_pull() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_pull - pull from USB bare repo to local git repo
Usage:
  usb_pull <project>    pull a specific project
  usb_pull all          pull all loaded projects
Refuses if there are uncommitted changes. Commit or stash first.
Uses --rebase to reconcile divergence cleanly.
EOF
        return 0
    fi

    local usb_pull_project_name="$1"

    if [[ "$usb_pull_project_name" == "all" ]]; then
        if ! usb_verify_connected; then
            _usb_err "USB not connected"
            return 1
        fi
        if [[ ${#USB_LOADED_PROJECTS[@]} -eq 0 ]]; then
            _usb_msg "no projects loaded"
            return 0
        fi
        local usb_pull_all_project_name
        local usb_pull_success_count=0
        local usb_pull_fail_count=0
        for usb_pull_all_project_name in "${USB_LOADED_PROJECTS[@]}"; do
            _usb_msg "--- pull $usb_pull_all_project_name ---"
            if usb_pull "$usb_pull_all_project_name"; then
                usb_pull_success_count=$((usb_pull_success_count + 1))
            else
                usb_pull_fail_count=$((usb_pull_fail_count + 1))
            fi
        done
        _usb_msg "pull all complete: $usb_pull_success_count succeeded, $usb_pull_fail_count failed"
        if [[ "$usb_pull_fail_count" -gt 0 ]]; then
            _usb_err "pull all finished with $usb_pull_fail_count failure(s)"
            return 1
        fi
        return 0
    fi

    local usb_pull_project_name_upper
    local usb_pull_local_dir_variable_name
    local usb_pull_repo_path_variable_name
    local usb_pull_project_is_loaded
    local usb_pull_loaded_project_name
    local usb_pull_branch
    local usb_pull_bare_repo_path
    local usb_pull_rc

    if [[ -z "$usb_pull_project_name" ]]; then
        _usb_err "argument required: usb_pull <project|all>"
        _usb_msg "loaded projects: ${USB_LOADED_PROJECTS[*]}"
        return 1
    fi

    if ! usb_verify_connected; then
        _usb_err "USB not connected"
        return 1
    fi

    usb_pull_project_is_loaded=false
    for usb_pull_loaded_project_name in "${USB_LOADED_PROJECTS[@]}"; do
        if [[ "$usb_pull_loaded_project_name" == "$usb_pull_project_name" ]]; then
            usb_pull_project_is_loaded=true
            break
        fi
    done
    if [[ "$usb_pull_project_is_loaded" == false ]]; then
        _usb_err "project '$usb_pull_project_name' is not loaded"
        _usb_msg "loaded projects: ${USB_LOADED_PROJECTS[*]}"
        return 1
    fi

    usb_pull_project_name_upper="${usb_pull_project_name^^}"
    usb_pull_local_dir_variable_name="USB_${usb_pull_project_name_upper}_LOCAL_DIR"
    usb_pull_repo_path_variable_name="USB_${usb_pull_project_name_upper}_REPO_PATH"
    declare -n usb_pull_local_dir_ref="$usb_pull_local_dir_variable_name"
    declare -n usb_pull_repo_path_ref="$usb_pull_repo_path_variable_name"

    if [[ ! -d "$usb_pull_local_dir_ref/.git" ]]; then
        _usb_err "$usb_pull_local_dir_ref is not a git repo"
        unset -n usb_pull_local_dir_ref
        unset -n usb_pull_repo_path_ref
        return 1
    fi

    usb_pull_bare_repo_path="$USB_MOUNT_POINT/$usb_pull_repo_path_ref"
    if [[ ! -d "$usb_pull_bare_repo_path" ]]; then
        _usb_err "bare repo not found on USB: $usb_pull_bare_repo_path"
        unset -n usb_pull_local_dir_ref
        unset -n usb_pull_repo_path_ref
        return 1
    fi

    if [[ -n "$(git -C "$usb_pull_local_dir_ref" status --porcelain 2>/dev/null)" ]]; then
        _usb_err "uncommitted changes in $usb_pull_local_dir_ref"
        _usb_msg "commit or stash changes before pulling"
        unset -n usb_pull_local_dir_ref
        unset -n usb_pull_repo_path_ref
        return 1
    fi

    usb_pull_branch=$(git -C "$usb_pull_local_dir_ref" symbolic-ref --short HEAD 2>/dev/null)
    if [[ -z "$usb_pull_branch" ]]; then
        _usb_err "could not detect branch in $usb_pull_local_dir_ref (detached HEAD?)"
        unset -n usb_pull_local_dir_ref
        unset -n usb_pull_repo_path_ref
        return 1
    fi

    git -C "$usb_pull_local_dir_ref" pull --rebase "$usb_pull_bare_repo_path" "$usb_pull_branch"
    usb_pull_rc=$?
    unset -n usb_pull_local_dir_ref
    unset -n usb_pull_repo_path_ref
    return "$usb_pull_rc"
}

# =============================================================
# usb_init_bare -- create bare repo on USB for a loaded project
# Arguments:
#   project_name -- name of the project as it appears in USB_LOADED_PROJECTS
# Project must be loaded (conf exists, local_dir is a git repo).
# WSL: uses PowerShell git, adds safe.directory, pushes initial content.
# Linux: uses git clone --bare (copies content in one step).
# Refuses if bare repo already exists on USB.
#   - Checks for Windows git before attempting PowerShell init
#   - On PowerShell failure, prints manual commands
#   - Calls _usb_ensure_safe_directory instead of raw git config
#   - Handles retry: if bare repo dir exists but is empty/valid,
#     skips init and attempts push only
# =============================================================
usb_init_bare() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_init_bare - create bare repo on USB for a loaded project
Usage:
  usb_init_bare <project>
Project must be loaded (conf exists, local_dir is a git repo).
Refuses if bare repo already exists on USB.
On WSL, requires git installed on Windows (winget install Git.Git).
EOF
        return 0
    fi

    local usb_init_project_name="$1"
    local usb_init_project_name_upper
    local usb_init_local_dir_variable_name
    local usb_init_repo_path_variable_name
    local usb_init_project_is_loaded
    local usb_init_loaded_project_name
    local usb_init_branch
    local usb_init_bare_repo_path
    local usb_init_needs_init
    local usb_init_win_path

    if [[ -z "$usb_init_project_name" ]]; then
        _usb_err "usage: usb_init_bare <project>"
        return 1
    fi

    if ! usb_verify_connected; then
        _usb_err "USB not connected"
        return 1
    fi

    usb_init_project_is_loaded=false
    for usb_init_loaded_project_name in "${USB_LOADED_PROJECTS[@]}"; do
        if [[ "$usb_init_loaded_project_name" == "$usb_init_project_name" ]]; then
            usb_init_project_is_loaded=true
            break
        fi
    done

    if [[ "$usb_init_project_is_loaded" == false ]]; then
        _usb_err "project '$usb_init_project_name' is not loaded"
        _usb_msg "loaded projects: ${USB_LOADED_PROJECTS[*]}"
        return 1
    fi

    usb_init_project_name_upper="${usb_init_project_name^^}"
    usb_init_local_dir_variable_name="USB_${usb_init_project_name_upper}_LOCAL_DIR"
    usb_init_repo_path_variable_name="USB_${usb_init_project_name_upper}_REPO_PATH"
    declare -n usb_init_local_dir_ref="$usb_init_local_dir_variable_name"
    declare -n usb_init_repo_path_ref="$usb_init_repo_path_variable_name"

    if [[ ! -d "$usb_init_local_dir_ref/.git" ]]; then
        _usb_err "$usb_init_local_dir_ref is not a git repo"
        unset -n usb_init_local_dir_ref
        unset -n usb_init_repo_path_ref
        return 1
    fi

    usb_init_bare_repo_path="$USB_MOUNT_POINT/$usb_init_repo_path_ref"

    # detect branch
    usb_init_branch=$(git -C "$usb_init_local_dir_ref" symbolic-ref --short HEAD 2>/dev/null)
    if [[ -z "$usb_init_branch" ]]; then
        _usb_err "could not detect branch in $usb_init_local_dir_ref (detached HEAD?)"
        unset -n usb_init_local_dir_ref
        unset -n usb_init_repo_path_ref
        return 1
    fi

    # check if bare repo exists -- allow retry if HEAD is missing (init succeeded, push didn't)
    usb_init_needs_init=true
    if [[ -d "$usb_init_bare_repo_path" ]]; then
        if [[ -f "$usb_init_bare_repo_path/HEAD" ]]; then
            _usb_err "bare repo already exists: $usb_init_bare_repo_path"
            unset -n usb_init_local_dir_ref
            unset -n usb_init_repo_path_ref
            return 1
        else
            _usb_msg "bare repo directory exists but looks incomplete, retrying push..."
            usb_init_needs_init=false
        fi
    fi

    if [[ "$USB_ENV" == "wsl" ]]; then
        # build windows path for PowerShell
        usb_init_win_path="${USB_DRIVE_LETTER}:\\${usb_init_repo_path_ref//\//\\}"

        if [[ "$usb_init_needs_init" == true ]]; then
            # check for Windows git
            if ! _usb_check_windows_git; then
                _usb_err "git not found on Windows"
                _usb_msg "install git for Windows:"
                _usb_msg "  winget install Git.Git"
                _usb_msg "then restart your terminal and retry"
                unset -n usb_init_local_dir_ref
                unset -n usb_init_repo_path_ref
                return 1
            fi

            _usb_msg "creating bare repo via PowerShell..."
            if ! _usb_ps "git init --bare '$usb_init_win_path'; exit \$LASTEXITCODE"; then
                _usb_err "git init --bare failed via PowerShell"
                _usb_msg "run manually in PowerShell:"
                _usb_msg "  git init --bare '$usb_init_win_path'"
                _usb_msg "then re-run this command to push:"
                _usb_msg "  usb_init_bare $usb_init_project_name"
                unset -n usb_init_local_dir_ref
                unset -n usb_init_repo_path_ref
                return 1
            fi
        fi

        _usb_ensure_safe_directory "$usb_init_bare_repo_path"

        _usb_msg "pushing $usb_init_branch to bare repo..."
        if ! git -C "$usb_init_local_dir_ref" push "$usb_init_bare_repo_path" "$usb_init_branch"; then
            _usb_err "initial push failed"
            _usb_msg "bare repo was created at $usb_init_win_path"
            _usb_msg "debug: try pushing manually:"
            _usb_msg "  git -C $usb_init_local_dir_ref push $usb_init_bare_repo_path $usb_init_branch"
            unset -n usb_init_local_dir_ref
            unset -n usb_init_repo_path_ref
            return 1
        fi
    else
        if [[ "$usb_init_needs_init" == true ]]; then
            _usb_msg "cloning bare repo to USB..."
            if ! git clone --bare "$usb_init_local_dir_ref" "$usb_init_bare_repo_path"; then
                _usb_err "git clone --bare failed"
                unset -n usb_init_local_dir_ref
                unset -n usb_init_repo_path_ref
                return 1
            fi
        fi

        _usb_ensure_safe_directory "$usb_init_bare_repo_path"
    fi

    _usb_msg "bare repo created at $usb_init_bare_repo_path"
    unset -n usb_init_local_dir_ref
    unset -n usb_init_repo_path_ref
}

# usb_clone_all -- clone all bare repos from USB to local directories
# No arguments. For new machine setup.
# Iterates .usb-projects/*.conf on USB, parses local_dir and repo_path.
# Skips projects where local_dir already exists or bare repo is missing.
# Creates parent directories if needed. Handles HEAD ref mismatch by
# detecting and checking out the actual branch after cloning.
# Does NOT modify USB_LOADED_PROJECTS or export variables.
# Run usb_refresh after to reload projects.
usb_clone_all() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_clone_all - clone all bare repos from USB to local directories
Usage:
  usb_clone_all
For new machine setup. Iterates .usb-projects/*.conf on USB.
Skips projects where local_dir already exists or bare repo is missing.
Run usb_refresh after to reload projects.
EOF
        return 0
    fi

    if ! usb_verify_connected; then
        _usb_err "USB not connected"
        return 1
    fi

    local usb_clone_conf_file_path
    local usb_clone_project_name
    local usb_clone_local_dir
    local usb_clone_repo_path
    local usb_clone_conf_key
    local usb_clone_conf_value
    local usb_clone_conf_line
    local usb_clone_bare_repo_path
    local usb_clone_parent_dir
    local usb_clone_branch
    local usb_clone_cloned_count=0
    local usb_clone_skipped_count=0
    local usb_clone_error_count=0

    for usb_clone_conf_file_path in "$USB_MOUNT_POINT/.usb-projects/"*.conf; do
        if [[ ! -f "$usb_clone_conf_file_path" ]]; then
            _usb_msg "no conf files found"
            break
        fi

        usb_clone_local_dir=""
        usb_clone_repo_path=""
        usb_clone_project_name=$(basename "$usb_clone_conf_file_path" .conf)

        while IFS= read -r usb_clone_conf_line; do
            usb_clone_conf_line="${usb_clone_conf_line%$'\r'}"
            if [[ -z "$usb_clone_conf_line" || "$usb_clone_conf_line" == \#* ]]; then
                continue
            fi
            if [[ "$usb_clone_conf_line" != *=* ]]; then
                _usb_warn "conf '$usb_clone_project_name' skipping malformed line (no '='): $usb_clone_conf_line"
                continue
            fi
            usb_clone_conf_key="${usb_clone_conf_line%%=*}"
            usb_clone_conf_value="${usb_clone_conf_line#*=}"
            if [[ ! "$usb_clone_conf_key" =~ ^[a-z][a-z0-9_]*$ ]]; then
                _usb_warn "conf '$usb_clone_project_name' skipping invalid key: $usb_clone_conf_key"
                continue
            fi
            case "$usb_clone_conf_key" in
                local_dir)
                    usb_clone_local_dir="${usb_clone_conf_value//\{HOME\}/$HOME}"
                    usb_clone_local_dir="${usb_clone_local_dir//\{WINDOWS_USER\}/$USB_WINDOWS_USER}"
                    ;;
                repo_path)
                    usb_clone_repo_path="$usb_clone_conf_value"
                    ;;
            esac
        done < "$usb_clone_conf_file_path"

        if [[ -z "$usb_clone_local_dir" || -z "$usb_clone_repo_path" ]]; then
            _usb_warn "conf '$usb_clone_project_name' missing local_dir or repo_path, skipping"
            usb_clone_error_count=$((usb_clone_error_count + 1))
            continue
        fi

        if [[ -d "$usb_clone_local_dir" ]]; then
            _usb_msg "[$usb_clone_project_name] local_dir exists, skipping: $usb_clone_local_dir"
            usb_clone_skipped_count=$((usb_clone_skipped_count + 1))
            continue
        fi

        usb_clone_bare_repo_path="$USB_MOUNT_POINT/$usb_clone_repo_path"
        if [[ ! -d "$usb_clone_bare_repo_path" ]]; then
            _usb_warn "[$usb_clone_project_name] bare repo not found on USB: $usb_clone_bare_repo_path"
            usb_clone_skipped_count=$((usb_clone_skipped_count + 1))
            continue
        fi

        # ensure parent directory exists
        usb_clone_parent_dir=$(dirname "$usb_clone_local_dir")
        if [[ ! -d "$usb_clone_parent_dir" ]]; then
            _usb_msg "[$usb_clone_project_name] creating parent directory: $usb_clone_parent_dir"
            if ! mkdir -p "$usb_clone_parent_dir"; then
                _usb_err "[$usb_clone_project_name] failed to create parent directory"
                usb_clone_error_count=$((usb_clone_error_count + 1))
                continue
            fi
        fi

        # detect actual branch in bare repo before cloning
        usb_clone_branch=$(git -C "$usb_clone_bare_repo_path" branch --list 2>/dev/null | sed 's/^[* ]*//' | head -n1)

        _usb_msg "[$usb_clone_project_name] cloning $usb_clone_bare_repo_path -> $usb_clone_local_dir"

        if [[ -n "$usb_clone_branch" ]]; then
            # clone with explicit branch to avoid HEAD ref mismatch
            if git clone --branch "$usb_clone_branch" "$usb_clone_bare_repo_path" "$usb_clone_local_dir"; then
                usb_clone_cloned_count=$((usb_clone_cloned_count + 1))
            else
                _usb_err "[$usb_clone_project_name] clone failed"
                usb_clone_error_count=$((usb_clone_error_count + 1))
                continue
            fi
        else
            # fallback: clone without branch (bare repo may be empty)
            if git clone "$usb_clone_bare_repo_path" "$usb_clone_local_dir"; then
                usb_clone_cloned_count=$((usb_clone_cloned_count + 1))
            else
                _usb_err "[$usb_clone_project_name] clone failed"
                usb_clone_error_count=$((usb_clone_error_count + 1))
                continue
            fi
        fi

        if [[ "$USB_ENV" == "wsl" ]]; then
            git config --global --add safe.directory "$usb_clone_bare_repo_path"
        fi
    done

    _usb_msg "clone_all complete: $usb_clone_cloned_count cloned, $usb_clone_skipped_count skipped, $usb_clone_error_count errors"
    if [[ "$usb_clone_cloned_count" -gt 0 ]]; then
        _usb_msg "run usb_refresh to reload projects"
    fi
}

# _usb_run_sync -- execute all sync_file and sync_dir entries for a project
# Arguments:
#   project_name -- name of the project as it appears in USB_LOADED_PROJECTS
# Processes sync_file entries first (individual file copies), then sync_dir
# entries (directory tree walks). All entries run unconditionally when called.
# Condition "newer" copies only when source is newer than dest (or dest missing).
# Sync entry format: source:dest:condition
_usb_run_sync() {
    local usb_sync_project_name="$1"
    local usb_sync_project_name_upper
    local usb_sync_files_variable_name
    local usb_sync_dirs_variable_name
    local usb_sync_entry
    local usb_sync_source_path
    local usb_sync_dest_path
    local usb_sync_condition
    local usb_sync_dest_dir
    local usb_sync_copy_result
    local usb_sync_log_timestamp
    local usb_sync_log_warning_shown=false
    local usb_sync_source_file_path
    local usb_sync_relative_path
    local usb_sync_dest_file_path
    local usb_sync_dest_file_dir
    local usb_sync_copy_count
    local usb_sync_error_count
    local usb_sync_symlink_count
    local usb_sync_should_copy

    if [[ -z "$usb_sync_project_name" ]]; then
        _usb_err "_usb_run_sync requires a project name argument"
        return 1
    fi

    usb_sync_project_name_upper="${usb_sync_project_name^^}"

    # Copy policy (all cp sites below): cp WITHOUT -p, so dest takes the current
    # mtime rather than inheriting the source's. Under "newer" this keeps the
    # relay one-directional -- after a copy dest is at least as new as src, so
    # the next sync does not re-copy the same file. This "newer-relay" property
    # is a documented assumption, not an enforced guard (see docs/design.md).

    # --- Sync files ---

    usb_sync_files_variable_name="USB_${usb_sync_project_name_upper}_SYNC_FILES"
    declare -n usb_sync_files_array_ref="$usb_sync_files_variable_name"


    if [[ ${#usb_sync_files_array_ref[@]} -gt 0 ]]; then
        for usb_sync_entry in "${usb_sync_files_array_ref[@]}"; do

            # Format: source:dest:condition
            IFS=: read -r usb_sync_source_path usb_sync_dest_path usb_sync_condition <<< "$usb_sync_entry"

            _usb_msg "[$usb_sync_project_name] evaluating entry: $usb_sync_source_path -> $usb_sync_dest_path (condition: $usb_sync_condition)"

            usb_sync_copy_result="SKIP"

            if [[ "$usb_sync_condition" == "newer" ]]; then
                # -nt returns false when source does not exist (graceful skip).
                # -nt returns true when dest does not exist (copy needed).
                if [[ "$usb_sync_source_path" -nt "$usb_sync_dest_path" ]]; then
                    usb_sync_dest_dir=$(dirname "$usb_sync_dest_path")
                    if [[ ! -d "$usb_sync_dest_dir" ]]; then
                        _usb_err "[$usb_sync_project_name] dest directory does not exist: $usb_sync_dest_dir"
                        usb_sync_copy_result="ERROR"
                    else

                        _usb_msg "[$usb_sync_project_name] copying (newer): $usb_sync_source_path -> $usb_sync_dest_path"
                        if cp "$usb_sync_source_path" "$usb_sync_dest_path"; then
                            usb_sync_copy_result="OK"
                        else
                            usb_sync_copy_result="ERROR"
                        fi

                    fi
                else

                    _usb_msg "[$usb_sync_project_name] skipping (source not newer): $usb_sync_source_path"

                fi
            elif [[ "$usb_sync_condition" == "differs" ]]; then
                # cmp -s: identical -> skip; differ or dest missing -> copy.
                # Source missing is a graceful skip (parallels -nt for "newer").
                if [[ ! -e "$usb_sync_source_path" ]]; then
                    _usb_msg "[$usb_sync_project_name] skipping (source does not exist): $usb_sync_source_path"
                elif cmp -s "$usb_sync_source_path" "$usb_sync_dest_path"; then
                    _usb_msg "[$usb_sync_project_name] skipping (identical): $usb_sync_source_path"
                else
                    usb_sync_dest_dir=$(dirname "$usb_sync_dest_path")
                    if [[ ! -d "$usb_sync_dest_dir" ]]; then
                        _usb_err "[$usb_sync_project_name] dest directory does not exist: $usb_sync_dest_dir"
                        usb_sync_copy_result="ERROR"
                    else

                        _usb_msg "[$usb_sync_project_name] copying (differs): $usb_sync_source_path -> $usb_sync_dest_path"
                        if cp "$usb_sync_source_path" "$usb_sync_dest_path"; then
                            usb_sync_copy_result="OK"
                        else
                            usb_sync_copy_result="ERROR"
                        fi

                    fi
                fi
            else

                _usb_warn "[$usb_sync_project_name] unknown condition '$usb_sync_condition', skipping entry"

            fi

            usb_sync_log_timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
            if [[ "$usb_sync_copy_result" == "OK" ]]; then
                _usb_msg "[$usb_sync_project_name] synced $usb_sync_source_path -> $usb_sync_dest_path"
            elif [[ "$usb_sync_copy_result" == "ERROR" ]]; then
                _usb_err "[$usb_sync_project_name] copy failed $usb_sync_source_path -> $usb_sync_dest_path"
            fi
            if [[ "$usb_sync_copy_result" == "OK" || "$usb_sync_copy_result" == "ERROR" ]]; then
                if [[ -n "$USB_SYNC_LOG" ]]; then
                    echo "$usb_sync_log_timestamp [$usb_sync_project_name] COPY $usb_sync_source_path -> $usb_sync_dest_path [$usb_sync_copy_result]" >> "$USB_SYNC_LOG"
                elif [[ "$usb_sync_log_warning_shown" == false ]]; then
                    _usb_warn "USB_SYNC_LOG is not set, skipping log writes"
                    usb_sync_log_warning_shown=true
                fi
            fi
        done
    fi
    unset -n usb_sync_files_array_ref

    # --- Sync dirs ---

    usb_sync_dirs_variable_name="USB_${usb_sync_project_name_upper}_SYNC_DIRS"
    declare -n usb_sync_dirs_array_ref="$usb_sync_dirs_variable_name"

    if [[ ${#usb_sync_dirs_array_ref[@]} -gt 0 ]]; then
        for usb_sync_entry in "${usb_sync_dirs_array_ref[@]}"; do

            # Format: source_dir:dest_dir:condition
            IFS=: read -r usb_sync_source_path usb_sync_dest_path usb_sync_condition <<< "$usb_sync_entry"

            if [[ "$usb_sync_condition" != "newer" && "$usb_sync_condition" != "differs" ]]; then
                _usb_warn "[$usb_sync_project_name] unknown condition '$usb_sync_condition', skipping entry"
                continue
            fi

            _usb_msg "[$usb_sync_project_name] processing sync_dir: $usb_sync_source_path -> $usb_sync_dest_path"

            if [[ ! -d "$usb_sync_source_path" ]]; then
                _usb_err "[$usb_sync_project_name] sync_dir source directory does not exist: $usb_sync_source_path"
                continue
            fi

            if [[ ! -d "$usb_sync_dest_path" ]]; then
                _usb_err "[$usb_sync_project_name] sync_dir dest directory does not exist: $usb_sync_dest_path"
                continue
            fi

            usb_sync_copy_count=0
            usb_sync_error_count=0

            # Warn about symlinks
            usb_sync_symlink_count=$(find "$usb_sync_source_path" -type l | wc -l)
            if [[ "$usb_sync_symlink_count" -gt 0 ]]; then
                _usb_warn "[$usb_sync_project_name] sync_dir skipped $usb_sync_symlink_count symlink(s) in $usb_sync_source_path"
            fi

            _usb_msg "[$usb_sync_project_name] scanning $usb_sync_source_path for files to sync..."

            while IFS= read -r usb_sync_source_file_path; do
                usb_sync_relative_path="${usb_sync_source_file_path#"$usb_sync_source_path"/}"
                usb_sync_dest_file_path="${usb_sync_dest_path}/${usb_sync_relative_path}"

                if [[ "$usb_sync_dest_file_path" != "$usb_sync_dest_path"/* ]]; then
                    _usb_err "[$usb_sync_project_name] sync_dir dest path outside dest_dir: $usb_sync_dest_file_path"
                    usb_sync_error_count=$((usb_sync_error_count + 1))
                    continue
                fi

                usb_sync_should_copy=false
                if [[ "$usb_sync_condition" == "newer" ]]; then
                    [[ "$usb_sync_source_file_path" -nt "$usb_sync_dest_file_path" ]] && usb_sync_should_copy=true
                else
                    # differs (guaranteed by the guard above): copy when the files
                    # differ or dest is missing; cmp -s is quiet and non-zero for both.
                    cmp -s "$usb_sync_source_file_path" "$usb_sync_dest_file_path" || usb_sync_should_copy=true
                fi

                if [[ "$usb_sync_should_copy" == true ]]; then

                    _usb_msg "[$usb_sync_project_name] copying ($usb_sync_condition): $usb_sync_relative_path"

                    usb_sync_dest_file_dir=$(dirname "$usb_sync_dest_file_path")
                    if [[ ! -d "$usb_sync_dest_file_dir" ]]; then
                        mkdir -p "$usb_sync_dest_file_dir"
                    fi
                    if cp "$usb_sync_source_file_path" "$usb_sync_dest_file_path"; then
                        usb_sync_copy_count=$((usb_sync_copy_count + 1))
                    else
                        _usb_err "[$usb_sync_project_name] sync_dir copy failed: $usb_sync_source_file_path -> $usb_sync_dest_file_path"
                        usb_sync_error_count=$((usb_sync_error_count + 1))
                    fi
                fi
            done < <(find "$usb_sync_source_path" -type f)

            # Summary / conclusion
            if [[ "$usb_sync_copy_count" -gt 0 || "$usb_sync_error_count" -gt 0 ]]; then
                _usb_msg "[$usb_sync_project_name] sync_dir $usb_sync_source_path -> $usb_sync_dest_path [$usb_sync_copy_count copied, $usb_sync_error_count errors]"
                usb_sync_log_timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
                if [[ -n "$USB_SYNC_LOG" ]]; then
                    echo "$usb_sync_log_timestamp [$usb_sync_project_name] SYNC_DIR $usb_sync_source_path -> $usb_sync_dest_path [$usb_sync_copy_count copied, $usb_sync_error_count errors]" >> "$USB_SYNC_LOG"
                elif [[ "$usb_sync_log_warning_shown" == false ]]; then
                    _usb_warn "USB_SYNC_LOG is not set, skipping log writes"
                    usb_sync_log_warning_shown=true
                fi
            else

                _usb_msg "[$usb_sync_project_name] sync_dir $usb_sync_source_path -> $usb_sync_dest_path: no files needed syncing"

            fi
        done
    fi

    unset -n usb_sync_dirs_array_ref

}


# usb_sync -- manually trigger file sync for one or all loaded projects
# Arguments:
#   [project_name] -- if omitted, syncs all loaded projects
# Requires USB connected. Runs all sync_file and sync_dir entries.
usb_sync() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_sync - manually trigger file sync for one or all loaded projects
Usage:
  usb_sync              sync all loaded projects
  usb_sync <project>    sync a specific project
Requires USB connected. Runs all sync_file and sync_dir entries.
EOF
        return 0
    fi

    local usb_sync_target_project="$1"
    local usb_sync_project_name
    local usb_sync_project_is_loaded

    if ! usb_verify_connected; then
        _usb_err "USB not connected"
        return 1
    fi

    if [[ -n "$usb_sync_target_project" ]]; then

        usb_sync_project_is_loaded=false
        for usb_sync_project_name in "${USB_LOADED_PROJECTS[@]}"; do
            if [[ "$usb_sync_project_name" == "$usb_sync_target_project" ]]; then
                usb_sync_project_is_loaded=true
                break
            fi
        done

        if [[ "$usb_sync_project_is_loaded" == false ]]; then
            _usb_err "project '$usb_sync_target_project' is not loaded"
            _usb_msg "loaded projects: ${USB_LOADED_PROJECTS[*]}"
            return 1
        fi

        _usb_run_sync "$usb_sync_target_project"

    else

        if [[ ${#USB_LOADED_PROJECTS[@]} -eq 0 ]]; then
            _usb_msg "no projects loaded"
            return 0
        fi

        for usb_sync_project_name in "${USB_LOADED_PROJECTS[@]}"; do
            _usb_msg "--- sync $usb_sync_project_name ---"
            _usb_run_sync "$usb_sync_project_name"
        done

    fi
}

# usb_eject -- pre-eject sync, unmount, PowerShell eject (WSL), state cleanup
# Syncs all loaded projects before unmount, then unmounts and clears state.
# _usb_clear_state -- sweep all drive-scope state after eject/removal.
# MACHINE-SCOPE (must survive): USB_SCRIPT_PATH, USB_CACHE_FILE,
#   USB_MANIFEST_FILENAME, USB_WINDOWS_USER, USB_ENV, _USB_PS_AVAILABLE,
#   USB_CONNECTED (set false, not unset -- PS1 hook reads it).
# DRIVE-SCOPE (swept here): everything below. This is the ONLY place
# drive-scope state is cleared; eject calls it from every exit path.
_usb_clear_state() {
    local _usb_cs_project _usb_cs_upper
    # [@]- guard: the yanked-USB path can reach here with the array
    # UNSET (half-initialized state), not merely empty.
    for _usb_cs_project in "${USB_LOADED_PROJECTS[@]-}"; do
        [[ -n "$_usb_cs_project" ]] || continue
        _usb_cs_upper="${_usb_cs_project^^}"
        unset "USB_${_usb_cs_upper}_LOCAL_DIR" \
              "USB_${_usb_cs_upper}_REPO_PATH" \
              "USB_${_usb_cs_upper}_SYNC_FILES" \
              "USB_${_usb_cs_upper}_SYNC_DIRS"
    done
    # Canonical exported name is USB_DRIVE_LETTER. Detection also leaves three
    # top-level intermediates that must not survive eject:
    unset USB_MOUNT_POINT USB_KEYS_FILE USB_DRIVE_LETTER USB_LABEL \
          USB_MANIFEST_VERSION USB_SYNC_LOG \
          USB_LOADED_PROJECTS USB_INITIALIZED \
          USB_DETECTED_DRIVE_LETTER USB_CACHED_DRIVE_LETTER \
          USB_POTENTIAL_MOUNT_POINT
    USB_KEYS_LOADED=false
    _USB_LOADED_KEY_NAMES=()
    export USB_CONNECTED=false
    rm -f "$USB_CACHE_FILE"
}

usb_eject() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_eject - pre-eject sync, unmount, and clean up state
Usage:
  usb_eject
Syncs all loaded projects, unmounts the USB,
ejects the drive (WSL), and clears all USB variables.
EOF
        return 0
    fi

    # Unload keys before any eject/cleanup logic.
    # Placed before verify_connected: keys should be unloaded even if USB was yanked.
    usb_unload_keys

    local usb_eject_project_name
    local usb_drive_still_present

    if ! usb_verify_connected; then
        _usb_msg "USB is not connected, cleaning up state"
        _usb_clear_state
        return 0
    fi

    if [[ ! -f "$USB_MOUNT_POINT/$USB_MANIFEST_FILENAME" ]]; then
        _usb_msg "USB already removed, cleaning up state"
        _usb_clear_state
        return 0
    fi
    for usb_eject_project_name in "${USB_LOADED_PROJECTS[@]}"; do
        _usb_run_sync "$usb_eject_project_name"
    done

    if [[ "$PWD" == "$USB_MOUNT_POINT"* ]]; then
        echo "usb: changing directory to ~"
        cd ~ || return 1
    fi

    # Flush filesystem write buffers before unmount. drvfs/VFAT can hold
    # dirty pages in the write cache; unmounting without a prior sync risks
    # data loss or a busy-target failure on removable media.
    sync

    if mountpoint -q "$USB_MOUNT_POINT" 2>/dev/null; then
        _usb_msg "unmounting $USB_MOUNT_POINT..."
        if ! sudo umount "$USB_MOUNT_POINT"; then
            _usb_err "unmount failed, files may still be in use"
            lsof +D "$USB_MOUNT_POINT" 2>/dev/null || echo "usb: could not list open files"
            return 1
        fi
    fi

    if [[ "$USB_ENV" == "wsl" ]]; then

        if [[ -d "$USB_MOUNT_POINT" ]]; then
            sudo rmdir "$USB_MOUNT_POINT" 2>/dev/null
        fi

        if [[ -n "$USB_DRIVE_LETTER" ]]; then
            _usb_msg "ejecting ${USB_DRIVE_LETTER}: from Windows..."
            _usb_ps "
                (New-Object -ComObject Shell.Application).NameSpace(17).ParseName('${USB_DRIVE_LETTER}:').InvokeVerb('Eject')
            "
            usb_drive_still_present=$(_usb_ps "Test-Path '${USB_DRIVE_LETTER}:'")
            if [[ "$usb_drive_still_present" == "True" ]]; then
                _usb_warn "Windows did not eject the drive, it may still be busy"
            else
                _usb_msg "drive ejected safely"
            fi
        fi

    else
        _usb_msg "unmounted, safe to unplug"
    fi

    _usb_clear_state
}

# usb_refresh -- re-source usb.sh with force argument to bypass cache
usb_refresh() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_refresh - re-detect USB and reload all project configurations
Usage:
  usb_refresh
Re-sources usb.sh with force to bypass cache.
EOF
        return 0
    fi

    if [[ ! -f "$USB_SCRIPT_PATH" ]]; then
        _usb_err "script not found at $USB_SCRIPT_PATH"
        _usb_msg "source usb.sh manually from its location"
        return 1
    fi
    _usb_msg "refreshing from $USB_SCRIPT_PATH..."
    # USB_SCRIPT_PATH is resolved at runtime; can't be followed statically
    # shellcheck source=/dev/null
    source "$USB_SCRIPT_PATH" force
    if [[ "$USB_CONNECTED" == true ]]; then
        _usb_msg "ready ($USB_ENV, mount: $USB_MOUNT_POINT)"
    else
        _usb_msg "ready ($USB_ENV, USB not connected)"
    fi
}

# usb_status -- print diagnostic information about USB state
# No arguments. Safe to call regardless of connection state.
usb_status() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_status - print diagnostic information about USB state
Usage:
  usb_status
Shows connection state, mount point, manifest info, and
per-project details including local_dir, repo_path, and
sync entry counts.
EOF
        return 0
    fi

    local usb_status_project_name
    local usb_status_project_name_upper
    local usb_status_local_dir_variable_name
    local usb_status_repo_path_variable_name
    local usb_status_sync_files_variable_name
    local usb_status_sync_dirs_variable_name
    echo "usb: status: connected=$USB_CONNECTED"
    echo "usb: status: environment=$USB_ENV"
    if [[ "$USB_CONNECTED" != true ]]; then
        return 0
    fi
    echo "usb: status: mount_point=$USB_MOUNT_POINT"
    if [[ -n "$USB_DRIVE_LETTER" ]]; then
        echo "usb: status: drive_letter=$USB_DRIVE_LETTER"
    fi
    echo "usb: status: manifest_version=$USB_MANIFEST_VERSION"
    echo "usb: status: label=$USB_LABEL"
    echo "usb: status: sync_log=$USB_SYNC_LOG"
    for usb_status_project_name in "${USB_LOADED_PROJECTS[@]}"; do
        usb_status_project_name_upper="${usb_status_project_name^^}"

        usb_status_local_dir_variable_name="USB_${usb_status_project_name_upper}_LOCAL_DIR"
        usb_status_repo_path_variable_name="USB_${usb_status_project_name_upper}_REPO_PATH"
        usb_status_sync_files_variable_name="USB_${usb_status_project_name_upper}_SYNC_FILES"
        usb_status_sync_dirs_variable_name="USB_${usb_status_project_name_upper}_SYNC_DIRS"

        declare -n usb_status_local_dir_ref="$usb_status_local_dir_variable_name"
        declare -n usb_status_repo_path_ref="$usb_status_repo_path_variable_name"
        declare -n usb_status_sync_files_ref="$usb_status_sync_files_variable_name"
        declare -n usb_status_sync_dirs_ref="$usb_status_sync_dirs_variable_name"

        echo "usb: status: project=$usb_status_project_name"
        echo "usb: status:   local_dir=$usb_status_local_dir_ref"
        echo "usb: status:   repo_path=$usb_status_repo_path_ref"
        echo "usb: status:   sync_files_count=${#usb_status_sync_files_ref[@]}"
        echo "usb: status:   sync_dirs_count=${#usb_status_sync_dirs_ref[@]}"

        unset -n usb_status_local_dir_ref
        unset -n usb_status_repo_path_ref
        unset -n usb_status_sync_files_ref
        unset -n usb_status_sync_dirs_ref
    done
}


# usb_ps1_indicator -- PS1 rendering helper for USB and key state
# Returns connectivity and key-load indicators.
# Called via $() substitution in prompt string, not a user command.
# No -h support: runs on every prompt render, must be zero-overhead.
usb_ps1_indicator() {
    local usb_ps1_usb_segment
    local usb_ps1_keys_segment

    if [[ "$USB_CONNECTED" == true ]]; then
        usb_ps1_usb_segment="usb[O]"
    else
        usb_ps1_usb_segment="usb[ ]"
    fi

    # Only show keys segment if USB is connected or keys are loaded.
    # Avoids cluttering prompt for sessions that never interact with keys.
    if [[ "$USB_CONNECTED" == true || "$USB_KEYS_LOADED" == true ]]; then
        if [[ "$USB_KEYS_LOADED" == true ]]; then
            usb_ps1_keys_segment="keys[O]"
        else
            usb_ps1_keys_segment="keys[ ]"
        fi
        echo "${usb_ps1_usb_segment}${usb_ps1_keys_segment}"
    else
        echo "$usb_ps1_usb_segment"
    fi
}

# usb_check -- validate conf files, check referenced paths, detect config drift
# No arguments. Requires USB_CONNECTED=true.
# Re-reads and parses conf files independently (same while-read pattern as
# LOAD). Compares configs/*.conf.reference against live USB copies.
# Reports only -- no copies, no exports, no state changes.
usb_check() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_check - validate conf files, check paths, and detect config drift
Usage:
  usb_check
Re-reads .usb-projects/*.conf on USB. Verifies local_dir,
repo_path, sync_file sources and destinations, and sync_dir
sources and destinations all exist. Compares configs/*.reference
against live USB copies. Reports errors.
EOF
        return 0
    fi
    local usb_check_conf_file_path
    local usb_check_project_name
    local usb_check_local_dir
    local usb_check_repo_path
    local usb_check_sync_files
    local usb_check_sync_dirs
    local usb_check_conf_key
    local usb_check_conf_value
    local usb_check_conf_line
    local usb_check_entry
    local usb_check_entry_source
    local usb_check_entry_dest
    local usb_check_entry_condition
    local usb_check_entry_extra
    local usb_check_entry_dest_dir
    local usb_check_entry_size
    local usb_check_local_branch
    local usb_check_bare_branch
    local usb_check_errors=0
    local usb_check_pair_sources=()
    local usb_check_pair_dests=()
    local usb_check_pair_projects=()
    local usb_check_pair_i
    local usb_check_pair_j

    if [[ "$USB_CONNECTED" != true ]]; then
        _usb_err "USB not connected, cannot check conf files"
        return 1
    fi

    for usb_check_conf_file_path in "$USB_MOUNT_POINT/.usb-projects/"*.conf; do
        if [[ ! -f "$usb_check_conf_file_path" ]]; then
            _usb_msg "check: no conf files found"
            break
        fi

        usb_check_local_dir=""
        usb_check_repo_path=""
        usb_check_sync_files=()
        usb_check_sync_dirs=()

        usb_check_project_name=$(basename "$usb_check_conf_file_path" .conf)
        _usb_msg "check: --- $usb_check_project_name ---"
        _usb_msg "check: conf=$usb_check_conf_file_path"

        while IFS= read -r usb_check_conf_line; do
            usb_check_conf_line="${usb_check_conf_line%$'\r'}"
            if [[ -z "$usb_check_conf_line" || "$usb_check_conf_line" == \#* ]]; then
                continue
            fi
            if [[ "$usb_check_conf_line" != *=* ]]; then
                _usb_warn "check: skipping malformed line (no '='): $usb_check_conf_line"
                continue
            fi
            usb_check_conf_key="${usb_check_conf_line%%=*}"
            usb_check_conf_value="${usb_check_conf_line#*=}"
            if [[ ! "$usb_check_conf_key" =~ ^[a-z][a-z0-9_]*$ ]]; then
                _usb_warn "check: skipping invalid key: $usb_check_conf_key"
                continue
            fi
            case "$usb_check_conf_key" in
                local_dir)
                    usb_check_local_dir="${usb_check_conf_value//\{HOME\}/$HOME}"
                    usb_check_local_dir="${usb_check_local_dir//\{WINDOWS_USER\}/$USB_WINDOWS_USER}"
                    ;;
                repo_path)
                    usb_check_repo_path="$usb_check_conf_value"
                    ;;
                sync_file)
                    usb_check_sync_files+=("$usb_check_conf_value")
                    ;;
                sync_dir)
                    usb_check_sync_dirs+=("$usb_check_conf_value")
                    ;;
                *)
                    _usb_msg "check: WARN unknown key: $usb_check_conf_key"
                    ;;
            esac
        done < "$usb_check_conf_file_path"

        if [[ -z "$usb_check_local_dir" ]]; then
            _usb_msg "check: ERROR local_dir missing"
            usb_check_errors=$((usb_check_errors + 1))
        else
            _usb_msg "check: local_dir=$usb_check_local_dir"
            if [[ -d "$usb_check_local_dir" ]]; then
                _usb_msg "check:   exists=yes"
            else
                _usb_msg "check:   exists=no"
                usb_check_errors=$((usb_check_errors + 1))
            fi
        fi

        if [[ -z "$usb_check_repo_path" ]]; then
            _usb_msg "check: ERROR repo_path missing"
            usb_check_errors=$((usb_check_errors + 1))
        else
            _usb_msg "check: repo_path=$usb_check_repo_path"
            if [[ -d "$USB_MOUNT_POINT/$usb_check_repo_path" ]]; then
                _usb_msg "check:   exists=yes"
            else
                _usb_msg "check:   exists=no"
                usb_check_errors=$((usb_check_errors + 1))
            fi
        fi

        if [[ -e "$usb_check_local_dir/.git" && -d "$USB_MOUNT_POINT/$usb_check_repo_path" ]]; then
            usb_check_local_branch=$(git -C "$usb_check_local_dir" symbolic-ref --short HEAD 2>/dev/null)
            usb_check_bare_branch=$(git -C "$USB_MOUNT_POINT/$usb_check_repo_path" symbolic-ref --short HEAD 2>/dev/null)
            if [[ -n "$usb_check_local_branch" && -n "$usb_check_bare_branch" ]]; then
                if [[ "$usb_check_local_branch" == "$usb_check_bare_branch" ]]; then
                    _usb_msg "check:   branch=$usb_check_local_branch (matches bare repo)"
                else
                    _usb_msg "check:   branch MISMATCH: local=$usb_check_local_branch bare=$usb_check_bare_branch"
                    usb_check_errors=$((usb_check_errors + 1))
                fi
            elif [[ -z "$usb_check_local_branch" ]]; then
                _usb_msg "check:   WARN could not detect local branch (detached HEAD?)"
            elif [[ -z "$usb_check_bare_branch" ]]; then
                _usb_msg "check:   WARN could not detect bare repo branch"
            fi
        fi

        for usb_check_entry in "${usb_check_sync_files[@]}"; do
            usb_check_entry="${usb_check_entry//\{USB_ROOT\}/$USB_MOUNT_POINT}"
            usb_check_entry="${usb_check_entry//\{LOCAL_DIR\}/$usb_check_local_dir}"
            IFS=: read -r usb_check_entry_source usb_check_entry_dest usb_check_entry_condition usb_check_entry_extra <<< "$usb_check_entry"
            _usb_msg "check: sync_file=$usb_check_entry_source -> $usb_check_entry_dest [$usb_check_entry_condition]"
            usb_check_pair_sources+=("$usb_check_entry_source")
            usb_check_pair_dests+=("$usb_check_entry_dest")
            usb_check_pair_projects+=("$usb_check_project_name")
            if [[ -n "$usb_check_entry_extra" ]]; then
                _usb_msg "check:   WARN extra field(s) after condition (phase model removed): $usb_check_entry_extra"
                usb_check_errors=$((usb_check_errors + 1))
            fi
            if [[ -f "$usb_check_entry_source" ]]; then
                _usb_msg "check:   source exists=yes"
            else
                _usb_msg "check:   source exists=no"
                usb_check_errors=$((usb_check_errors + 1))
            fi
            if [[ "$usb_check_entry_condition" == "differs" && -f "$usb_check_entry_source" ]]; then
                usb_check_entry_size=$(stat -c '%s' "$usb_check_entry_source" 2>/dev/null || echo 0)
                if [[ "$usb_check_entry_size" -gt "$USB_DIFFERS_SIZE_WARN" ]]; then
                    _usb_msg "check:   WARN differs source is large (${usb_check_entry_size} B > ${USB_DIFFERS_SIZE_WARN} B); a full cmp runs every sync"
                fi
            fi
            usb_check_entry_dest_dir=$(dirname "$usb_check_entry_dest")
            if [[ -d "$usb_check_entry_dest_dir" ]]; then
                _usb_msg "check:   dest dir exists=yes"
            else
                _usb_msg "check:   dest dir exists=no"
                usb_check_errors=$((usb_check_errors + 1))
            fi
        done

        for usb_check_entry in "${usb_check_sync_dirs[@]}"; do
            usb_check_entry="${usb_check_entry//\{USB_ROOT\}/$USB_MOUNT_POINT}"
            usb_check_entry="${usb_check_entry//\{LOCAL_DIR\}/$usb_check_local_dir}"
            IFS=: read -r usb_check_entry_source usb_check_entry_dest usb_check_entry_condition usb_check_entry_extra <<< "$usb_check_entry"
            _usb_msg "check: sync_dir=$usb_check_entry_source -> $usb_check_entry_dest [$usb_check_entry_condition]"
            usb_check_pair_sources+=("$usb_check_entry_source")
            usb_check_pair_dests+=("$usb_check_entry_dest")
            usb_check_pair_projects+=("$usb_check_project_name")
            if [[ -n "$usb_check_entry_extra" ]]; then
                _usb_msg "check:   WARN extra field(s) after condition (phase model removed): $usb_check_entry_extra"
                usb_check_errors=$((usb_check_errors + 1))
            fi
            if [[ -d "$usb_check_entry_source" ]]; then
                _usb_msg "check:   source dir exists=yes"
            else
                _usb_msg "check:   source dir exists=no"
                usb_check_errors=$((usb_check_errors + 1))
            fi
            if [[ -d "$usb_check_entry_dest" ]]; then
                _usb_msg "check:   dest dir exists=yes"
            else
                _usb_msg "check:   dest dir exists=no"
                usb_check_errors=$((usb_check_errors + 1))
            fi
done
    done
    # Config drift: compare configs/*.conf.reference against live USB copies.
    # Derives repo root from USB_SCRIPT_PATH using readlink -f to resolve symlinks.
    local usb_check_configs_dir
    usb_check_configs_dir="$(dirname "$(readlink -f "$USB_SCRIPT_PATH")")/configs"
    if [[ -d "$usb_check_configs_dir" ]]; then
        _usb_msg "check: --- config drift ---"
        if [[ -f "$usb_check_configs_dir/.usb-manifest.reference" ]]; then
            if ! cmp -s "$usb_check_configs_dir/.usb-manifest.reference" "$USB_MOUNT_POINT/$USB_MANIFEST_FILENAME"; then
                _usb_msg "check: WARN .usb-manifest has drifted from reference copy"
                usb_check_errors=$((usb_check_errors + 1))
            else
                _usb_msg "check: .usb-manifest matches reference"
            fi
        fi
        local usb_check_reference_file
        local usb_check_reference_basename
        local usb_check_conf_name
        local usb_check_usb_conf_path
        for usb_check_reference_file in "$usb_check_configs_dir"/*.conf.reference; do
            if [[ ! -f "$usb_check_reference_file" ]]; then
                break
            fi
            usb_check_reference_basename=$(basename "$usb_check_reference_file")
            usb_check_conf_name="${usb_check_reference_basename%.reference}"
            usb_check_usb_conf_path="$USB_MOUNT_POINT/.usb-projects/$usb_check_conf_name"
            if [[ ! -f "$usb_check_usb_conf_path" ]]; then
                _usb_msg "check: WARN $usb_check_conf_name has no USB counterpart"
                usb_check_errors=$((usb_check_errors + 1))
                continue
            fi
            if ! cmp -s "$usb_check_reference_file" "$usb_check_usb_conf_path"; then
                _usb_msg "check: WARN $usb_check_conf_name has drifted from reference copy"
                usb_check_errors=$((usb_check_errors + 1))
            else
                _usb_msg "check: $usb_check_conf_name matches reference"
            fi
        done
    fi
    # Ownership / relay analysis across every resolved (source -> dest) pair from
    # all confs. The relay is one-directional and each dest has one owner, so:
    #   - same source AND same dest  -> exact duplicate entry (ERROR)
    #   - same dest, different source -> two owners writing one path (ERROR)
    #   - reversed pair A:B and B:A   -> ping-pong / bidirectional relay (ERROR)
    # Same source with different dests is the allowed fan-out (one owner places a
    # shared file, many readers copy it out) and is intentionally not flagged.
    if [[ ${#usb_check_pair_dests[@]} -gt 1 ]]; then
        _usb_msg "check: --- ownership / relay ---"
        for ((usb_check_pair_i = 0; usb_check_pair_i < ${#usb_check_pair_dests[@]}; usb_check_pair_i++)); do
            for ((usb_check_pair_j = usb_check_pair_i + 1; usb_check_pair_j < ${#usb_check_pair_dests[@]}; usb_check_pair_j++)); do
                if [[ "${usb_check_pair_dests[usb_check_pair_i]}" == "${usb_check_pair_dests[usb_check_pair_j]}" ]]; then
                    if [[ "${usb_check_pair_sources[usb_check_pair_i]}" == "${usb_check_pair_sources[usb_check_pair_j]}" ]]; then
                        _usb_msg "check: ERROR duplicate sync entry: ${usb_check_pair_sources[usb_check_pair_i]} -> ${usb_check_pair_dests[usb_check_pair_i]} (${usb_check_pair_projects[usb_check_pair_i]}, ${usb_check_pair_projects[usb_check_pair_j]})"
                    else
                        _usb_msg "check: ERROR multiple sources write the same dest: ${usb_check_pair_dests[usb_check_pair_i]} (from ${usb_check_pair_sources[usb_check_pair_i]} in ${usb_check_pair_projects[usb_check_pair_i]}, ${usb_check_pair_sources[usb_check_pair_j]} in ${usb_check_pair_projects[usb_check_pair_j]})"
                    fi
                    usb_check_errors=$((usb_check_errors + 1))
                fi
                if [[ "${usb_check_pair_sources[usb_check_pair_i]}" == "${usb_check_pair_dests[usb_check_pair_j]}" \
                   && "${usb_check_pair_dests[usb_check_pair_i]}" == "${usb_check_pair_sources[usb_check_pair_j]}" ]]; then
                    _usb_msg "check: ERROR ping-pong (bidirectional relay): ${usb_check_pair_sources[usb_check_pair_i]} <-> ${usb_check_pair_dests[usb_check_pair_i]} (${usb_check_pair_projects[usb_check_pair_i]}, ${usb_check_pair_projects[usb_check_pair_j]})"
                    usb_check_errors=$((usb_check_errors + 1))
                fi
            done
        done
    fi
    if [[ "$usb_check_errors" -gt 0 ]]; then
        _usb_msg "check: $usb_check_errors error(s) found"
        return 1
    else
        _usb_msg "check: all checks passed"
        return 0
    fi
}

# usb_new_project -- create a new project conf via editor
# Arguments:
#   project_name -- lowercase, letters/digits/underscores, starts with letter
# Opens $EDITOR with a scaffold. Validates after editor exits.
# Atomic move from .tmp to .conf on success.
usb_new_project() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_new_project - create a new project configuration file
Usage:
  usb_new_project <name>
Name must start with a lowercase letter and contain only
lowercase letters, digits, and underscores. Opens editor
with a conf scaffold. Validates required keys (local_dir,
repo_path) after editor exits.
EOF
        return 0
    fi

    local usb_new_project_name="$1"
    local usb_new_project_conf_path
    local usb_new_project_tmp_path
    local usb_new_project_editor
    local usb_new_project_local_dir
    local usb_new_project_repo_path
    local usb_new_project_conf_key
    local usb_new_project_conf_value
    local usb_new_project_conf_line
    local usb_new_project_has_local_dir=false
    local usb_new_project_has_repo_path=false

    if [[ "$USB_CONNECTED" != true ]]; then
        _usb_err "USB not connected"
        return 1
    fi

    if [[ -z "$usb_new_project_name" ]]; then
        _usb_err "usage: usb_new_project <name>"
        return 1
    fi

    # Name becomes part of bash variable names (USB_<NAME>_*).
    # Must be valid identifier component: lowercase start, alphanumeric + underscore.
    if [[ ! "$usb_new_project_name" =~ ^[a-z][a-z0-9_]*$ ]]; then
        _usb_err "project name must start with a lowercase letter and contain only lowercase letters, digits, and underscores"
        return 1
    fi

    usb_new_project_conf_path="$USB_MOUNT_POINT/.usb-projects/${usb_new_project_name}.conf"

    if [[ -f "$usb_new_project_conf_path" ]]; then
        _usb_err "conf already exists: $usb_new_project_conf_path"
        return 1
    fi

    usb_new_project_editor="${EDITOR:-vi}"
    if ! command -v "$usb_new_project_editor" > /dev/null 2>&1; then
        _usb_err "editor not found: $usb_new_project_editor"
        _usb_msg "set EDITOR to a valid editor"
        return 1
    fi

    # Write scaffold to temp file on USB (same filesystem for atomic move)
    usb_new_project_tmp_path="${usb_new_project_conf_path}.tmp"

    cat > "$usb_new_project_tmp_path" << SCAFFOLD
# ${usb_new_project_name} project configuration
#
# Tokens resolved during loading:
#   {HOME}      -> user home directory
#   {USB_ROOT}  -> USB mount point
#   {LOCAL_DIR} -> resolved local_dir value
#
# sync_file format: src:dest:condition
#   condition: newer (copy if source is newer than dest) or
#              differs (copy if source and dest differ)
#
# sync_dir format: src:dest:condition
#   Same as sync_file but syncs all files in directory recursively.

local_dir={HOME}/personal_repos/${usb_new_project_name}
repo_path=personal_repos/${usb_new_project_name}.git
# sync_file={USB_ROOT}/shared/example.txt:{LOCAL_DIR}/example.txt:newer:auto
# sync_dir={USB_ROOT}/shared/docs:{LOCAL_DIR}/docs:newer:auto
SCAFFOLD

    _usb_msg "opening editor: $usb_new_project_editor"
    "$usb_new_project_editor" "$usb_new_project_tmp_path"

    if [[ ! -f "$usb_new_project_tmp_path" ]]; then
        _usb_err "temp file removed, aborting"
        return 1
    fi

    # Validate conf after editor exits
    while IFS= read -r usb_new_project_conf_line; do
        usb_new_project_conf_line="${usb_new_project_conf_line%$'\r'}"
        if [[ -z "$usb_new_project_conf_line" || "$usb_new_project_conf_line" == \#* ]]; then
            continue
        fi
        if [[ "$usb_new_project_conf_line" != *=* ]]; then
            _usb_warn "skipping malformed line (no '='): $usb_new_project_conf_line"
            continue
        fi
        usb_new_project_conf_key="${usb_new_project_conf_line%%=*}"
        usb_new_project_conf_value="${usb_new_project_conf_line#*=}"
        if [[ ! "$usb_new_project_conf_key" =~ ^[a-z][a-z0-9_]*$ ]]; then
            _usb_warn "skipping invalid key: $usb_new_project_conf_key"
            continue
        fi
        case "$usb_new_project_conf_key" in
            local_dir)
                usb_new_project_has_local_dir=true
                usb_new_project_local_dir="${usb_new_project_conf_value//\{HOME\}/$HOME}"
                usb_new_project_local_dir="${usb_new_project_local_dir//\{WINDOWS_USER\}/$USB_WINDOWS_USER}"
                ;;
            repo_path)
                usb_new_project_has_repo_path=true
                usb_new_project_repo_path="$usb_new_project_conf_value"
                ;;
            sync_file|sync_dir)
                ;;
            *)
                _usb_warn "unknown key: $usb_new_project_conf_key"
                ;;
        esac
    done < "$usb_new_project_tmp_path"

    if [[ "$usb_new_project_has_local_dir" == false || "$usb_new_project_has_repo_path" == false ]]; then
        _usb_err "conf missing required key(s):"
        if [[ "$usb_new_project_has_local_dir" == false ]]; then
            _usb_err "  local_dir"
        fi
        if [[ "$usb_new_project_has_repo_path" == false ]]; then
            _usb_err "  repo_path"
        fi
        _usb_msg "temp file kept at: $usb_new_project_tmp_path"
        _usb_msg "fix and rename manually, or remove and try again"
        return 1
    fi

    if [[ ! -d "$usb_new_project_local_dir" ]]; then
        _usb_warn "local_dir does not exist: $usb_new_project_local_dir"
    fi
    if [[ ! -d "$USB_MOUNT_POINT/$usb_new_project_repo_path" ]]; then
        _usb_warn "repo_path does not exist on USB: $usb_new_project_repo_path"
    fi

    mv "$usb_new_project_tmp_path" "$usb_new_project_conf_path"
    _usb_msg "created $usb_new_project_conf_path"
    _usb_msg "run usb_refresh to load the new project"
}

# =============================================================================
# KEYS -- Encrypted API key management
#
# Stores GPG-encrypted key-value pairs on USB (.keys/env.gpg), decrypts
# on-demand into shell environment variables, cleans up on session end.
#
# REQUIREMENTS:
#   - GPG 2.x with allow-loopback-pinentry in ~/.gnupg/gpg-agent.conf
#   - /dev/shm available (tmpfs, RAM-only) for plaintext during editing
#   - After changing gpg-agent.conf: gpgconf --kill gpg-agent
#
# FUTURE:
#   - Per-project key files (.keys/<project>.gpg, loaded via usb_load_keys <project>)
#   - gpg-agent cache TTL enforcement (default-cache-ttl 0) for stricter security
#   - PROMPT_COMMAND revocation guard for tmux multi-pane auto-unload
#   - Pre-commit hook installer for API key pattern detection
#   - Note: shred is ineffective on 9p/NTFS (USB filesystem), effective on /dev/shm (tmpfs)
#   - Note: pinentry-curses is unreliable in tmux; --pinentry-mode loopback is required
# DESIGN: Keys are NOT a usb-sh project. Projects have local_dir, repo_path,
#   and participate in commit/push/pull. Keys have none of these. .keys/ is a
#   peer directory to .usb-projects/ with its own simpler contract.
#
# MULTI-PANE: Each tmux pane is a separate shell. usb_load_keys must be called
#   independently in each pane that needs keys. usb_shutdown kills all panes.
#
# MODULE BOUNDARY (commit 12): this section's only external inputs are
#   USB_MOUNT_POINT (read exactly once, immediately below, to derive
#   USB_KEYS_FILE) and usb_verify_connected (host-provided availability check
#   called by every action function). The section owns its state
#   (USB_KEYS_LOADED, _USB_LOADED_KEY_NAMES, initialized below). One allowed
#   reverse edge: the host calls usb_unload_keys during teardown (usb_shutdown
#   and the eject paths).
# =============================================================================

# Keys state (moved here in commit 12; previously in the top-level state block).
# Initialize only if unset: usb_refresh re-sources with "force", bypassing the
# already-initialized guard. Unconditional resets here would wipe key
# bookkeeping while the secrets remain exported in the environment, leaving
# usb_unload_keys unable to remove them (orphaned secrets).
#   USB_KEYS_LOADED: true/false, whether keys are currently in environment.
#   _USB_LOADED_KEY_NAMES: names exported by usb_load_keys, for clean unload.
: "${USB_KEYS_LOADED:=false}"
declare -p _USB_LOADED_KEY_NAMES >/dev/null 2>&1 || _USB_LOADED_KEY_NAMES=()

# USB_KEYS_FILE: the single on-USB key-file path, derived once per source pass
# from USB_MOUNT_POINT (set by detection above; re-derived on every usb_refresh).
# Drive-scope: swept in _usb_clear_state. Not exported -- consumed only by keys
# functions in this shell, and gpg receives the path as an argument, not via the
# environment. When disconnected USB_MOUNT_POINT is unset and this holds a
# placeholder that no function reads: every consumer gates on
# usb_verify_connected (init/edit/load) or USB_CONNECTED (usb_keys_status).
USB_KEYS_FILE="$USB_MOUNT_POINT/.keys/env.gpg"

# _usb_gpg_check -- verify GPG loopback pinentry is available
# Returns 0 if ready, 1 with actionable error if not.
# Called by every function that invokes GPG. Cost: one grep per call.

_usb_gpg_check() {
    if ! command -v gpg > /dev/null 2>&1; then
        _usb_err "gpg command not found"
        return 1
    fi

    if [[ ! -d "$HOME/.gnupg" ]]; then
        echo "usb[ERROR]: ~/.gnupg directory not found"
        echo "usb: run: mkdir -p ~/.gnupg && chmod 700 ~/.gnupg"
        return 1
    fi

    local usb_gpg_check_perms
    usb_gpg_check_perms=$(stat -c '%a' "$HOME/.gnupg" 2>/dev/null)
    if [[ "$usb_gpg_check_perms" != "700" ]]; then
        echo "usb[ERROR]: ~/.gnupg has unsafe permissions ($usb_gpg_check_perms, need 700)"
        echo "usb: run: chmod 700 ~/.gnupg && chmod 600 ~/.gnupg/*"
        return 1
    fi

    if [[ ! -f "$HOME/.gnupg/gpg-agent.conf" ]]; then
        echo "usb[ERROR]: ~/.gnupg/gpg-agent.conf not found"
        _usb_msg "create it with:"
        echo "usb:   printf '%s\\n' 'pinentry-program /usr/bin/pinentry-curses' 'allow-loopback-pinentry' > ~/.gnupg/gpg-agent.conf"
        _usb_msg "  gpgconf --kill gpg-agent"
        return 1
    fi

    if ! grep -q "^allow-loopback-pinentry" "$HOME/.gnupg/gpg-agent.conf" 2>/dev/null; then
        _usb_err "GPG loopback pinentry not enabled"
        echo "usb: add 'allow-loopback-pinentry' to ~/.gnupg/gpg-agent.conf"
        _usb_msg "then run: gpgconf --kill gpg-agent"
        return 1
    fi

    return 0
}

# _usb_check_editor_safety -- warn if editor may leak plaintext to disk
# Checks for nvim/vim undo, swap, and backup persistence on /dev/shm paths.
# Returns 0 always (warning only, does not block).
_usb_check_editor_safety() {
    local usb_check_editor_name
    local usb_check_editor_config
    local usb_check_editor_warnings=0

    usb_check_editor_name=$(basename "${EDITOR:-vi}")

    case "$usb_check_editor_name" in
        nvim)
            # Check init.lua first, then init.vim
            usb_check_editor_config=""
            if [[ -f "$HOME/.config/nvim/init.lua" ]]; then
                usb_check_editor_config="$HOME/.config/nvim/init.lua"
                if ! grep -q "/dev/shm" "$usb_check_editor_config" 2>/dev/null; then
                    usb_check_editor_warnings=1
                fi
            elif [[ -f "$HOME/.config/nvim/init.vim" ]]; then
                usb_check_editor_config="$HOME/.config/nvim/init.vim"
                if ! grep -q "/dev/shm" "$usb_check_editor_config" 2>/dev/null; then
                    usb_check_editor_warnings=1
                fi
            else
                usb_check_editor_warnings=1
            fi

            if [[ "$usb_check_editor_warnings" -eq 1 ]]; then
                _usb_warn "nvim may write plaintext to disk (swap, undo, backup files)"
                echo "usb[WARN]: add /dev/shm autocmd to ${usb_check_editor_config:-~/.config/nvim/init.lua}"
                _usb_warn "see .keys/README or usb-sh docs for the required config"
            fi
            ;;
        vim)
            usb_check_editor_config="$HOME/.vimrc"
            if [[ -f "$usb_check_editor_config" ]]; then
                if ! grep -q "/dev/shm" "$usb_check_editor_config" 2>/dev/null; then
                    usb_check_editor_warnings=1
                fi
            else
                usb_check_editor_warnings=1
            fi

            if [[ "$usb_check_editor_warnings" -eq 1 ]]; then
                _usb_warn "vim may write plaintext to disk (swap, undo, backup files)"
                _usb_warn "add /dev/shm autocmd to ${usb_check_editor_config}"
                _usb_warn "see .keys/README or usb-sh docs for the required config"
            fi
            ;;
        vi|nano)
            # Generally safe by default, no warning needed
            ;;
        *)
            _usb_warn "unknown editor '$usb_check_editor_name' -- verify it does not"
            _usb_warn "write swap, undo, or backup files for /dev/shm paths"
            ;;
    esac

    # Check for existing leaked undo/swap files from previous sessions
    local usb_check_leaked_files
    usb_check_leaked_files=$(find \
        "$HOME/.local/state/nvim/undo" \
        "$HOME/.local/state/nvim/swap" \
        "$HOME/.local/share/nvim/swap" \
        "$HOME/.vim/undodir" \
        "$HOME/.vim/swap" \
        -name "*shm*" -o -name "*usb_keys*" \
        2>/dev/null)

    if [[ -n "$usb_check_leaked_files" ]]; then
        _usb_warn "found editor residue files that may contain plaintext keys:"
        echo "$usb_check_leaked_files"
        _usb_warn "review and delete these files with: shred -u <file>"
    fi

    return 0
}

# _usb_gpg_encrypt -- encrypt a file with GPG symmetric AES256
# Arguments:
#   $1 -- output path (.gpg file)
#   $2 -- input path (plaintext file)
# Uses --pinentry-mode loopback for tmux compatibility.
# Caller must check return code.
_usb_gpg_encrypt() {
    gpg --symmetric --cipher-algo AES256 --pinentry-mode loopback --yes --output "$1" "$2"
}

# _usb_gpg_decrypt -- decrypt a GPG file to stdout
# Arguments:
#   $1 -- input path (.gpg file)
# Uses --pinentry-mode loopback for tmux compatibility.
# Output goes to stdout; caller captures or redirects.
# Caller must check return code.
_usb_gpg_decrypt() {
    gpg --quiet --decrypt --pinentry-mode loopback "$1"
}

# _usb_gpg_decrypt_to_file -- decrypt a GPG file to a specified output path
# Arguments:
#   $1 -- input path (.gpg file)
#   $2 -- output path (plaintext file)
# Uses --pinentry-mode loopback for tmux compatibility.
# Caller must check return code.
_usb_gpg_decrypt_to_file() {
    gpg --quiet --decrypt --pinentry-mode loopback --output "$2" "$1"
}

# usb_init_keys -- first-time setup of encrypted key file on USB
# Creates .keys/env.gpg via editor + GPG encryption.
# Plaintext only exists on /dev/shm (tmpfs) during editing.
usb_init_keys() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_init_keys - create encrypted API key file on USB
Usage:
  usb_init_keys
First-time setup. Opens editor with a scaffold, encrypts the
result to .keys/env.gpg on USB. Use usb_edit_keys to modify
an existing file.
Requires: USB connected, GPG with loopback pinentry enabled.
EOF
        return 0
    fi


    if ! _usb_gpg_check; then
        return 1
    fi

    if [[ ! -d /dev/shm || ! -w /dev/shm ]]; then
        _usb_err "/dev/shm is not available or not writable"
        _usb_msg "required as tmpfs for plaintext during editing"
        return 1
    fi

    if ! usb_verify_connected; then
        _usb_err "USB not connected"
        return 1
    fi

    local usb_init_keys_gpg_path="$USB_KEYS_FILE"
    local usb_init_keys_tmp_path="/dev/shm/usb_keys_init_$$"
    local usb_init_keys_editor
    local usb_init_keys_has_valid_line

    trap 'shred -u "$usb_init_keys_tmp_path" 2>/dev/null; trap - RETURN' RETURN

    if [[ -f "$usb_init_keys_gpg_path" ]]; then
        _usb_err ".keys/env.gpg already exists"
        _usb_msg "use usb_edit_keys to modify, or remove manually and re-run"
        return 1
    fi

    usb_init_keys_editor="${EDITOR:-vi}"
    if ! command -v "$usb_init_keys_editor" > /dev/null 2>&1; then
        _usb_err "editor not found: $usb_init_keys_editor"
        _usb_msg "set EDITOR to a valid editor"
        return 1
    fi

    mkdir -p "${USB_KEYS_FILE%/*}"

    # Write scaffold to tmpfs (RAM-only, never hits disk)
    cat > "$usb_init_keys_tmp_path" << 'SCAFFOLD'
# API keys - one per line, KEY=value format
# Blank lines and lines starting with # are skipped
# Values are everything after the first = (may contain = signs)
# Example:
# ANTHROPIC_API_KEY=sk-ant-api03-xxxxxxxxxxxx
SCAFFOLD

    chmod 600 "$usb_init_keys_tmp_path"

    _usb_check_editor_safety
    _usb_msg "opening editor: $usb_init_keys_editor"
    "$usb_init_keys_editor" "$usb_init_keys_tmp_path"

    if [[ ! -f "$usb_init_keys_tmp_path" ]]; then
        _usb_err "temp file removed, aborting"
        return 1
    fi

    # Validate: at least one KEY=value line
    usb_init_keys_has_valid_line=false
    while IFS= read -r usb_init_keys_line; do
        usb_init_keys_line="${usb_init_keys_line%$'\r'}"
        if [[ -z "$usb_init_keys_line" || "$usb_init_keys_line" == \#* ]]; then
            continue
        fi
        if [[ "$usb_init_keys_line" != *=* ]]; then
            _usb_warn "skipping malformed line (no '='): $usb_init_keys_line"
            continue
        fi
        usb_init_keys_key="${usb_init_keys_line%%=*}"
        usb_init_keys_value="${usb_init_keys_line#*=}"
        if [[ ! "$usb_init_keys_key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            _usb_warn "skipping invalid key: $usb_init_keys_key"
            continue
        fi
        if [[ -n "$usb_init_keys_value" ]]; then
            usb_init_keys_has_valid_line=true
            break
        fi
    done < "$usb_init_keys_tmp_path"

    if [[ "$usb_init_keys_has_valid_line" == false ]]; then
        _usb_err "no valid KEY=value lines found"
        shred -u "$usb_init_keys_tmp_path" 2>/dev/null || rm -f "$usb_init_keys_tmp_path"
        return 1
    fi

    # Encrypt to USB
    if ! _usb_gpg_encrypt "$usb_init_keys_gpg_path" "$usb_init_keys_tmp_path"; then
        _usb_err "GPG encryption failed (passphrase cancelled?)"
        shred -u "$usb_init_keys_tmp_path" 2>/dev/null || rm -f "$usb_init_keys_tmp_path"
        return 1
    fi

    # Shred plaintext from tmpfs
    shred -u "$usb_init_keys_tmp_path" 2>/dev/null || rm -f "$usb_init_keys_tmp_path"

    # Write README if it doesn't exist
    if [[ ! -f "${USB_KEYS_FILE%/*}/README" ]]; then
        cat > "${USB_KEYS_FILE%/*}/README" << 'README'
# .keys/ - Encrypted API Key Storage
#
# File: env.gpg
#   GPG symmetric AES256-encrypted key-value file.
#   Format: KEY=value, one per line. Comments (#) and blank lines skipped.
#   Values are everything after the first = (may contain = signs).
#
# Commands:
#   usb_init_keys    - first-time creation (refuses if env.gpg exists)
#   usb_edit_keys    - decrypt, edit, re-encrypt cycle
#   usb_load_keys    - decrypt and export as environment variables
#   usb_unload_keys  - remove keys from environment
#   usb_keys_status  - show current key state
#   usb_shutdown     - unload keys and eject USB
#
# Security:
#   - Plaintext only exists on /dev/shm (tmpfs, RAM-only) during editing
#   - shred -u is used on /dev/shm files after encryption
#   - USB filesystem is 9p/NTFS; only the .gpg file is written there
#   - Keys in environment vanish when shell exits or usb_unload_keys runs
#
# GPG Setup Required:
#   ~/.gnupg/gpg-agent.conf must contain:
#     pinentry-program /usr/bin/pinentry-curses
#     allow-loopback-pinentry
#   After editing: gpgconf --kill gpg-agent
#   Shell must export: GPG_TTY=$(tty)
README
    fi

    _usb_msg "keys initialized at $usb_init_keys_gpg_path"
}

# usb_edit_keys -- decrypt, edit, and re-encrypt the key file
# Plaintext only exists on /dev/shm (tmpfs) during editing.
# If re-encryption fails, tmpfs file is preserved for recovery.
usb_edit_keys() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_edit_keys - edit the encrypted API key file
Usage:
  usb_edit_keys
Decrypts .keys/env.gpg to /dev/shm, opens editor, re-encrypts.
If no changes are made, skips re-encryption.
If re-encryption fails, the tmpfs file is preserved (path printed).
Requires: USB connected, .keys/env.gpg exists.
EOF
        return 0
    fi

    if ! _usb_gpg_check; then
        return 1
    fi

    if [[ ! -d /dev/shm || ! -w /dev/shm ]]; then
        _usb_err "/dev/shm is not available or not writable"
        _usb_msg "required as tmpfs for plaintext during editing"
        return 1
    fi

    if ! usb_verify_connected; then
        _usb_err "USB not connected"
        return 1
    fi

    local usb_edit_keys_gpg_path="$USB_KEYS_FILE"
    local usb_edit_keys_tmp_path="/dev/shm/usb_keys_edit_$$"
    local usb_edit_keys_editor
    local usb_edit_keys_checksum_before
    local usb_edit_keys_checksum_after
    local usb_edit_keys_has_valid_line

    if [[ ! -f "$usb_edit_keys_gpg_path" ]]; then
        _usb_err ".keys/env.gpg not found"
        _usb_msg "run usb_init_keys to create it"
        return 1
    fi

    usb_edit_keys_editor="${EDITOR:-vi}"
    if ! command -v "$usb_edit_keys_editor" > /dev/null 2>&1; then
        _usb_err "editor not found: $usb_edit_keys_editor"
        _usb_msg "set EDITOR to a valid editor"
        return 1
    fi

    # Decrypt to tmpfs
    if ! _usb_gpg_decrypt_to_file "$usb_edit_keys_gpg_path" "$usb_edit_keys_tmp_path"; then
        _usb_err "GPG decryption failed (wrong passphrase or cancelled)"
        rm -f "$usb_edit_keys_tmp_path" 2>/dev/null
        return 1
    fi

    chmod 600 "$usb_edit_keys_tmp_path"

    # Checksum before edit
    usb_edit_keys_checksum_before=$(sha256sum "$usb_edit_keys_tmp_path" | cut -d' ' -f1)

    _usb_check_editor_safety
    _usb_msg "opening editor: $usb_edit_keys_editor"
    "$usb_edit_keys_editor" "$usb_edit_keys_tmp_path"

    if [[ ! -f "$usb_edit_keys_tmp_path" ]]; then
        _usb_err "temp file removed during editing, aborting"
        return 1
    fi

    # Checksum after edit
    usb_edit_keys_checksum_after=$(sha256sum "$usb_edit_keys_tmp_path" | cut -d' ' -f1)

    if [[ "$usb_edit_keys_checksum_before" == "$usb_edit_keys_checksum_after" ]]; then
        _usb_msg "no changes detected, skipping re-encryption"
        shred -u "$usb_edit_keys_tmp_path" 2>/dev/null || rm -f "$usb_edit_keys_tmp_path"
        return 0
    fi

    # Validate: at least one KEY=value line
    usb_edit_keys_has_valid_line=false
    while IFS= read -r usb_edit_keys_line; do
        # Strip carriage return (CRLF from Windows/NTFS round-trips)
        usb_edit_keys_line="${usb_edit_keys_line%$'\r'}"
        if [[ -z "$usb_edit_keys_line" || "$usb_edit_keys_line" == \#* ]]; then
            continue
        fi
        if [[ "$usb_edit_keys_line" != *=* ]]; then
            _usb_warn "skipping malformed line (no '='): $usb_edit_keys_line"
            continue
        fi
        usb_edit_keys_key="${usb_edit_keys_line%%=*}"
        usb_edit_keys_value="${usb_edit_keys_line#*=}"
        if [[ ! "$usb_edit_keys_key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            _usb_warn "skipping invalid key: $usb_edit_keys_key"
            continue
        fi
        if [[ -n "$usb_edit_keys_value" ]]; then
            usb_edit_keys_has_valid_line=true
            break
        fi
    done < "$usb_edit_keys_tmp_path"

    if [[ "$usb_edit_keys_has_valid_line" == false ]]; then
        _usb_err "no valid KEY=value lines found after edit"
        _usb_msg "tmpfs file preserved for recovery: $usb_edit_keys_tmp_path"
        return 1
    fi

    # Re-encrypt to USB
    if ! _usb_gpg_encrypt "$usb_edit_keys_gpg_path" "$usb_edit_keys_tmp_path"; then
        _usb_err "GPG re-encryption failed (passphrase cancelled?)"
        _usb_msg "tmpfs file preserved for recovery: $usb_edit_keys_tmp_path"
        return 1
    fi

    # Shred plaintext from tmpfs
    shred -u "$usb_edit_keys_tmp_path" 2>/dev/null || rm -f "$usb_edit_keys_tmp_path"

    if [[ "$USB_KEYS_LOADED" == true ]]; then
        _usb_warn "loaded keys are now stale, run usb_load_keys to reload"
    fi

    _usb_msg "keys updated at $usb_edit_keys_gpg_path"
}

# usb_load_keys -- decrypt key file and export as environment variables
# Decrypts to a shell variable (never tmpfs), parses, exports each key.
# Tracks exported names in _USB_LOADED_KEY_NAMES for clean unload.
usb_load_keys() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_load_keys - load encrypted API keys into environment
Usage:
  usb_load_keys
Decrypts .keys/env.gpg and exports each KEY=value pair as an
environment variable. Tracks loaded names for usb_unload_keys.
If keys are already loaded, unloads first (clean reload).
Requires: USB connected, .keys/env.gpg exists.
EOF
        return 0
    fi

    if ! _usb_gpg_check; then
        return 1
    fi

    if ! usb_verify_connected; then
        _usb_err "USB not connected"
        return 1
    fi

    local usb_load_keys_gpg_path="$USB_KEYS_FILE"
    local usb_load_keys_decrypted
    local usb_load_keys_key
    local usb_load_keys_value
    local usb_load_keys_count=0

    if [[ ! -f "$usb_load_keys_gpg_path" ]]; then
        _usb_err ".keys/env.gpg not found"
        _usb_msg "run usb_init_keys to create it"
        return 1
    fi

    # Clean reload if already loaded
    if [[ "$USB_KEYS_LOADED" == true ]]; then
        usb_unload_keys
    fi

    # Decrypt to variable. GPG prompts on /dev/tty via loopback,
    # stdout (decrypted content) is captured by $(...).
    # Stderr passes through to user for error visibility.
    usb_load_keys_decrypted=$(_usb_gpg_decrypt "$usb_load_keys_gpg_path")

    if [[ $? -ne 0 || -z "$usb_load_keys_decrypted" ]]; then
        _usb_err "GPG decryption failed (wrong passphrase or cancelled)"
        unset usb_load_keys_decrypted
        return 1
    fi

    _USB_LOADED_KEY_NAMES=()

    while IFS= read -r usb_load_keys_line; do
        # Strip carriage return (CRLF from Windows/NTFS round-trips)
        usb_load_keys_line="${usb_load_keys_line%$'\r'}"
        if [[ -z "$usb_load_keys_line" || "$usb_load_keys_line" == \#* ]]; then
            continue
        fi
        if [[ "$usb_load_keys_line" != *=* ]]; then
            _usb_warn "skipping malformed line (no '='): $usb_load_keys_line"
            continue
        fi
        # Split on the FIRST '=' via expansion, not IFS='=' read: read strips a
        # single trailing '=' from the value, truncating base64-padded secrets.
        usb_load_keys_key="${usb_load_keys_line%%=*}"
        usb_load_keys_value="${usb_load_keys_line#*=}"
        if [[ ! "$usb_load_keys_key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            _usb_warn "skipping invalid key: $usb_load_keys_key"
            continue
        fi
        if [[ -z "$usb_load_keys_value" ]]; then
            continue
        fi

        # Note: export "$key=$value" is safe for API key values (base64 alphabet).
        # If values with spaces, quotes, or $ are ever needed, use declare -gx instead.
        export "$usb_load_keys_key=$usb_load_keys_value"
        _USB_LOADED_KEY_NAMES+=("$usb_load_keys_key")
        usb_load_keys_count=$((usb_load_keys_count + 1))
    done <<< "$usb_load_keys_decrypted"

    # Kill plaintext from memory
    unset usb_load_keys_decrypted

    USB_KEYS_LOADED=true
    _usb_msg "loaded $usb_load_keys_count key(s) into environment"
}

# usb_unload_keys -- remove loaded API keys from environment
# Iterates _USB_LOADED_KEY_NAMES and unsets each. Idempotent.
usb_unload_keys() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_unload_keys - remove API keys from environment
Usage:
  usb_unload_keys
Unsets all environment variables loaded by usb_load_keys.
Safe to call multiple times (idempotent).
EOF
        return 0
    fi

    local usb_unload_keys_name

    if [[ "$USB_KEYS_LOADED" != true ]]; then
        _usb_msg "no keys loaded"
        return 0
    fi

    for usb_unload_keys_name in "${_USB_LOADED_KEY_NAMES[@]}"; do
        unset "$usb_unload_keys_name"
    done

    _USB_LOADED_KEY_NAMES=()
    USB_KEYS_LOADED=false
    _usb_msg "keys removed from environment"
}

# usb_keys_status -- report current key management state
usb_keys_status() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_keys_status - show API key management state
Usage:
  usb_keys_status
Reports: loaded state, count, variable names (never values),
source file path, and GPG loopback availability.
EOF
        return 0
    fi

    local usb_keys_status_gpg_loopback

    echo "usb: keys: loaded=$USB_KEYS_LOADED"
    echo "usb: keys: count=${#_USB_LOADED_KEY_NAMES[@]}"

    if [[ ${#_USB_LOADED_KEY_NAMES[@]} -gt 0 ]]; then
        echo "usb: keys: names=${_USB_LOADED_KEY_NAMES[*]}"
    fi

    if [[ "$USB_CONNECTED" == true ]]; then
        echo "usb: keys: source=$USB_KEYS_FILE"
        if [[ -f "$USB_KEYS_FILE" ]]; then
            echo "usb: keys: file=present"
        else
            echo "usb: keys: file=missing"
        fi
    else
        echo "usb: keys: source=unavailable (USB not connected)"
    fi

    if _usb_gpg_check > /dev/null 2>&1; then
        usb_keys_status_gpg_loopback="available"
    else
        usb_keys_status_gpg_loopback="unavailable"
    fi
    echo "usb: keys: gpg_loopback=$usb_keys_status_gpg_loopback"
}

# usb_shutdown -- unload keys and eject USB (this module's session teardown).
# Does NOT call exit and does NOT kill tmux: session-lifecycle policy lives in
# the user's shell, not this module. Compose it in ~/.bashrc if wanted, e.g.:
#   session_end() { usb_shutdown && tmux kill-server; }
usb_shutdown() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<'EOF'
usb_shutdown - unload keys and eject USB
Usage:
  usb_shutdown
Unloads keys and ejects USB (if connected). Does not call exit and does not
kill tmux. To also end a tmux session, compose in ~/.bashrc:
  session_end() { usb_shutdown && tmux kill-server; }
EOF
        return 0
    fi

    usb_unload_keys

    if [[ "$USB_CONNECTED" == true ]]; then
        usb_eject
    fi
}

# =============================================================================
# SYNC -- Execute sync_files entries for auto and always phases on startup
# Requires: USB_CONNECTED=true, USB_LOADED_PROJECTS non-empty
# =============================================================================

if [[ "$USB_CONNECTED" == true ]]; then
    if [[ ${#USB_LOADED_PROJECTS[@]} -gt 0 ]]; then
        for usb_startup_project_name in "${USB_LOADED_PROJECTS[@]}"; do
            _usb_run_sync "$usb_startup_project_name"
        done
        unset usb_startup_project_name

    fi
fi

# =============================================================================
# PS1 -- USB connectivity indicator in prompt
# MC_PS1 is the composable prompt variable used by the bash/ infrastructure.
# The contains-check prevents duplicate prepending on usb_refresh.
# =============================================================================
if [[ -z "$MC_PS1" ]]; then
    MC_PS1='\u@\h:\w\$ '
fi
if [[ "$MC_PS1" != *'usb_ps1_indicator'* ]]; then
    MC_PS1='$(usb_ps1_indicator)'"${MC_PS1}"
fi
export PS1="$MC_PS1"

USB_INITIALIZED=true
