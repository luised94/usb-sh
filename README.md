# usb.sh

A reusable shell module for USB detection, project configuration loading,
and file synchronization across multiple projects sharing a single USB drive.

Source `usb.sh` from a project-specific shell module (e.g. `kbd.sh`).
It handles finding the USB drive, loading per-project configuration from
`.usb-projects/*.conf` on the USB, syncing files according to declared
rules on startup and eject, and unmounting safely. It knows nothing about
any specific project -- git operations, multi-hop syncs, and
project-specific logic stay in the project module.

## Documentation

- `docs/design.md`     -- architecture, schema, phase model, variable namespace
- `docs/usb-setup.md`  -- reference copies of .usb-manifest and conf files,
                          USB directory structure

## Delivery

`~/.config/mc_extensions/usb.sh` symlinks to this `~/personal_repos/usb-sh/usb.sh`.
Projects source it via the symlink path (use mc_link_extension from the my_config repo).
