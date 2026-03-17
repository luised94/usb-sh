#!/usr/bin/env bash
# usb.sh -- USB detection, project configuration loading, and file synchronization.
# Source this file. Do not execute directly.
# Projects source usb.sh and compose on top of it.
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

USB_SCRIPT_PATH="${BASH_SOURCE[0]}"

# =============================================================================
# FIND -- USB hardware detection
# Sets: USB_CONNECTED, USB_MOUNT_POINT, USB_ENV, USB_DRIVE_LETTER
# =============================================================================

USB_CACHE_FILE="/tmp/usb_drive_cache"

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
        echo "usb: found cache file $USB_CACHE_FILE"
        USB_CACHED_DRIVE_LETTER=$(cat "$USB_CACHE_FILE")
        USB_POTENTIAL_MOUNT_POINT="/mnt/${USB_CACHED_DRIVE_LETTER,,}"
        if [[ -f "$USB_POTENTIAL_MOUNT_POINT/.usb-manifest" ]]; then
            export USB_DRIVE_LETTER="$USB_CACHED_DRIVE_LETTER"
            export USB_MOUNT_POINT="$USB_POTENTIAL_MOUNT_POINT"
            export USB_CONNECTED=true
        else
            echo "usb: cache stale, removing"
            rm -f "$USB_CACHE_FILE"
        fi
    fi

    if [[ "$USB_CONNECTED" == false ]]; then
        if command -v powershell.exe > /dev/null 2>&1; then
            USB_DETECTED_DRIVE_LETTER=$(powershell.exe -NoProfile -Command '
                Get-Volume | Where-Object {
                    $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\.usb-manifest")
                } | Select-Object -ExpandProperty DriveLetter
            ' 2>/dev/null | tr -d '\r')

            if [[ -n "$USB_DETECTED_DRIVE_LETTER" ]]; then
                export USB_DRIVE_LETTER="$USB_DETECTED_DRIVE_LETTER"
                export USB_MOUNT_POINT="/mnt/${USB_DETECTED_DRIVE_LETTER,,}"
                echo "$USB_DETECTED_DRIVE_LETTER" > "$USB_CACHE_FILE"

                if [[ ! -d "$USB_MOUNT_POINT" ]]; then
                    sudo mkdir -p "$USB_MOUNT_POINT"
                fi

                if [[ ! -f "$USB_MOUNT_POINT/.usb-manifest" ]]; then
                    echo "usb: mounting ${USB_DETECTED_DRIVE_LETTER}:..."
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
        if [[ -f "$usb_candidate_path/.usb-manifest" ]]; then
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

    source "$USB_MOUNT_POINT/.usb-manifest"
    export USB_MANIFEST_VERSION
    export USB_LABEL
    export USB_DEFAULT_PHASE
    USB_SYNC_LOG="$USB_MOUNT_POINT/$USB_SYNC_LOG"
    export USB_SYNC_LOG

    USB_LOADED_PROJECTS=()

    for usb_conf_file_path in "$USB_MOUNT_POINT/.usb-projects/"*.conf; do

        if [[ ! -f "$usb_conf_file_path" ]]; then
            break
        fi

        unset local_dir
        unset repo_path
        unset sync_files
        unset sync_dirs

        usb_project_name=$(basename "$usb_conf_file_path" .conf)

        source "$usb_conf_file_path"

        if [[ ! -d "$local_dir" ]]; then
            echo "usb[WARN]: local_dir for project '$usb_project_name' not found: $local_dir -- skipping"
            continue
        fi

        usb_project_name_upper="${usb_project_name^^}"

        USB_RESOLVED_SYNC_FILES=()
        for usb_sync_files_entry in "${sync_files[@]}"; do
            usb_sync_files_entry="${usb_sync_files_entry//\{USB_ROOT\}/$USB_MOUNT_POINT}"
            usb_sync_files_entry="${usb_sync_files_entry//\{LOCAL_DIR\}/$local_dir}"
            USB_RESOLVED_SYNC_FILES+=("$usb_sync_files_entry")
        done

        USB_RESOLVED_SYNC_DIRS=()
        for usb_sync_dirs_entry in "${sync_dirs[@]}"; do
            usb_sync_dirs_entry="${usb_sync_dirs_entry//\{USB_ROOT\}/$USB_MOUNT_POINT}"
            usb_sync_dirs_entry="${usb_sync_dirs_entry//\{LOCAL_DIR\}/$local_dir}"
            USB_RESOLVED_SYNC_DIRS+=("$usb_sync_dirs_entry")
        done

        export "USB_${usb_project_name_upper}_LOCAL_DIR=$local_dir"
        export "USB_${usb_project_name_upper}_REPO_PATH=$repo_path"

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

    unset local_dir
    unset repo_path
    unset sync_files
    unset sync_dirs
    unset usb_conf_file_path
    unset usb_project_name
    unset usb_project_name_upper
    unset USB_RESOLVED_SYNC_FILES
    unset USB_RESOLVED_SYNC_DIRS
    unset usb_sync_files_entry
    unset usb_sync_dirs_entry
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
    local usb_effective_phase
    local usb_should_run
    local usb_copy_result
    local usb_log_timestamp

    usb_project_name_upper="${usb_project_name^^}"
    usb_sync_files_variable_name="USB_${usb_project_name_upper}_SYNC_FILES"

    declare -n usb_sync_files_array_ref="$usb_sync_files_variable_name"

    for usb_sync_entry in "${usb_sync_files_array_ref[@]}"; do

        IFS=: read -r usb_entry_source_path usb_entry_dest_path usb_entry_condition usb_entry_phase <<< "$usb_sync_entry"

        if [[ -z "$usb_entry_phase" ]]; then
            usb_effective_phase="$USB_DEFAULT_PHASE"
        else
            usb_effective_phase="$usb_entry_phase"
        fi

        usb_should_run=false

        if [[ "$usb_trigger_label" == "startup" || "$usb_trigger_label" == "eject" ]]; then
            if [[ "$usb_effective_phase" == "auto" || "$usb_effective_phase" == "always" ]]; then
                usb_should_run=true
            fi
        fi

        if [[ "$usb_trigger_label" == "sync" ]]; then
            if [[ "$usb_effective_phase" == "manual" || "$usb_effective_phase" == "always" ]]; then
                usb_should_run=true
            fi
        fi

        if [[ "$usb_should_run" == false ]]; then
            continue
        fi

        usb_copy_result="SKIP"

        if [[ "$usb_entry_condition" == "newer" ]]; then
            if [[ "$usb_entry_source_path" -nt "$usb_entry_dest_path" ]]; then
                if cp "$usb_entry_source_path" "$usb_entry_dest_path"; then
                    usb_copy_result="OK"
                else
                    usb_copy_result="ERROR"
                fi
            fi
        fi

        usb_log_timestamp=$(date +"%Y-%m-%dT%H:%M:%S")

        if [[ "$usb_copy_result" == "OK" ]]; then
            echo "usb: [$usb_project_name] synced $usb_entry_source_path -> $usb_entry_dest_path"
            echo "$usb_log_timestamp [$usb_project_name] COPY $usb_entry_source_path -> $usb_entry_dest_path [OK]" >> "$USB_SYNC_LOG"
        fi

        if [[ "$usb_copy_result" == "ERROR" ]]; then
            echo "usb[ERROR]: [$usb_project_name] copy failed $usb_entry_source_path -> $usb_entry_dest_path"
            echo "$usb_log_timestamp [$usb_project_name] COPY $usb_entry_source_path -> $usb_entry_dest_path [ERROR]" >> "$USB_SYNC_LOG"
        fi

    done

    unset -n usb_sync_files_array_ref
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

    else

        for usb_sync_project_name in "${USB_LOADED_PROJECTS[@]}"; do
            _usb_run_sync_files "$usb_sync_project_name" "sync"
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

    for usb_eject_project_name in "${USB_LOADED_PROJECTS[@]}"; do
        _usb_run_sync_files "$usb_eject_project_name" "eject"
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

# =============================================================================
# SYNC -- Execute sync_files entries for auto and always phases on startup
# Requires: USB_CONNECTED=true, USB_LOADED_PROJECTS non-empty
# =============================================================================

if [[ "$USB_CONNECTED" == true ]]; then
    if [[ ${#USB_LOADED_PROJECTS[@]} -gt 0 ]]; then
        for usb_startup_project_name in "${USB_LOADED_PROJECTS[@]}"; do
            _usb_run_sync_files "$usb_startup_project_name" "startup"
        done
        unset usb_startup_project_name
    fi
fi
