#!/usr/bin/env bash
# usb.sh -- USB detection, project configuration loading, and file synchronization.
# Source this file. Do not execute directly.
# Projects source usb.sh and compose on top of it.
# Note: FUNCTIONS section must precede SYNC section because SYNC calls
# _usb_run_sync_files at source time.
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
#   USB_DEFAULT_PHASE    -- "auto", "manual", or "always", from .usb-manifest
#   USB_SYNC_LOG         -- absolute path to sync log file, from .usb-manifest
#   USB_LOADED_PROJECTS  -- indexed array of loaded project names
#   USB_DRIVE_LETTER     -- Windows drive letter for WSL eject, set if USB found on WSL
#
# Per-project variables set during LOAD phase.
# Replace KBD with the uppercased project name (e.g. FINANCES, SM2).
#
#   USB_KBD_LOCAL_DIR    -- absolute path to local project directory
#   USB_KBD_REPO_PATH    -- relative path to bare git repo on USB, metadata only
#   USB_KBD_SYNC_FILES   -- indexed array of resolved sync_files entries
#   USB_KBD_SYNC_DIRS    -- indexed array of resolved sync_dirs entries
#
# sync_files entry format: src:dest:condition:phase
#   condition -- "newer" (copy if src is newer than dest)
#   phase     -- "auto", "manual", or "always"
#
# =============================================================================

