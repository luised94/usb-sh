#!/usr/bin/env bash
# dev/parse-fixture.sh -- ad-hoc fixture harness for the shared conf parser.
# Usage: bash dev/parse-fixture.sh   (run from repo root or anywhere)
#
# Extracts only the helper definitions (_usb_parse_conf,
# _usb_resolve_sync_entry) from usb.sh -- the file is source-time active and
# cannot be sourced whole in a test context -- then runs fixtures F1-F3 from
# the implementation plan.

set -u

pf_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pf_usb_sh="$pf_script_dir/../usb.sh"
pf_fail_count=0
pf_pass_count=0

pf_ok()   { pf_pass_count=$((pf_pass_count + 1)); echo "PASS: $*"; }
pf_fail() { pf_fail_count=$((pf_fail_count + 1)); echo "FAIL: $*" >&2; }

pf_assert_eq() { # desc expected actual
    if [[ "$2" == "$3" ]]; then pf_ok "$1"; else pf_fail "$1 (expected [$2], got [$3])"; fi
}

# Extract a function body by name: from "name() {" to the first line that is
# exactly "}" at column 0.
pf_extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { emit=1 }
        emit { print }
        emit && /^\}/ { exit }
    ' "$pf_usb_sh"
}

# Diagnostic emitter stubs (the real ones live above the extraction range).
_usb_msg()  { echo "usb: $*" >&2; }
_usb_warn() { echo "usb[WARN]: $*" >&2; }
_usb_err()  { echo "usb[ERROR]: $*" >&2; }

pf_parse_conf_src=$(pf_extract_fn "_usb_parse_conf")
pf_resolve_src=$(pf_extract_fn "_usb_resolve_sync_entry")

if [[ -z "$pf_parse_conf_src" || -z "$pf_resolve_src" ]]; then
    echo "fixture: helpers not found in usb.sh (pre-C2 tree?)" >&2
    exit 2
fi
eval "$pf_parse_conf_src"
eval "$pf_resolve_src"

# Environment the helpers read.
export USB_WINDOWS_USER="winuser"
export USB_MOUNT_POINT="/mnt/fixture"

pf_tmpdir=$(mktemp -d)
trap 'rm -rf "$pf_tmpdir"' EXIT

# --- F1: full-featured conf ------------------------------------------------
pf_conf="$pf_tmpdir/f1.conf"
{
    printf '# a comment\n'
    printf '\n'
    printf 'local_dir={HOME}/x-{WINDOWS_USER}\n'
    printf 'repo_path=y.git\n'
    printf 'sync_file={USB_ROOT}/a:{LOCAL_DIR}/b-{WINDOWS_USER}:newer\r\n'   # CRLF line
    printf 'sync_dir={USB_ROOT}/d:{LOCAL_DIR}/e:differs\n'
    printf 'this line has no equals sign\n'
    printf 'Uppercase=1\n'
    printf 'zzz=1\n'
} > "$pf_conf"

pf_ld="" pf_rp=""
pf_sf=() pf_sd=()
pf_stderr="$pf_tmpdir/f1.stderr"
_usb_parse_conf "$pf_conf" pf_ld pf_rp pf_sf pf_sd 2> "$pf_stderr"
pf_rc=$?

pf_assert_eq "F1 rc"          "0" "$pf_rc"
pf_assert_eq "F1 local_dir"   "$HOME/x-winuser" "$pf_ld"
pf_assert_eq "F1 repo_path"   "y.git" "$pf_rp"
pf_assert_eq "F1 sync_file raw (CRLF stripped, tokens unresolved)" \
    '{USB_ROOT}/a:{LOCAL_DIR}/b-{WINDOWS_USER}:newer' "${pf_sf[0]-}"
pf_assert_eq "F1 sync_dir raw" '{USB_ROOT}/d:{LOCAL_DIR}/e:differs' "${pf_sd[0]-}"
pf_assert_eq "F1 sync_files count" "1" "${#pf_sf[@]}"
pf_assert_eq "F1 sync_dirs count"  "1" "${#pf_sd[@]}"
grep -q "malformed line" "$pf_stderr" && pf_ok "F1 malformed warn" || pf_fail "F1 malformed warn missing"
grep -q "invalid key: Uppercase" "$pf_stderr" && pf_ok "F1 invalid-key warn" || pf_fail "F1 invalid-key warn missing"
grep -q "unknown key: zzz" "$pf_stderr" && pf_ok "F1 unknown-key warn" || pf_fail "F1 unknown-key warn missing"

# --- F2: missing local_dir -> empty out-param, rc 0 (readable file) ---------
pf_conf2="$pf_tmpdir/f2.conf"
printf 'repo_path=z.git\n' > "$pf_conf2"
pf_ld="preset" pf_rp=""
pf_sf=() pf_sd=()
_usb_parse_conf "$pf_conf2" pf_ld pf_rp pf_sf pf_sd 2>/dev/null
pf_rc=$?
pf_assert_eq "F2 rc (readable file)" "0" "$pf_rc"
pf_assert_eq "F2 local_dir out-param empty" "" "$pf_ld"

# F2b: unreadable path -> rc 1
_usb_parse_conf "$pf_tmpdir/does-not-exist.conf" pf_ld pf_rp pf_sf pf_sd 2>/dev/null
pf_assert_eq "F2b rc (missing file)" "1" "$?"

# --- F3: resolver ------------------------------------------------------------
pf_resolved=$(_usb_resolve_sync_entry \
    '{USB_ROOT}/a:{LOCAL_DIR}/b:{WINDOWS_USER}' '/home/u/proj')
pf_assert_eq "F3 resolve all three tokens" \
    "/mnt/fixture/a:/home/u/proj/b:winuser" "$pf_resolved"

echo "----"
echo "fixture: $pf_pass_count passed, $pf_fail_count failed"
[[ $pf_fail_count -eq 0 ]]
