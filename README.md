# Systemd Services

## ssh-agent.service
to setup you need to add this to a ~/.zshrc, ~/.bashrc, ~/.bash_profile, ~/.zshenv
```bash
export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.socket"
```