if [[ "${BASH_VERSINFO[0]}" -lt 4 || ( "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -lt 3 ) ]]; then
    echo "usb[ERROR]: bash 4.3+ required (found ${BASH_VERSION})"
    return 1 2>/dev/null || exit 1
fi

USB_SCRIPT_PATH="${BASH_SOURCE[0]}"
if [[ "$USB_INITIALIZED" == true && "$1" != "force" ]]; then
    echo "usb[WARN]: already initialized (connected=$USB_CONNECTED, source=$(caller 0 2>/dev/null || echo unknown))"
    echo "usb[WARN]: usb.sh should be sourced once from bash/06_usb.sh, use 'force' to re-run"
    return 0
fi

# =============================================================================
# FIND -- USB hardware detection
# Sets: USB_CONNECTED, USB_MOUNT_POINT, USB_ENV, USB_DRIVE_LETTER
# =============================================================================

USB_CACHE_FILE="/tmp/usb_drive_cache"
USB_MANIFEST_FILENAME=".usb-manifest"
export USB_CONNECTED=false
unset USB_MOUNT_POINT
unset USB_DRIVE_LETTER

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
        echo "usb: cache hit  $USB_CACHE_FILE"
        USB_CACHED_DRIVE_LETTER=$(cat "$USB_CACHE_FILE")
        USB_POTENTIAL_MOUNT_POINT="/mnt/${USB_CACHED_DRIVE_LETTER,,}"

        if [[ -f "$USB_POTENTIAL_MOUNT_POINT/$USB_MANIFEST_FILENAME" ]]; then
            export USB_DRIVE_LETTER="$USB_CACHED_DRIVE_LETTER"
            export USB_MOUNT_POINT="$USB_POTENTIAL_MOUNT_POINT"
            export USB_CONNECTED=true

        else

            echo "usb[WARN]: cache stale, removing"
            rm -f "$USB_CACHE_FILE"
        fi
    fi

    if [[ "$USB_CONNECTED" == false ]]; then
        if command -v powershell.exe > /dev/null 2>&1; then
            USB_DETECTED_DRIVE_LETTER=$(powershell.exe -NoProfile -Command '
                Get-Volume | Where-Object {
                  $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\'"$USB_MANIFEST_FILENAME"'")
                } | Select-Object -ExpandProperty DriveLetter
            ' 2>/dev/null | tr -d '\r')

            if [[ -n "$USB_DETECTED_DRIVE_LETTER" ]]; then
                export USB_DRIVE_LETTER="$USB_DETECTED_DRIVE_LETTER"
                export USB_MOUNT_POINT="/mnt/${USB_DETECTED_DRIVE_LETTER,,}"
                echo "$USB_DETECTED_DRIVE_LETTER" > "$USB_CACHE_FILE"

                if [[ ! -d "$USB_MOUNT_POINT" ]]; then
                    sudo mkdir -p "$USB_MOUNT_POINT"
                fi

                if [[ ! -f "$USB_MOUNT_POINT/$USB_MANIFEST_FILENAME" ]]; then
                    echo "usb: mounting ${USB_DETECTED_DRIVE_LETTER}: ..."
                    if sudo mount -t drvfs "${USB_DETECTED_DRIVE_LETTER}:" "$USB_MOUNT_POINT" -o metadata; then
                        export USB_CONNECTED=true
                    else
                        echo "usb[ERROR]: mount failed"
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
            echo "usb: USB connected at $USB_MOUNT_POINT"
            break
        fi
    done

fi

# =============================================================================
# LOAD -- Source .usb-manifest and .usb-projects/*.conf
# Requires: USB_CONNECTED=true
# Sets: USB_LABEL, USB_MANIFEST_VERSION, USB_DEFAULT_PHASE, USB_SYNC_LOG,
#       USB_LOADED_PROJECTS, USB_<PROJECT>_* per loaded project
# =============================================================================


if [[ "$USB_CONNECTED" == true ]]; then


    # Parse .usb-manifest as plain key-value data. File is not sourced.
    # Expected format: KEY=value, one per line. No quotes or brackets. Comments (#) and blank lines skipped.
    while IFS='=' read -r usb_manifest_key usb_manifest_value; do
        if [[ -z "$usb_manifest_key" || "$usb_manifest_key" == \#* ]]; then
            continue
        fi
        case "$usb_manifest_key" in
            VERSION)       USB_MANIFEST_VERSION="$usb_manifest_value" ;;
            LABEL)         USB_LABEL="$usb_manifest_value" ;;
            SYNC_LOG)      USB_SYNC_LOG="$USB_MOUNT_POINT/$usb_manifest_value" ;;
            DEFAULT_PHASE) USB_DEFAULT_PHASE="$usb_manifest_value" ;;
            *)             echo "usb[WARN]: unknown manifest key: $usb_manifest_key" ;;
        esac
    done < "$USB_MOUNT_POINT/$USB_MANIFEST_FILENAME"
    unset usb_manifest_key
    unset usb_manifest_value
    if [[ -z "$USB_LABEL" || -z "$USB_MANIFEST_VERSION" ]]; then
        echo "usb[ERROR]: manifest missing required keys (LABEL, VERSION)"
        export USB_CONNECTED=false
        return 1
    fi
    export USB_MANIFEST_VERSION
    export USB_LABEL
    export USB_DEFAULT_PHASE
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
        while IFS='=' read -r usb_conf_key usb_conf_value; do
            if [[ -z "$usb_conf_key" || "$usb_conf_key" == \#* ]]; then
                continue
            fi
            case "$usb_conf_key" in
                local_dir)
                    usb_parsed_local_dir="${usb_conf_value//\{HOME\}/$HOME}"
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
                    echo "usb[WARN]: conf '$usb_project_name' unknown key: $usb_conf_key"
                    ;;
            esac
        done < "$usb_conf_file_path"

        if [[ -z "$usb_parsed_local_dir" ]]; then
            echo "usb[ERROR]: conf '$usb_project_name' missing required key: local_dir"
            continue
        fi
        if [[ -z "$usb_parsed_repo_path" ]]; then
            echo "usb[ERROR]: conf '$usb_project_name' missing required key: repo_path"
            continue
        fi
        if [[ ! -d "$usb_parsed_local_dir" ]]; then
            echo "usb[WARN]: local_dir for project '$usb_project_name' not found: $usb_parsed_local_dir -- skipping"
            continue
        fi

        usb_project_name_upper="${usb_project_name^^}"

        # Resolve {USB_ROOT} and {LOCAL_DIR} tokens in sync_file entries
        USB_RESOLVED_SYNC_FILES=()
        for usb_raw_sync_entry in "${usb_parsed_sync_files[@]}"; do
            usb_raw_sync_entry="${usb_raw_sync_entry//\{USB_ROOT\}/$USB_MOUNT_POINT}"
            usb_raw_sync_entry="${usb_raw_sync_entry//\{LOCAL_DIR\}/$usb_parsed_local_dir}"
            USB_RESOLVED_SYNC_FILES+=("$usb_raw_sync_entry")
        done

        # Resolve {USB_ROOT} and {LOCAL_DIR} tokens in sync_dir entries
        USB_RESOLVED_SYNC_DIRS=()
        for usb_raw_sync_entry in "${usb_parsed_sync_dirs[@]}"; do
            usb_raw_sync_entry="${usb_raw_sync_entry//\{USB_ROOT\}/$USB_MOUNT_POINT}"
            usb_raw_sync_entry="${usb_raw_sync_entry//\{LOCAL_DIR\}/$usb_parsed_local_dir}"
            USB_RESOLVED_SYNC_DIRS+=("$usb_raw_sync_entry")
        done

        export "USB_${usb_project_name_upper}_LOCAL_DIR=$usb_parsed_local_dir"
        export "USB_${usb_project_name_upper}_REPO_PATH=$usb_parsed_repo_path"

        # Bash arrays cannot cross subshell boundaries via export. eval + printf %q
        # builds the assignment string with proper quoting for special characters,
        # then evaluates it in the current shell to create the array.
        usb_sync_files_assignment="USB_${usb_project_name_upper}_SYNC_FILES=("
        for usb_resolved_sync_files_entry in "${USB_RESOLVED_SYNC_FILES[@]}"; do
            usb_sync_files_assignment+="$(printf '%q' "$usb_resolved_sync_files_entry") "
        done
        usb_sync_files_assignment+=")"
        eval "$usb_sync_files_assignment"

        usb_sync_dirs_assignment="USB_${usb_project_name_upper}_SYNC_DIRS=("
        for usb_resolved_sync_dirs_entry in "${USB_RESOLVED_SYNC_DIRS[@]}"; do
            usb_sync_dirs_assignment+="$(printf '%q' "$usb_resolved_sync_dirs_entry") "
        done
        usb_sync_dirs_assignment+=")"
        eval "$usb_sync_dirs_assignment"

        USB_LOADED_PROJECTS+=("$usb_project_name")
    done


    unset usb_parsed_local_dir
    unset usb_parsed_repo_path
    unset usb_parsed_sync_files
    unset usb_parsed_sync_dirs
    unset usb_conf_key
    unset usb_conf_value
    unset usb_conf_file_path
    unset usb_project_name
    unset usb_project_name_upper
    unset USB_RESOLVED_SYNC_FILES
    unset USB_RESOLVED_SYNC_DIRS
    unset usb_raw_sync_entry
    unset usb_sync_files_assignment
    unset usb_sync_dirs_assignment
    unset usb_resolved_sync_files_entry
    unset usb_resolved_sync_dirs_entry

    echo "usb: loaded ${#USB_LOADED_PROJECTS[@]} project(s): ${USB_LOADED_PROJECTS[*]}"

fi

# =============================================================================
# FUNCTIONS
# =============================================================================

# _usb_run_sync_files -- execute sync_files entries for a project and trigger
# Arguments:
#   project_name  -- name of the project as it appears in USB_LOADED_PROJECTS
#   trigger_label -- one of: startup, sync, eject
# Phases run per trigger:
#   startup -> auto, always
#   sync    -> manual, always
#   eject   -> auto, always
_usb_run_sync_files() {
    local usb_project_name="$1"
    local usb_trigger_label="$2"
    local usb_project_name_upper
    local usb_sync_files_variable_name
    local usb_sync_entry
    local usb_entry_source_path
    local usb_entry_dest_path
    local usb_entry_condition
    local usb_entry_phase
    local usb_entry_dest_dir
    local usb_effective_phase
    local usb_should_run
    local usb_copy_result
    local usb_log_timestamp
    local usb_log_warning_shown=false

    usb_project_name_upper="${usb_project_name^^}"
    usb_sync_files_variable_name="USB_${usb_project_name_upper}_SYNC_FILES"

    # declare -n creates a nameref for reading the dynamically-named sync_files
    # array. LOAD uses eval to write arrays (dynamic name construction). Functions
    # use nameref to read them (cleaner than eval for access). Requires bash 4.3+.
    declare -n usb_sync_files_array_ref="$usb_sync_files_variable_name"

    for usb_sync_entry in "${usb_sync_files_array_ref[@]}"; do

        IFS=: read -r usb_entry_source_path usb_entry_dest_path usb_entry_condition usb_entry_phase <<< "$usb_sync_entry"

        if [[ -z "$usb_entry_phase" ]]; then
            usb_effective_phase="$USB_DEFAULT_PHASE"
        else
            usb_effective_phase="$usb_entry_phase"
        fi


        # Trigger-to-phase mapping:
        #   startup -> runs: auto, always
        #   eject   -> runs: auto, always
        #   sync    -> runs: manual, always
        usb_should_run=false

        case "${usb_trigger_label}:${usb_effective_phase}" in
            startup:auto|startup:always)  usb_should_run=true ;;
            eject:auto|eject:always)      usb_should_run=true ;;
            sync:manual|sync:always)      usb_should_run=true ;;
        esac

        if [[ "$usb_should_run" == false ]]; then
            continue
        fi

        usb_copy_result="SKIP"
        if [[ "$usb_entry_condition" == "newer" ]]; then
            # bash -nt returns true when the right-hand file does not exist.
            # This is the desired behavior: a missing destination means the
            # file should be copied.
            if [[ "$usb_entry_source_path" -nt "$usb_entry_dest_path" ]]; then
                usb_entry_dest_dir=$(dirname "$usb_entry_dest_path")
                if [[ ! -d "$usb_entry_dest_dir" ]]; then
                    echo "usb[ERROR]: [$usb_project_name] dest directory does not exist: $usb_entry_dest_dir"
                    usb_copy_result="ERROR"
                elif cp "$usb_entry_source_path" "$usb_entry_dest_path"; then
                    usb_copy_result="OK"
                else
                    usb_copy_result="ERROR"
                fi
            fi
        fi


        usb_log_timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
        if [[ "$usb_copy_result" == "OK" ]]; then
            echo "usb: [$usb_project_name] synced $usb_entry_source_path -> $usb_entry_dest_path"
        elif [[ "$usb_copy_result" == "ERROR" ]]; then
            echo "usb[ERROR]: [$usb_project_name] copy failed $usb_entry_source_path -> $usb_entry_dest_path"
        fi
        if [[ "$usb_copy_result" == "OK" || "$usb_copy_result" == "ERROR" ]]; then
            if [[ -n "$USB_SYNC_LOG" ]]; then
                echo "$usb_log_timestamp [$usb_project_name] COPY $usb_entry_source_path -> $usb_entry_dest_path [$usb_copy_result]" >> "$USB_SYNC_LOG"
            elif [[ "$usb_log_warning_shown" == false ]]; then
                echo "usb[WARN]: USB_SYNC_LOG is not set, skipping log writes"
                usb_log_warning_shown=true
            fi
        fi
    done

    unset -n usb_sync_files_array_ref
}

