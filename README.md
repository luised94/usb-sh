
# usb-sh

Portable USB management for multi-project workflows. Handles USB detection,
project configuration loading, file synchronization, and bare-repo git
operations across WSL and Linux.

## Quick Reference

All functions support `-h` for usage help.

| Function | Purpose |
|----------|---------|
| `usb_push <project>` | Push current branch to USB bare repo |
| `usb_pull <project>` | Pull current branch from USB bare repo |
| `usb_sync [project]` | Run manual-phase file and directory sync entries |
| `usb_eject` | Sync, unmount, and eject USB |
| `usb_status` | Print USB connection state and per-project details |
| `usb_check` | Validate confs, paths, git remotes, and branch consistency |
| `usb_new_project <name>` | Create new project conf file via editor scaffold |
| `usb_init_bare <project>` | Create bare repo on USB for a loaded project |
| `usb_clone_all` | Clone all USB bare repos to local directories |
| `usb_refresh` | Re-detect USB and reload all project configurations |
| `usb_verify_connected` | Check USB is still physically accessible |

## Repository Structure
usb.sh                              Main module
README.md                           This file
docs/
    design.md                         Architecture, schema, phase model
    usb-setup.md                      Operational reference and setup steps
    module-template.sh                Integration template for new project modules
    initial-usb-setup.md              Historical: initial USB setup log
    implementation-plan.md            Historical: original 7-phase build plan
    deferred-and-monitoring.md        Active: deferred items, monitoring, triggers
configs/
    kbd.conf.reference                Reference copy of kbd project configuration
    finances.conf.reference           Reference copy of finances project configuration

## Setup

See [docs/usb-setup.md](docs/usb-setup.md) for complete setup instructions
including the loading architecture and `.bashrc` integration.

For architecture and schema details, see [docs/design.md](docs/design.md).

## Adding a New Project

Run `usb_new_project <name>` for an interactive scaffold that creates the
conf file on the USB. Then run `usb_init_bare <name>` to create the bare
repo. See [docs/module-template.sh](docs/module-template.sh) for the
module integration pattern.
