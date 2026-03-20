#!/bin/bash
# myproject.sh - shell tooling for myproject
# Source this file or place in mc_extensions directory.
#
# Integration with usb.sh:
#   This module sources usb.sh and composes on top of it.
#   If usb.sh is not found, USB features are unavailable but
#   local functionality still works.
#
# Replace "myproject" / "MYPROJECT" throughout with your project name.
# The project name must match the conf filename on the USB
# (e.g. myproject.conf -> USB_MYPROJECT_*).


# --- usb.sh integration check ---
# usb.sh is loaded by infrastructure (bash/06_usb.sh) before extensions.
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
        echo "myproject[WARN]: usb.sh found but not loaded (check bash/ chain load order)"
    else
        echo "myproject[WARN]: usb.sh not found, USB features unavailable"
    fi
    export USB_CONNECTED=false
fi

# =============================================================================
# SECTION 1: LOCAL CONFIGURATION (always available, no USB dependency)
# =============================================================================
# Everything in this section uses MYPROJECT_DIR. It works whether
# USB is connected or not.

# Local directory with USB fallback. If USB is connected and the project
# conf loaded, USB_MYPROJECT_LOCAL_DIR is set by usb.sh. Otherwise
# fall back to a hardcoded default. This single variable is the root
# for all local paths -- aliases, functions, and USB operations all
# reference it.
MYPROJECT_DIR="${USB_MYPROJECT_LOCAL_DIR:-$HOME/personal_repos/myproject}"

# Local aliases -- always available
alias mpcd='cd "$MYPROJECT_DIR"'
alias mpst='cd "$MYPROJECT_DIR" && git status && cd - > /dev/null'

# Local functions -- always available
# myproject_example() {
#     "${EDITOR:-nvim}" "$MYPROJECT_DIR/somefile.txt"
# }

# =============================================================================
# SECTION 2: USB OPERATIONS (requires USB_CONNECTED=true)
# =============================================================================
# Every function in this section must check USB_CONNECTED before
# doing USB-dependent work. These functions read USB_MOUNT_POINT
# and USB_MYPROJECT_REPO_PATH from usb.sh.
#
# Common pattern:
#   if [[ "$USB_CONNECTED" != true ]]; then
#       echo "myproject[ERROR]: USB not connected"
#       return 1
#   fi

# Example: pull from USB bare repo and sync
# myproject_pull() {
#     if [[ "$USB_CONNECTED" != true ]]; then
#         echo "myproject[ERROR]: USB not connected"
#         return 1
#     fi
#     if [[ ! -d "$MYPROJECT_DIR/.git" ]]; then
#         echo "myproject[ERROR]: $MYPROJECT_DIR is not a git repository"
#         return 1
#     fi
#     cd "$MYPROJECT_DIR" || return 1
#     git pull "$USB_MOUNT_POINT/$USB_MYPROJECT_REPO_PATH" master
#     usb_sync myproject
#     cd - > /dev/null
# }

# Example: commit and push to USB bare repo
# myproject_push() {
#     if [[ "$USB_CONNECTED" != true ]]; then
#         echo "myproject[ERROR]: USB not connected"
#         return 1
#     fi
#     if [[ ! -d "$MYPROJECT_DIR/.git" ]]; then
#         echo "myproject[ERROR]: $MYPROJECT_DIR is not a git repository"
#         return 1
#     fi
#     cd "$MYPROJECT_DIR" || return 1
#     git add -A
#     if git diff --cached --quiet; then
#         echo "myproject: nothing to commit"
#     else
#         git commit
#     fi
#     git push "$USB_MOUNT_POINT/$USB_MYPROJECT_REPO_PATH" master
#     usb_sync myproject
#     cd - > /dev/null
# }

# =============================================================================
# SECTION 3: SHELL INTERFACE (PS1 modification, optional)
# =============================================================================
# Indicator shows USB connection state in the prompt.
# Follows the same pattern as kbd.sh -- appends to MC_PS1 once.

# myproject_indicator() {
#     if [[ "$USB_CONNECTED" == true ]]; then
#         echo "mp[O]"
#     else
#         echo "mp[ ]"
#     fi
# }
#
# if [[ -z "$MC_PS1" ]]; then
#     MC_PS1='\u@\h:\w\$ '
# fi
# if [[ "$MC_PS1" != *'myproject_indicator'* ]]; then
#     MC_PS1='$(myproject_indicator)'"${MC_PS1}"
# fi
# export PS1="$MC_PS1"
