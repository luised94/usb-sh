# usb-setup
## Background
Reference document for the first versions of `.usb-manifest` and `.usb-projects/kbd.conf`
Documents were created 2026-03-16. Verified against USB content 2026-03-16.
```

## .usb-manifest
```bash
USB_MANIFEST_VERSION=1
USB_LABEL="luised94-usb"
USB_SYNC_LOG=".usb-sync.log"
USB_DEFAULT_PHASE="auto"
```

## .usb-projects/kbd.conf
```bash
local_dir="$HOME/personal_repos/kbd"
repo_path="personal_repos/kbd.git"
sync_files=("{USB_ROOT}/shared/kbd_zotero_library.bib:{LOCAL_DIR}/zotero_library.bib:newer:auto")
sync_dirs=()
```
