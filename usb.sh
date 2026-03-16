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
# Sets: USB_CONNECTED, USB_MOUNT_POINT, USB_ENV
# =============================================================================
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


# =============================================================================
# LOAD -- Source .usb-manifest and .usb-projects/*.conf
# Requires: USB_CONNECTED=true
# Sets: USB_LABEL, USB_MANIFEST_VERSION, USB_DEFAULT_PHASE, USB_SYNC_LOG,
#       USB_LOADED_PROJECTS, USB_<PROJECT>_* per loaded project
# =============================================================================



# =============================================================================
# SYNC -- Execute sync_files entries for auto and always phases on startup
# Requires: USB_CONNECTED=true, USB_LOADED_PROJECTS non-empty
# =============================================================================



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
    :
}

# usb_sync -- manually trigger file sync for one or all loaded projects
# Arguments:
#   [project_name] -- if omitted, syncs all loaded projects
# Runs phases: manual, always
usb_sync() {
    :
}

# usb_eject -- pre-eject sync, unmount, PowerShell eject (WSL), state cleanup
# Runs phases: auto, always (for all loaded projects before unmount)
usb_eject() {
    :
}

# usb_refresh -- re-source usb.sh with force argument to bypass cache
usb_refresh() {
    :
}
