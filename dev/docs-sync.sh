#!/usr/bin/env bash
# dev/docs-sync.sh -- keep the README function table synced with usb.sh -h help.
#
# Usage:
#   dev/docs-sync.sh --check   # exit 1 (with a diff) if the table region is stale
#   dev/docs-sync.sh --write   # regenerate the table region between the markers
#
# Only the region between these README markers is generated (source order);
# all other README prose is hand-written:
#   <!-- BEGIN: generated function table -->
#   <!-- END: generated function table -->
#
# The single source of truth is each public function's -h help heredoc, whose
# first line must read "<funcname> - <purpose>".

export LC_ALL=C
set -u

usb_ds_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usb_ds_repo_root=$(cd "$usb_ds_script_dir/.." && pwd)
usb_ds_usb_sh="$usb_ds_repo_root/usb.sh"
usb_ds_readme="$usb_ds_repo_root/README.md"
usb_ds_begin='<!-- BEGIN: generated function table -->'
usb_ds_end='<!-- END: generated function table -->'
usb_ds_rows=()

usb_ds_fail() { echo "docs-sync: ERROR: $*" >&2; exit 1; }
usb_ds_usage() { echo "usage: docs-sync.sh --check | --write" >&2; exit 2; }

# Validate usb.sh and populate usb_ds_rows (one markdown row per function).
# Runs in the current shell so usb_ds_fail's exit aborts the whole script.
usb_ds_collect() {
    local usb_ds_dupes usb_ds_pairs usb_ds_fn usb_ds_help usb_ds_purpose
    local -a usb_ds_names

    [[ -f "$usb_ds_usb_sh" ]] || usb_ds_fail "usb.sh not found at $usb_ds_usb_sh"

    if grep -q $'\r' "$usb_ds_usb_sh"; then
        usb_ds_fail "usb.sh contains CRLF line endings"
    fi

    mapfile -t usb_ds_names < <(grep -oP '^usb_[a-z_]+(?=\(\) \{)' "$usb_ds_usb_sh")
    [[ ${#usb_ds_names[@]} -gt 0 ]] || usb_ds_fail "no public usb_* functions found in usb.sh"

    usb_ds_dupes=$(printf '%s\n' "${usb_ds_names[@]}" | sort | uniq -d | tr '\n' ' ')
    [[ -z "${usb_ds_dupes// /}" ]] || usb_ds_fail "duplicate function names: $usb_ds_dupes"

    # For each function def, capture the first heredoc's opening line's successor
    # (the help first line). A function that reaches the next def or EOF without
    # a heredoc is emitted as "MISSING<TAB><fn>".
    usb_ds_pairs=$(awk '
        /^usb_[a-z_]+\(\) \{/ {
            if (pending != "") print "MISSING\t" pending
            fn=$1; sub(/\(\)$/, "", fn); pending=fn; next
        }
        pending != "" && /<<.?EOF.?$/ {
            getline line
            print pending "\t" line
            pending=""
        }
        END { if (pending != "") print "MISSING\t" pending }
    ' "$usb_ds_usb_sh")

    usb_ds_rows=()
    while IFS=$'\t' read -r usb_ds_fn usb_ds_help; do
        [[ "$usb_ds_fn" == "MISSING" ]] && usb_ds_fail "function '$usb_ds_help' has no -h help heredoc"
        if [[ "$usb_ds_help" != "$usb_ds_fn - "* ]]; then
            usb_ds_fail "help first line for '$usb_ds_fn' must start with '$usb_ds_fn - ' (got: '$usb_ds_help')"
        fi
        usb_ds_purpose="${usb_ds_help#"$usb_ds_fn" - }"
        usb_ds_rows+=("| \`$usb_ds_fn\` | $usb_ds_purpose |")
    done <<< "$usb_ds_pairs"

    [[ ${#usb_ds_rows[@]} -eq ${#usb_ds_names[@]} ]] \
        || usb_ds_fail "internal: row count ${#usb_ds_rows[@]} != function count ${#usb_ds_names[@]}"
}

# Validate the README markers (exactly one each, BEGIN before END).
usb_ds_check_markers() {
    local usb_ds_nb usb_ds_ne usb_ds_bl usb_ds_el
    [[ -f "$usb_ds_readme" ]] || usb_ds_fail "README.md not found at $usb_ds_readme"
    usb_ds_nb=$(grep -cF -- "$usb_ds_begin" "$usb_ds_readme")
    usb_ds_ne=$(grep -cF -- "$usb_ds_end" "$usb_ds_readme")
    [[ "$usb_ds_nb" -eq 1 ]] || usb_ds_fail "expected exactly one BEGIN marker, found $usb_ds_nb"
    [[ "$usb_ds_ne" -eq 1 ]] || usb_ds_fail "expected exactly one END marker, found $usb_ds_ne"
    usb_ds_bl=$(grep -nF -- "$usb_ds_begin" "$usb_ds_readme" | cut -d: -f1)
    usb_ds_el=$(grep -nF -- "$usb_ds_end" "$usb_ds_readme" | cut -d: -f1)
    [[ "$usb_ds_bl" -lt "$usb_ds_el" ]] || usb_ds_fail "BEGIN marker must precede END marker"
}

# Emit the desired full README (region between markers replaced by the table).
usb_ds_build_expected() {
    local usb_ds_bl usb_ds_el
    usb_ds_bl=$(grep -nF -- "$usb_ds_begin" "$usb_ds_readme" | cut -d: -f1)
    usb_ds_el=$(grep -nF -- "$usb_ds_end" "$usb_ds_readme" | cut -d: -f1)
    sed -n "1,${usb_ds_bl}p" "$usb_ds_readme"
    printf '%s\n' "| Function | Purpose |" "| --- | --- |"
    printf '%s\n' "${usb_ds_rows[@]}"
    sed -n "${usb_ds_el},\$p" "$usb_ds_readme"
}

usb_ds_check() {
    local usb_ds_diff
    if usb_ds_diff=$(diff -u "$usb_ds_readme" <(usb_ds_build_expected)); then
        echo "docs-sync: README function table is up to date."
        return 0
    fi
    echo "docs-sync: README function table is stale. Run: dev/docs-sync.sh --write" >&2
    printf '%s\n' "$usb_ds_diff" >&2
    exit 1
}

usb_ds_write() {
    local usb_ds_tmp
    usb_ds_tmp=$(mktemp)
    usb_ds_build_expected > "$usb_ds_tmp"
    mv "$usb_ds_tmp" "$usb_ds_readme"
    # idempotency guard: a second generation must produce no change
    if ! diff -q "$usb_ds_readme" <(usb_ds_build_expected) >/dev/null; then
        usb_ds_fail "--write is not idempotent (generation is unstable)"
    fi
    echo "docs-sync: README function table regenerated."
}

[[ $# -eq 1 ]] || usb_ds_usage
usb_ds_collect
usb_ds_check_markers
case "$1" in
    --check) usb_ds_check ;;
    --write) usb_ds_write ;;
    *)       usb_ds_usage ;;
esac
