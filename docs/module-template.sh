# module-template.sh - Template for new usb.sh project modules
#
# Usage: Copy this file, rename to <project>.sh, and customize.
#
# Loading: .bashrc sources usb.sh first (exports USB_* variables),
# then sources this module. This file does NOT source usb.sh.
#
# Design: The module always loads. Local features (aliases, directory
# navigation, project-specific scripts) work regardless of USB state.
# Only USB operations (push, pull, sync) require USB_CONNECTED=true,
# and those checks happen inside the usb_ functions themselves.
#
# Replace all instances of:
#   TEMPLATE / template  ->  your project's uppercase / lowercase name
#   e.g., KBD / kbd, FINANCES / finances

# --- usb.sh integration check ---
# usb.sh is loaded by infrastructure before extensions.
# This module does not source usb.sh. It reads variables usb.sh set
# during shell initialization. If usb.sh has not run, USB features
# degrade gracefully via variable fallbacks below.
#
# This check is a runtime safety net, not dead code. It fires when:
#   - usb-sh repo is not cloned on this machine
#   - bash/ chain load order changed and usb.sh loads after extensions
#   - usb.sh was removed from the infrastructure chain
# See: ~/personal_repos/usb-sh/docs/usb-setup.md (Loading Architecture)
if [[ "${USB_INITIALIZED:-}" != true ]]; then
    if [[ -f "$HOME/personal_repos/usb-sh/usb.sh" ]]; then
        echo "template[WARN]: usb.sh found but not loaded (check bash/ chain load order)"
    else
        echo "template[WARN]: usb.sh not found, USB features unavailable"
    fi
    export USB_CONNECTED=false
fi

# --- directory ---
# Fallback ensures aliases and local functions work even without USB.
TEMPLATE_DIR="${USB_TEMPLATE_LOCAL_DIR:-$HOME/personal_repos/template}"

# --- aliases ---
# These work regardless of USB connection.
# alias tj='nvim "$TEMPLATE_DIR/journal.txt"'
# alias td='cd "$TEMPLATE_DIR"'

# --- functions ---

# Push local commits to USB bare repo.
template_push() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "Usage: template_push"
        echo "Push current branch to USB bare repo for template project."
        return 0
    fi
    usb_push template
}

# Pull from USB bare repo to local.
template_pull() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "Usage: template_pull"
        echo "Pull current branch from USB bare repo for template project."
        return 0
    fi
    usb_pull template
}

# Run manual-phase sync entries.
template_sync() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "Usage: template_sync"
        echo "Run manual-phase file sync entries for template project."
        return 0
    fi
    usb_sync template
}

# --- project-specific ---
# Add functions here that usb.sh does not own.
# Examples: multi-hop file syncs, custom commit strategies, export scripts.
#
# template_export() {
#     if [[ "$1" == "-h" || "$1" == "--help" ]]; then
#         echo "Usage: template_export"
#         echo "Copy data from external source to USB shared directory."
#         return 0
#     fi
#     local src="/mnt/c/Users/${MC_WINDOWS_USER}/SomeApp/output.dat"
#     local dest="$USB_MOUNT_POINT/shared/template_output.dat"
#     [[ -f "$src" ]] && [[ "$src" -nt "$dest" ]] && cp "$src" "$dest"
# }
