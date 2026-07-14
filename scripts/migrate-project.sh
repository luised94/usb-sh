#!/usr/bin/env bash
# migrate-project.sh -- M3+M4 for ONE project: move the local dir under
# usb-repos/ and rewrite local_dir in the live USB conf. Flat and sequential;
# every mutation is echoed before it runs and the conf is backed up first.
#
# Usage: bash migrate-project.sh <local_leaf> <conf_name> <usb_mount>
#   local_leaf -- directory name under ~/personal_repos (e.g. kbd, finances)
#   conf_name  -- conf basename without .conf (e.g. kbd, finance)
#   usb_mount  -- USB mount point (e.g. /mnt/d)
#
# Deliberately does NOT touch your shell session: after this script, run
# usb_refresh and usb_check in your interactive shell (the usb_* functions
# live there, not in this subshell).
set -u

leaf="${1:?usage: bash migrate-project.sh <local_leaf> <conf_name> <usb_mount>}"
conf_name="${2:?usage: bash migrate-project.sh <local_leaf> <conf_name> <usb_mount>}"
usb_mount="${3:?usage: bash migrate-project.sh <local_leaf> <conf_name> <usb_mount>}"

src="$HOME/personal_repos/$leaf"
dst="$HOME/personal_repos/usb-repos/$leaf"
conf="$usb_mount/.usb-projects/${conf_name}.conf"
new_line="local_dir={HOME}/personal_repos/usb-repos/$leaf"

fail() { echo "ABORT: $*" >&2; exit 1; }

echo "== migrate-project: leaf=$leaf conf=$conf =="

# --- preflight checks (no mutation) ---
[[ -d "$src" ]]        || fail "source missing: $src"
[[ ! -e "$dst" ]]      || fail "destination already exists: $dst"
[[ -f "$conf" ]]       || fail "live conf missing: $conf"
[[ -d "$src/.git" ]]   || fail "$src is not a git repo"
grep -q '^local_dir=' "$conf" || fail "no local_dir line in $conf"
grep -q "^local_dir={HOME}/personal_repos/usb-repos/" "$conf" \
    && fail "conf already migrated: $(grep '^local_dir=' "$conf")"

# refuse to move a dirty worktree: M2 requires clean + pushed
dirty=$(git -C "$src" status --porcelain | wc -l)
[[ "$dirty" -eq 0 ]] || fail "worktree dirty ($dirty changes) -- run usb_commit/usb_push first (M2)"

echo "preflight ok:"
echo "  mv   $src -> $dst"
echo "  conf $(grep '^local_dir=' "$conf")  ->  $new_line"

# --- mutations ---
echo "RUN: mkdir -p $HOME/personal_repos/usb-repos"
mkdir -p "$HOME/personal_repos/usb-repos" || fail "mkdir failed"

echo "RUN: cp $conf $conf.pre-migration.bak"
cp "$conf" "$conf.pre-migration.bak" || fail "conf backup failed"

echo "RUN: mv $src $dst"
mv "$src" "$dst" || fail "mv failed"

echo "RUN: rewrite local_dir in $conf"
# sed with | delimiter; anchored to the whole local_dir line
if ! sed -i "s|^local_dir=.*$|$new_line|" "$conf"; then
    echo "sed failed -- restoring conf from backup and moving dir back" >&2
    cp "$conf.pre-migration.bak" "$conf"
    mv "$dst" "$src"
    fail "rolled back"
fi

# --- verification ---
echo "== verify =="
grep '^local_dir=' "$conf" | grep -qx "$new_line" || fail "conf rewrite did not take"
[[ -d "$dst/.git" ]] || fail "moved dir lost its .git?!"
echo "  conf: $(grep '^local_dir=' "$conf")"
echo "  dir:  $dst (git repo present)"
echo "  bak:  $conf.pre-migration.bak"
echo
echo "DONE. Now in your INTERACTIVE shell:"
echo "  usb_refresh          # expect: $conf_name loads"
echo "  usb_check            # expect: drift WARN for ${conf_name}.conf (the signal), no new errors"
echo "  # round trip: touch a file, usb_commit $conf_name, usb_push, usb_pull, usb_status"
echo "Rollback if needed:"
echo "  mv $dst $src && cp $conf.pre-migration.bak $conf   # then usb_refresh"