# _usb_run_sync_dirs -- execute sync_dir entries for a project and trigger
# Arguments:
#   project_name  -- name of the project as it appears in USB_LOADED_PROJECTS
#   trigger_label -- one of: startup, sync, eject
# Per-file newer check: walks source tree, copies files newer than dest.
# Creates subdirectories within dest_dir as needed. Top-level dest_dir
# must exist (setup error if missing). Symlinks skipped with warning.
# Does not delete files missing from source.
_usb_run_sync_dirs() {
    local usb_project_name="$1"
    local usb_trigger_label="$2"
    local usb_project_name_upper
    local usb_sync_dirs_variable_name
    local usb_sync_entry
    local usb_entry_source_dir
    local usb_entry_dest_dir
    local usb_entry_condition
    local usb_entry_phase
    local usb_effective_phase
    local usb_should_run
    local usb_log_timestamp
    local usb_log_warning_shown=false
    local usb_symlink_count
    local usb_source_file_path
    local usb_relative_path
    local usb_dest_file_path
    local usb_dest_file_dir
    local usb_copy_count
    local usb_error_count

    usb_project_name_upper="${usb_project_name^^}"
    usb_sync_dirs_variable_name="USB_${usb_project_name_upper}_SYNC_DIRS"

    declare -n usb_sync_dirs_array_ref="$usb_sync_dirs_variable_name"

    for usb_sync_entry in "${usb_sync_dirs_array_ref[@]}"; do

        IFS=: read -r usb_entry_source_dir usb_entry_dest_dir usb_entry_condition usb_entry_phase <<< "$usb_sync_entry"

        if [[ -z "$usb_entry_phase" ]]; then
            usb_effective_phase="$USB_DEFAULT_PHASE"
        else
            usb_effective_phase="$usb_entry_phase"
        fi

        usb_should_run=false
        case "${usb_trigger_label}:${usb_effective_phase}" in
            startup:auto|startup:always)  usb_should_run=true ;;
            eject:auto|eject:always)      usb_should_run=true ;;
            sync:manual|sync:always)      usb_should_run=true ;;
        esac

        if [[ "$usb_should_run" == false ]]; then
            continue
        fi

        if [[ ! -d "$usb_entry_source_dir" ]]; then
            echo "usb[ERROR]: [$usb_project_name] sync_dir source directory does not exist: $usb_entry_source_dir"
            continue
        fi

        # Top-level dest_dir must exist -- missing means setup error.
        # Subdirectories within dest_dir are created as needed.
        if [[ ! -d "$usb_entry_dest_dir" ]]; then
            echo "usb[ERROR]: [$usb_project_name] sync_dir dest directory does not exist: $usb_entry_dest_dir"
            continue
        fi

        usb_copy_count=0
        usb_error_count=0

        if [[ "$usb_entry_condition" == "newer" ]]; then

            # Warn about symlinks -- find -type f skips them silently
            usb_symlink_count=$(find "$usb_entry_source_dir" -type l | wc -l)
            if [[ "$usb_symlink_count" -gt 0 ]]; then
                echo "usb[WARN]: [$usb_project_name] sync_dir skipped $usb_symlink_count symlink(s) in $usb_entry_source_dir"
            fi

            while IFS= read -r usb_source_file_path; do
                usb_relative_path="${usb_source_file_path#"$usb_entry_source_dir"/}"
                usb_dest_file_path="${usb_entry_dest_dir}/${usb_relative_path}"

                # Safety: dest path must be under the declared dest_dir
                if [[ "$usb_dest_file_path" != "$usb_entry_dest_dir"/* ]]; then
                    echo "usb[ERROR]: [$usb_project_name] sync_dir dest path outside dest_dir: $usb_dest_file_path"
                    usb_error_count=$((usb_error_count + 1))
                    continue
                fi

                # bash -nt returns true when the right-hand file does not exist.
                # A missing dest file means copy it.
                if [[ "$usb_source_file_path" -nt "$usb_dest_file_path" ]]; then
                    usb_dest_file_dir=$(dirname "$usb_dest_file_path")
                    if [[ ! -d "$usb_dest_file_dir" ]]; then
                        mkdir -p "$usb_dest_file_dir"
                    fi
                    if cp "$usb_source_file_path" "$usb_dest_file_path"; then
                        usb_copy_count=$((usb_copy_count + 1))
                    else
                        echo "usb[ERROR]: [$usb_project_name] sync_dir copy failed: $usb_source_file_path -> $usb_dest_file_path"
                        usb_error_count=$((usb_error_count + 1))
                    fi
                fi
            done < <(find "$usb_entry_source_dir" -type f)
        fi

        # Summary log: one line per entry, plus individual errors above
        if [[ "$usb_copy_count" -gt 0 || "$usb_error_count" -gt 0 ]]; then
            echo "usb: [$usb_project_name] sync_dir $usb_entry_source_dir -> $usb_entry_dest_dir [$usb_copy_count copied, $usb_error_count errors]"
            usb_log_timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
            if [[ -n "$USB_SYNC_LOG" ]]; then
                echo "$usb_log_timestamp [$usb_project_name] SYNC_DIR $usb_entry_source_dir -> $usb_entry_dest_dir [$usb_copy_count copied, $usb_error_count errors]" >> "$USB_SYNC_LOG"
            elif [[ "$usb_log_warning_shown" == false ]]; then
                echo "usb[WARN]: USB_SYNC_LOG is not set, skipping log writes"
                usb_log_warning_shown=true
            fi
        fi

    done

    unset -n usb_sync_dirs_array_ref
}

# usb_sync -- manually trigger file sync for one or all loaded projects
# Arguments:
#   [project_name] -- if omitted, syncs all loaded projects
# Runs phases: manual, always
usb_sync() {
    local usb_sync_target_project="$1"
    local usb_sync_project_name
    local usb_project_is_loaded


    if [[ "$USB_CONNECTED" != true ]]; then
        echo "usb[ERROR]: USB not connected"
        return 1
    fi

    if [[ ! -f "$USB_MOUNT_POINT/$USB_MANIFEST_FILENAME" ]]; then
        echo "usb[ERROR]: USB appears to have been removed (manifest not found at $USB_MOUNT_POINT/$USB_MANIFEST_FILENAME)"
        export USB_CONNECTED=false
        return 1
    fi

    if [[ -n "$usb_sync_target_project" ]]; then

        usb_project_is_loaded=false
        for usb_sync_project_name in "${USB_LOADED_PROJECTS[@]}"; do
            if [[ "$usb_sync_project_name" == "$usb_sync_target_project" ]]; then
                usb_project_is_loaded=true
                break
            fi
        done

        if [[ "$usb_project_is_loaded" == false ]]; then
            echo "usb[ERROR]: project '$usb_sync_target_project' is not loaded"
            echo "usb: loaded projects: ${USB_LOADED_PROJECTS[*]}"
            return 1
        fi

        _usb_run_sync_files "$usb_sync_target_project" "sync"
        _usb_run_sync_dirs "$usb_sync_target_project" "sync"

    else

        for usb_sync_project_name in "${USB_LOADED_PROJECTS[@]}"; do
            _usb_run_sync_files "$usb_sync_project_name" "sync"
            _usb_run_sync_dirs "$usb_sync_target_project" "sync"
        done

    fi
}

# usb_eject -- pre-eject sync, unmount, PowerShell eject (WSL), state cleanup
# Runs phases: auto, always (for all loaded projects before unmount)
usb_eject() {
    local usb_eject_project_name
    local usb_eject_project_name_upper
    local usb_drive_still_present

if [[ "$USB_CONNECTED" != true ]]; then
        echo "usb: USB is not connected, nothing to eject"
        return 0
    fi
    if [[ ! -f "$USB_MOUNT_POINT/$USB_MANIFEST_FILENAME" ]]; then
        echo "usb: USB already removed, cleaning up state"
        for usb_eject_project_name in "${USB_LOADED_PROJECTS[@]}"; do
            usb_eject_project_name_upper="${usb_eject_project_name^^}"
            unset "USB_${usb_eject_project_name_upper}_LOCAL_DIR"
            unset "USB_${usb_eject_project_name_upper}_REPO_PATH"
            unset "USB_${usb_eject_project_name_upper}_SYNC_FILES"
            unset "USB_${usb_eject_project_name_upper}_SYNC_DIRS"
        done
        unset USB_MOUNT_POINT
        unset USB_DRIVE_LETTER
        unset USB_LABEL
        unset USB_MANIFEST_VERSION
        unset USB_DEFAULT_PHASE
        unset USB_SYNC_LOG
        unset USB_LOADED_PROJECTS
        unset USB_ENV
        export USB_CONNECTED=false
        unset USB_INITIALIZED
        rm -f "$USB_CACHE_FILE"
        return 0
    fi
    for usb_eject_project_name in "${USB_LOADED_PROJECTS[@]}"; do
        _usb_run_sync_files "$usb_eject_project_name" "eject"
        _usb_run_sync_dirs "$usb_eject_project_name" "eject"
    done

    if [[ "$PWD" == "$USB_MOUNT_POINT"* ]]; then
        echo "usb: changing directory to ~"
        cd ~ || return 1
    fi

    if mountpoint -q "$USB_MOUNT_POINT" 2>/dev/null; then
        echo "usb: unmounting $USB_MOUNT_POINT..."
        if ! sudo umount "$USB_MOUNT_POINT"; then
            echo "usb[ERROR]: unmount failed, files may still be in use"
            lsof +D "$USB_MOUNT_POINT" 2>/dev/null || echo "usb: could not list open files"
            return 1
        fi
    fi

    if [[ "$USB_ENV" == "wsl" ]]; then

        if [[ -d "$USB_MOUNT_POINT" ]]; then
            sudo rmdir "$USB_MOUNT_POINT" 2>/dev/null
        fi

        if [[ -n "$USB_DRIVE_LETTER" ]]; then
            echo "usb: ejecting ${USB_DRIVE_LETTER}: from Windows..."
            powershell.exe -NoProfile -Command "
                (New-Object -ComObject Shell.Application).NameSpace(17).ParseName('${USB_DRIVE_LETTER}:').InvokeVerb('Eject')
            " 2>/dev/null
            sleep 2
            usb_drive_still_present=$(powershell.exe -NoProfile -Command "Test-Path '${USB_DRIVE_LETTER}:'" 2>/dev/null | tr -d '\r')
            if [[ "$usb_drive_still_present" == "True" ]]; then
                echo "usb[WARN]: Windows did not eject the drive, it may still be busy"
            else
                echo "usb: drive ejected safely"
            fi
        fi

    else
        echo "usb: unmounted, safe to unplug"
    fi

    for usb_eject_project_name in "${USB_LOADED_PROJECTS[@]}"; do
        usb_eject_project_name_upper="${usb_eject_project_name^^}"
        unset "USB_${usb_eject_project_name_upper}_LOCAL_DIR"
        unset "USB_${usb_eject_project_name_upper}_REPO_PATH"
        unset "USB_${usb_eject_project_name_upper}_SYNC_FILES"
        unset "USB_${usb_eject_project_name_upper}_SYNC_DIRS"
    done

    unset USB_MOUNT_POINT
    unset USB_DRIVE_LETTER
    unset USB_LABEL
    unset USB_MANIFEST_VERSION
    unset USB_DEFAULT_PHASE
    unset USB_SYNC_LOG
    unset USB_LOADED_PROJECTS
    unset USB_ENV
    export USB_CONNECTED=false
    unset USB_INITIALIZED
    rm -f "$USB_CACHE_FILE"

}

# usb_refresh -- re-source usb.sh with force argument to bypass cache
usb_refresh() {
    if [[ ! -f "$USB_SCRIPT_PATH" ]]; then
        echo "usb[ERROR]: script not found at $USB_SCRIPT_PATH"
        echo "usb: source usb.sh manually from its location"
        return 1
    fi
    echo "usb: refreshing from $USB_SCRIPT_PATH..."
    source "$USB_SCRIPT_PATH" force
    if [[ "$USB_CONNECTED" == true ]]; then
        echo "usb: ready ($USB_ENV, mount: $USB_MOUNT_POINT)"
    else
        echo "usb: ready ($USB_ENV, USB not connected)"
    fi
}

# usb_status -- print diagnostic information about USB state
# No arguments. Safe to call regardless of connection state.
usb_status() {
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
    echo "usb: status: default_phase=$USB_DEFAULT_PHASE"
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


# usb_check -- validate conf files and check that all referenced paths exist
# No arguments. Requires USB_CONNECTED=true.
# Re-reads and parses conf files independently (same while-read pattern as
# LOAD). Reports only -- no copies, no exports, no state changes.
usb_check() {
    local usb_check_conf_file_path
    local usb_check_project_name
    local usb_check_local_dir
    local usb_check_repo_path
    local usb_check_sync_files
    local usb_check_sync_dirs
    local usb_check_conf_key
    local usb_check_conf_value
    local usb_check_entry
    local usb_check_entry_source
    local usb_check_entry_dest
    local usb_check_entry_condition
    local usb_check_entry_phase
    local usb_check_entry_dest_dir
    local usb_check_errors=0

    if [[ "$USB_CONNECTED" != true ]]; then
        echo "usb[ERROR]: USB not connected, cannot check conf files"
        return 1
    fi

    for usb_check_conf_file_path in "$USB_MOUNT_POINT/.usb-projects/"*.conf; do
        if [[ ! -f "$usb_check_conf_file_path" ]]; then
            echo "usb: check: no conf files found"
            break
        fi

        usb_check_local_dir=""
        usb_check_repo_path=""
        usb_check_sync_files=()
        usb_check_sync_dirs=()

        usb_check_project_name=$(basename "$usb_check_conf_file_path" .conf)
        echo "usb: check: --- $usb_check_project_name ---"
        echo "usb: check: conf=$usb_check_conf_file_path"

        while IFS='=' read -r usb_check_conf_key usb_check_conf_value; do
            if [[ -z "$usb_check_conf_key" || "$usb_check_conf_key" == \#* ]]; then
                continue
            fi
            case "$usb_check_conf_key" in
                local_dir)
                    usb_check_local_dir="${usb_check_conf_value//\{HOME\}/$HOME}"
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
                    echo "usb: check: WARN unknown key: $usb_check_conf_key"
                    ;;
            esac
        done < "$usb_check_conf_file_path"

        if [[ -z "$usb_check_local_dir" ]]; then
            echo "usb: check: ERROR local_dir missing"
            usb_check_errors=$((usb_check_errors + 1))
        else
            echo "usb: check: local_dir=$usb_check_local_dir"
            if [[ -d "$usb_check_local_dir" ]]; then
                echo "usb: check:   exists=yes"
            else
                echo "usb: check:   exists=no"
                usb_check_errors=$((usb_check_errors + 1))
            fi
        fi

        if [[ -z "$usb_check_repo_path" ]]; then
            echo "usb: check: ERROR repo_path missing"
            usb_check_errors=$((usb_check_errors + 1))
        else
            echo "usb: check: repo_path=$usb_check_repo_path"
            if [[ -d "$USB_MOUNT_POINT/$usb_check_repo_path" ]]; then
                echo "usb: check:   exists=yes"
            else
                echo "usb: check:   exists=no"
                usb_check_errors=$((usb_check_errors + 1))
            fi
        fi

        for usb_check_entry in "${usb_check_sync_files[@]}"; do
            usb_check_entry="${usb_check_entry//\{USB_ROOT\}/$USB_MOUNT_POINT}"
            usb_check_entry="${usb_check_entry//\{LOCAL_DIR\}/$usb_check_local_dir}"
            IFS=: read -r usb_check_entry_source usb_check_entry_dest usb_check_entry_condition usb_check_entry_phase <<< "$usb_check_entry"
            echo "usb: check: sync_file=$usb_check_entry_source -> $usb_check_entry_dest [$usb_check_entry_condition:$usb_check_entry_phase]"
            if [[ -f "$usb_check_entry_source" ]]; then
                echo "usb: check:   source exists=yes"
            else
                echo "usb: check:   source exists=no"
                usb_check_errors=$((usb_check_errors + 1))
            fi
            usb_check_entry_dest_dir=$(dirname "$usb_check_entry_dest")
            if [[ -d "$usb_check_entry_dest_dir" ]]; then
                echo "usb: check:   dest dir exists=yes"
            else
                echo "usb: check:   dest dir exists=no"
                usb_check_errors=$((usb_check_errors + 1))
            fi
        done

        for usb_check_entry in "${usb_check_sync_dirs[@]}"; do
            usb_check_entry="${usb_check_entry//\{USB_ROOT\}/$USB_MOUNT_POINT}"
            usb_check_entry="${usb_check_entry//\{LOCAL_DIR\}/$usb_check_local_dir}"
            IFS=: read -r usb_check_entry_source usb_check_entry_dest usb_check_entry_condition usb_check_entry_phase <<< "$usb_check_entry"
            echo "usb: check: sync_dir=$usb_check_entry_source -> $usb_check_entry_dest [$usb_check_entry_condition:$usb_check_entry_phase]"
            if [[ -d "$usb_check_entry_source" ]]; then
                echo "usb: check:   source dir exists=yes"
            else
                echo "usb: check:   source dir exists=no"
                usb_check_errors=$((usb_check_errors + 1))
            fi
            if [[ -d "$usb_check_entry_dest" ]]; then
                echo "usb: check:   dest dir exists=yes"
            else
                echo "usb: check:   dest dir exists=no"
                usb_check_errors=$((usb_check_errors + 1))
            fi
        done

    done

    if [[ "$usb_check_errors" -gt 0 ]]; then
        echo "usb: check: $usb_check_errors error(s) found"
        return 1
    else
        echo "usb: check: all checks passed"
        return 0
    fi
}

# usb_new_project -- create a new project conf via editor
# Arguments:
#   project_name -- lowercase, letters/digits/underscores, starts with letter
# Opens $EDITOR with a scaffold. Validates after editor exits.
# Atomic move from .tmp to .conf on success.
usb_new_project() {
    local usb_new_project_name="$1"
    local usb_new_project_conf_path
    local usb_new_project_tmp_path
    local usb_new_project_editor
    local usb_new_project_local_dir
    local usb_new_project_repo_path
    local usb_new_project_conf_key
    local usb_new_project_conf_value
    local usb_new_project_has_local_dir=false
    local usb_new_project_has_repo_path=false

    if [[ "$USB_CONNECTED" != true ]]; then
        echo "usb[ERROR]: USB not connected"
        return 1
    fi

    if [[ -z "$usb_new_project_name" ]]; then
        echo "usb[ERROR]: usage: usb_new_project <name>"
        return 1
    fi

    # Name becomes part of bash variable names (USB_<NAME>_*).
    # Must be valid identifier component: lowercase start, alphanumeric + underscore.
    if [[ ! "$usb_new_project_name" =~ ^[a-z][a-z0-9_]*$ ]]; then
        echo "usb[ERROR]: project name must start with a lowercase letter and contain only lowercase letters, digits, and underscores"
        return 1
    fi

    usb_new_project_conf_path="$USB_MOUNT_POINT/.usb-projects/${usb_new_project_name}.conf"

    if [[ -f "$usb_new_project_conf_path" ]]; then
        echo "usb[ERROR]: conf already exists: $usb_new_project_conf_path"
        return 1
    fi

    usb_new_project_editor="${EDITOR:-vi}"
    if ! command -v "$usb_new_project_editor" > /dev/null 2>&1; then
        echo "usb[ERROR]: editor not found: $usb_new_project_editor"
        echo "usb: set EDITOR to a valid editor"
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
# sync_file format: src:dest:condition:phase
#   condition: newer (copy if source is newer than dest)
#   phase: auto | manual | always
#
# sync_dir format: src:dest:condition:phase
#   Same as sync_file but syncs all files in directory recursively.

local_dir={HOME}/personal_repos/${usb_new_project_name}
repo_path=personal_repos/${usb_new_project_name}.git
# sync_file={USB_ROOT}/shared/example.txt:{LOCAL_DIR}/example.txt:newer:auto
# sync_dir={USB_ROOT}/shared/docs:{LOCAL_DIR}/docs:newer:auto
SCAFFOLD

    echo "usb: opening editor: $usb_new_project_editor"
    "$usb_new_project_editor" "$usb_new_project_tmp_path"

    if [[ ! -f "$usb_new_project_tmp_path" ]]; then
        echo "usb[ERROR]: temp file removed, aborting"
        return 1
    fi

    # Validate conf after editor exits
    while IFS='=' read -r usb_new_project_conf_key usb_new_project_conf_value; do
        if [[ -z "$usb_new_project_conf_key" || "$usb_new_project_conf_key" == \#* ]]; then
            continue
        fi
        case "$usb_new_project_conf_key" in
            local_dir)
                usb_new_project_has_local_dir=true
                usb_new_project_local_dir="${usb_new_project_conf_value//\{HOME\}/$HOME}"
                ;;
            repo_path)
                usb_new_project_has_repo_path=true
                usb_new_project_repo_path="$usb_new_project_conf_value"
                ;;
            sync_file|sync_dir)
                ;;
            *)
                echo "usb[WARN]: unknown key: $usb_new_project_conf_key"
                ;;
        esac
    done < "$usb_new_project_tmp_path"

    if [[ "$usb_new_project_has_local_dir" == false || "$usb_new_project_has_repo_path" == false ]]; then
        echo "usb[ERROR]: conf missing required key(s):"
        if [[ "$usb_new_project_has_local_dir" == false ]]; then
            echo "usb[ERROR]:   local_dir"
        fi
        if [[ "$usb_new_project_has_repo_path" == false ]]; then
            echo "usb[ERROR]:   repo_path"
        fi
        echo "usb: temp file kept at: $usb_new_project_tmp_path"
        echo "usb: fix and rename manually, or remove and try again"
        return 1
    fi

    if [[ ! -d "$usb_new_project_local_dir" ]]; then
        echo "usb[WARN]: local_dir does not exist: $usb_new_project_local_dir"
    fi
    if [[ ! -d "$USB_MOUNT_POINT/$usb_new_project_repo_path" ]]; then
        echo "usb[WARN]: repo_path does not exist on USB: $usb_new_project_repo_path"
    fi

    mv "$usb_new_project_tmp_path" "$usb_new_project_conf_path"
    echo "usb: created $usb_new_project_conf_path"
    echo "usb: run 'source ~/.config/mc_extensions/usb.sh force' to load"
}

# =============================================================================
# SYNC -- Execute sync_files entries for auto and always phases on startup
# Requires: USB_CONNECTED=true, USB_LOADED_PROJECTS non-empty
# =============================================================================

if [[ "$USB_CONNECTED" == true ]]; then
    if [[ ${#USB_LOADED_PROJECTS[@]} -gt 0 ]]; then
        for usb_startup_project_name in "${USB_LOADED_PROJECTS[@]}"; do
            _usb_run_sync_files "$usb_startup_project_name" "startup"
            _usb_run_sync_dirs "$usb_startup_project_name" "startup"
        done
        unset usb_startup_project_name

    fi
fi

USB_INITIALIZED=true
