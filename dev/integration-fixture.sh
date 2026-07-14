#!/usr/bin/env bash
# dev/integration-fixture.sh -- source usb.sh against a fake USB mount and
# print usb_status + usb_check output (and startup stderr) for comparison
# across commits. Usage: bash dev/integration-fixture.sh <usb.sh-path>
# Requires a writable /mnt (sandbox/CI). Sets up:
#   /mnt/fakeusb/.usb-manifest, .usb-projects/{alpha,beta}.conf
#   $HOME/fixture-local/{alpha,beta} local git repos
#   bare repo on the fake USB for alpha (so branch/divergence paths run)
set -u
target_usb_sh="$1"

export USER="${USER:-root}"
export MC_WINDOWS_USER="winfixture"
mount="/mnt/fakeusb"

rm -rf "$mount" "$HOME/fixture-local"
mkdir -p "$mount/.usb-projects" "$mount/shared" "$HOME/fixture-local"

cat > "$mount/.usb-manifest" <<'EOF'
VERSION=1
LABEL=FIXTURE
SYNC_LOG=sync.log
EOF

# alpha: full project with git repo, bare repo, sync entries
mkdir -p "$HOME/fixture-local/alpha/docs"
git -C "$HOME/fixture-local/alpha" init -q -b main
echo hello > "$HOME/fixture-local/alpha/file.txt"
git -C "$HOME/fixture-local/alpha" add -A
git -C "$HOME/fixture-local/alpha" -c user.email=f@x -c user.name=f commit -qm init
git clone -q --bare "$HOME/fixture-local/alpha" "$mount/repos/alpha.git"
echo shared > "$mount/shared/note.txt"
cat > "$mount/.usb-projects/alpha.conf" <<'EOF'
local_dir={HOME}/fixture-local/alpha
repo_path=repos/alpha.git
sync_file={USB_ROOT}/shared/note.txt:{LOCAL_DIR}/docs/note.txt:newer
sync_dir={USB_ROOT}/shared:{LOCAL_DIR}/docs:differs
EOF

# beta: loaded but no bare repo; exercises warn paths
mkdir -p "$HOME/fixture-local/beta"
git -C "$HOME/fixture-local/beta" init -q -b main
cat > "$mount/.usb-projects/beta.conf" <<'EOF'
local_dir={HOME}/fixture-local/beta
repo_path=repos/beta.git
EOF

run() { # label; sources usb.sh fresh in a subshell, prints tagged output
    local label="$1"
    bash -c '
        set +e
        source "'"$target_usb_sh"'" force 2> /tmp/fixture-source.stderr
        echo "== source rc: $? connected: $USB_CONNECTED =="
        echo "== source stderr =="
        cat /tmp/fixture-source.stderr
        echo "== usb_status stdout =="
        usb_status 2>/tmp/fixture-status.stderr
        echo "== usb_status stderr =="
        cat /tmp/fixture-status.stderr
        echo "== usb_check =="
        usb_check 2>&1
        echo "== usb_check rc: $? =="
    '
}

run main
