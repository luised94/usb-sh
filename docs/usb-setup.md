# usb-setup
## Background
Reference document for the first versions of `.usb-manifest` and `.usb-projects/kbd.conf`
Documents were created 2026-03-16. Verified against USB content 2026-03-16.
`.usb-manifest` updated 2026-03-17 to key:value format.
## .usb-manifest
```bash
# .usb-manifest assigned to $USB_MANIFEST_FILENAME.
cat > "$USB_MOUNT_POINT/.usb-manifest" << 'EOF'
VERSION=1
LABEL=luised94-usb
SYNC_LOG=.usb-sync.log
DEFAULT_PHASE=auto
EOF
```

## .usb-projects/kbd.conf
```bash
local_dir="$HOME/personal_repos/kbd"
repo_path="personal_repos/kbd.git"
sync_files=("{USB_ROOT}/shared/kbd_zotero_library.bib:{LOCAL_DIR}/zotero_library.bib:newer:auto")
sync_dirs=()
```
