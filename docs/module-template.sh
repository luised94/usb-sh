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

# --- Source guard for usb.sh ---
# usb.sh sets USB_CONNECTED and USB_MYPROJECT_* variables.
# If usb.sh is missing, set USB_CONNECTED=false so USB-dependent
# code can check one variable without caring why USB is unavailable.
if [[ -f "$HOME/.config/mc_extensions/usb.sh" ]]; then
    source "$HOME/.config/mc_extensions/usb.sh"
else
    export USB_CONNECTED=false
    echo "myproject[WARN]: usb.sh not found, USB features unavailable"
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
