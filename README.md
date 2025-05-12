# Systemd Services

This directory contains **user-level systemd services** and supporting scripts.

Each services automates some kind of long-lived or login-triggered behavior using systemd's
`--user` mode. These are intended to be used on Linux systems with systemd and not macOS (which uses `launchd` because Apple likes being difficult).

## Included Services

### `ssh-agent`

Starts `ssh-agent` once per session and auto-adds your private keys using a companion service.
NOTE: This only works with ssh-keys that do **NOT** have a password.

- `ssh-agent.service`: systemd user service to start `ssh-agent`
- `ssh-add.service`: template for loading key(s) into the agent
- `ssh-agent-setup.sh`: setup to script to install/configure both services

#### Setup:

```bash
./ssh-agent-setup.sh ~/.ssh/id_ed25519
```

- If no keys are passed, it prompts interactively
- Appends `SSH_AUTH_SOCK` to your `.bashrc` or `.zshrc`
- Creates `~/.config/systemd/user/ssh-add.service`
- Enable and starts both services

#### Manual uninstall:

```bash
systemctl --user disable --now ssh-agent.service ssh-add.service
rm ~/.config/systemd/user/ssh-{agent,add}.service
# remove SSH_AUTH_SOCK from your shell rc manually
```

If you're not on Linux with systemd... sorry.
