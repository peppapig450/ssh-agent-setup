# SSH Agent Automation

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache-2.0-yellow.svg)](./LICENSE)

A production-ready toolkit to automate SSH agent management on Linux via systemd user services, featuring auto-start, key loading, and multi-shell integration.

## Overview

* **Automatic `ssh-agent` startup** at login via systemd user services
* **Auto-loading of SSH keys** (passwordless only)
* **Multi-shell support** (bash, zsh, fish, elvish)
* **Chezmoi integration** for dotfile-managed environments
* **Robust logging** and error handling

## Repository Structure

```
.
├── README.md
├── ssh-agent.service
├── ssh-add.service
├── ssh-agent-setup.sh
└── lib/
    └── logging/
        ├── LICENSE
        ├── README.md
        └── logging.lib.sh
```

## Features

### SSH Agent Management

* Systemd user services for reliable agent lifecycle management
* Automatic startup and proper socket management
* Batch loading of multiple keys
* **Limitation**: Only passwordless SSH keys are supported due to systemd's non-interactive nature.

### Shell Integration

* Support for bash, zsh, fish, and elvish
* Automatic detection and update of RC files
* Interactive shell selector with `fzf` fallback handling

### Dotfile Management

* Detects and updates chezmoi-managed dotfiles
* Safe RC file creation with user confirmation

### Logging Library

* Color-coded output and UTC timestamps
* Automatic error tracing and safe trap chaining
* Google Shell Style Guide compliant
* See `lib/logging/README.md` for details
* Vendored from [Bashing logs](https://github.com/peppapig450/bashing-logs)

## Quick Start

### Prerequisites

* Linux with systemd and Bash 4.0+
* Standard Unix utilities: `systemctl`, `ssh-add`, `awk`, `grep`, `perl`
* One or more **passwordless** SSH private keys

### Installation

```bash
git clone https://github.com/peppapig450/ssh-agent-setup.git
cd ssh-agent-automation

# Interactive setup
./ssh-agent-setup.sh

# Or specify keys directly
./ssh-agent-setup.sh ~/.ssh/id_ed25519 ~/.ssh/id_rsa
```

Follow the interactive prompts to select shells, confirm RC modifications, and enable/start services. Then start a new shell or source your RC file:

```bash
source ~/.bashrc
# or
source ~/.zshrc
# fish users
source ~/.config/fish/conf.d/ssh_agent.fish
```

## Usage

### Basic Setup

```bash
./ssh-agent-setup.sh ~/.ssh/id_ed25519
```

This sets up systemd user services, updates your shell RC, enables services, and loads the key.

### Advanced Options

* **Multiple keys**: `./ssh-agent-setup.sh ~/.ssh/id_ed25519 ~/.ssh/id_rsa`
* **Shell selection**: Interactive with `fzf` or fallback selector
* **Chezmoi integration**: Auto-detects chezmoi-managed files

### Manual Operations

```bash
# Check status
systemctl --user status ssh-agent.service ssh-add.service

# View logs
journalctl --user -u ssh-agent.service -f

# Restart services
systemctl --user restart ssh-agent.service ssh-add.service
```

## Uninstallation

```bash
# Disable and stop services
systemctl --user disable --now ssh-agent.service ssh-add.service

# Remove service files
rm ~/.config/systemd/user/ssh-agent.service ~/.config/systemd/user/ssh-add.service

# Reload
systemctl --user daemon-reload

# Remove RC modifications as needed
```

## Contributing

1. Fork the repo
2. Create a branch: `git checkout -b feature/awesome`
3. Follow the Google Shell Style Guide and add tests
4. Commit and push
5. Open a PR

## Troubleshooting

* **"Service failed to start"**: Check logs (`journalctl --user -u ssh-agent.service`) and key paths.
* **"Password-protected SSH keys not loading"**: Use passwordless keys or add keys manually after login (`ssh-add ~/.ssh/id_rsa`).
* **"SSH_AUTH_SOCK not set"**: Source your RC or start a new shell.

## License

Apache-2.0 - see [LICENSE](./LICENSE)

## Acknowledgments

Inspired by the need for adaptive and reliable SSH agent management.

> **Pro Tip**: Pair this toolkit with [chezmoi](https://chezmoi.io/) and [fzf](https://github.com/junegunn/fzf) for an even smoother experience!
