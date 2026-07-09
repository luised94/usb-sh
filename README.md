
# usb-sh

Portable USB management for multi-project workflows. Handles USB detection,
project configuration loading, file synchronization, and bare-repo git
operations across WSL and Linux.

## Quick Reference

All functions support `-h` for usage help.

<!-- BEGIN: generated function table -->
| Function | Purpose |
| --- | --- |
| `usb_verify_connected` | check USB is still physically connected |
| `usb_commit` | stage and commit changes in a loaded project |
| `usb_push` | push local git repo to USB bare repo |
| `usb_pull` | pull from USB bare repo to local git repo |
| `usb_init_bare` | create bare repo on USB for a loaded project |
| `usb_clone_all` | clone all bare repos from USB to local directories |
| `usb_sync` | manually trigger file sync for one or all loaded projects |
| `usb_eject` | pre-eject sync, unmount, and clean up state |
| `usb_refresh` | re-detect USB and reload all project configurations |
| `usb_status` | print diagnostic information about USB state |
| `usb_check` | validate conf files, check paths, and detect config drift |
| `usb_new_project` | create a new project configuration file |
| `usb_init_keys` | create encrypted API key file on USB |
| `usb_edit_keys` | edit the encrypted API key file |
| `usb_load_keys` | load encrypted API keys into environment |
| `usb_unload_keys` | remove API keys from environment |
| `usb_keys_status` | show API key management state |
| `usb_shutdown` | unload keys and eject USB |
<!-- END: generated function table -->

## Repository Structure
usb.sh                              Main module
README.md                           This file
docs/
    design.md                         Architecture, schema, and invariants
    usb-setup.md                      Operational reference and setup steps
    module-template.sh                Integration template for new project modules
    initial-usb-setup.md              Historical: initial USB setup log
    implementation-plan.md            Historical: original 7-phase build plan
    deferred-and-monitoring.md        Active: deferred items, monitoring, triggers
configs/
    _template.conf.example            Template for scaffolding new project confs
    finance.conf.reference            Reference copy of finance project configuration
    friction.conf.reference           Reference copy of friction project configuration
    kbd.conf.reference                Reference copy of kbd project configuration
    lab.conf.reference                Reference copy of lab project configuration
    tasks.conf.reference              Reference copy of tasks project configuration

## Setup

See [docs/usb-setup.md](docs/usb-setup.md) for complete setup instructions
including the loading architecture and `.bashrc` integration.

For architecture and schema details, see [docs/design.md](docs/design.md).

## Session teardown

`usb_shutdown` unloads keys and ejects the USB. It deliberately does not end
your terminal or kill tmux -- session-lifecycle policy belongs in your shell,
not this module. To tear down the session as well, compose it in `~/.bashrc`:

    session_end() { usb_shutdown && tmux kill-server; }

## Adding a New Project

Run `usb_new_project <name>` for an interactive scaffold that creates the
conf file on the USB. Then run `usb_init_bare <name>` to create the bare
repo. See [docs/module-template.sh](docs/module-template.sh) for the
module integration pattern.

## Development

The function table under Quick Reference is generated from each function's
`-h` help by `dev/docs-sync.sh`. After editing help text, regenerate it:

    dev/docs-sync.sh --write

Enable the versioned pre-commit hook once per clone so a stale table (or a
malformed help line) blocks the commit:

    git config core.hooksPath dev/hooks
