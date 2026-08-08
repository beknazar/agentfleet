#!/usr/bin/env bash
# Toolchain for one agent machine. Pushed and run by `agentfleet provision`.
#
# Idempotent: re-running it is the fix for a half-finished install, which is the
# state you actually find machines in.
#
# Toolchain only. No credential ever lands here - those arrive later via
# `agentfleet sync`, which can put them in mode-600 files instead of in a
# script that gets copied to ten machines.
#
# RULE: no strict-confinement snaps. Snaps are AppArmor-confined and cannot read
# a home directory outside /home, which is exactly what path mirroring (AF_HOME)
# gives you: the snap installs cleanly and then cannot see a single one of the
# agent's files. Everything below comes from the distro repo or the vendor's own
# installer. Anyone rewriting this will reach for `snap install` and break the
# machine in a way that looks like a permissions bug.
#
# Assumes Debian/Ubuntu (apt).
set -euo pipefail

AF_NAME="${AF_NAME:-agentfleet}"
AF_AGENT="${AF_AGENT:-claude}"
AF_NODE_VERSION="${AF_NODE_VERSION:-22}"
AF_PKG_EXTRA="${AF_PKG_EXTRA:-}"
AF_NPM_EXTRA="${AF_NPM_EXTRA:-}"
AF_BROWSER="${AF_BROWSER:-0}"

# Pinned so an upstream release cannot change what every machine in the fleet
# installs on the same afternoon. Bump deliberately.
NVM_VERSION="v0.40.1"

log() { printf '[bootstrap] %s\n' "$*"; }
die() { printf '[bootstrap] FAILED: %s\n' "$*" >&2; exit 1; }

command -v apt-get >/dev/null 2>&1 || die "no apt-get: agentfleet's machine image is Debian/Ubuntu"
sudo -n true 2>/dev/null || die "passwordless sudo is required for $(id -un) on this machine"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- packages

# Core, in the order you would miss them: the agent's own session (tmux), the
# things every agent shells out to (git, ripgrep, jq, python3), what agentfleet
# itself needs on the far end (rsync, curl, unzip), and the web terminal that
# makes a machine watchable from a phone (ttyd).
CORE_PKGS="ca-certificates curl git jq tmux rsync unzip ripgrep python3 python3-venv build-essential ttyd"

# Only pulled in when the browser stack is enabled: an Xvfb display, a VNC
# server for it, and the noVNC bridge that turns that into a web page.
BROWSER_PKGS="xvfb x11vnc novnc websockify fonts-liberation"

log "apt: core toolchain"
sudo apt-get update -qq
# shellcheck disable=SC2086
sudo apt-get install -y -qq $CORE_PKGS

if [ "$AF_BROWSER" = 1 ]; then
  log "apt: browser stack"
  # shellcheck disable=SC2086
  sudo apt-get install -y -qq $BROWSER_PKGS
fi

if [ -n "$AF_PKG_EXTRA" ]; then
  log "apt: extras ($AF_PKG_EXTRA)"
  # shellcheck disable=SC2086
  sudo apt-get install -y -qq $AF_PKG_EXTRA
fi

# ---------------------------------------------------------------- node

log "node $AF_NODE_VERSION (nvm $NVM_VERSION)"
if [ ! -d "$HOME/.nvm" ]; then
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | bash >/dev/null
fi
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
nvm install "$AF_NODE_VERSION" >/dev/null
nvm alias default "$AF_NODE_VERSION" >/dev/null
NODE_BIN="$(dirname "$(nvm which "$AF_NODE_VERSION")")"
export PATH="$NODE_BIN:$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------- agent CLI

case "$AF_AGENT" in
  claude|both)
    log "claude code"
    command -v claude >/dev/null 2>&1 || curl -fsSL https://claude.ai/install.sh | bash >/dev/null
    ;;
esac
case "$AF_AGENT" in
  codex|both)
    log "codex"
    command -v codex >/dev/null 2>&1 || npm install -g @openai/codex >/dev/null
    ;;
esac
case "$AF_AGENT" in
  claude|codex|both|none) ;;
  *) die "unknown AF_AGENT: $AF_AGENT (claude, codex, both, none)" ;;
esac

if [ -n "$AF_NPM_EXTRA" ]; then
  log "npm -g extras ($AF_NPM_EXTRA)"
  # shellcheck disable=SC2086
  npm install -g $AF_NPM_EXTRA >/dev/null
fi

if [ "$AF_BROWSER" = 1 ]; then
  log "playwright chromium (vendor download, not a snap)"
  npm install -g playwright >/dev/null
  playwright install --with-deps chromium >/dev/null 2>&1 ||
    log "WARN: chromium download failed; rerun 'playwright install chromium' on the machine"
fi

# ---------------------------------------------------------------- PATH

# systemd units and `ssh host <cmd>` do not read a login profile, so anything
# reachable only through ~/.zshrc or nvm's shell function is invisible to half
# the things that need it. Symlink the handful of binaries that get invoked
# non-interactively into a directory that is always on PATH.
log "exposing binaries to non-login shells"
for b in node npm npx corepack claude codex playwright; do
  src=""
  if [ -x "$NODE_BIN/$b" ]; then
    src="$NODE_BIN/$b"
  elif [ -x "$HOME/.local/bin/$b" ]; then
    src="$HOME/.local/bin/$b"
  fi
  if [ -n "$src" ]; then sudo ln -sf "$src" "/usr/local/bin/$b"; fi
done

# Login shells still get the user-local bin dirs, for the human who ssh's in.
sudo tee "/etc/profile.d/$AF_NAME-path.sh" >/dev/null <<'EOF'
# Managed by agentfleet.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac
export PATH
EOF

# ---------------------------------------------------------------- shims

# Scripts written on a Mac get synced to these machines verbatim, and some of
# them wrap long jobs in `caffeinate` to keep the laptop awake. There is no
# Linux equivalent and no need for one, so absorb the flags and run the rest.
# Costs nothing, and without it a synced wrapper dies on command-not-found.
# shellcheck disable=SC2016  # the shim's body must reach the machine unexpanded
printf '#!/bin/sh\nwhile [ "$1" != "${1#-}" ]; do shift; done\nexec "$@"\n' |
  sudo tee /usr/local/bin/caffeinate >/dev/null
sudo chmod +x /usr/local/bin/caffeinate

# If you sync a shell rc that lists plugins (oh-my-zsh and friends), install
# those plugins too via AF_PKG_EXTRA or a provision hook. A missing plugin makes
# every non-interactive shell print a warning to stderr, and that warning ends
# up mixed into the command output this tool parses.

# ---------------------------------------------------------------- verify

# A tool that is missing is not a warning, it is a machine that will fail its
# first real job in a way nobody connects back to provisioning.
log "verifying"
missing=""
# BINARY names, not package names. The apt package is `ripgrep` and the only
# thing it puts on PATH is `rg`, so checking for `ripgrep` here failed on every
# machine and turned a successful ten-minute provision into "NOT provisioned".
# Anything added below must be the name you would type, not the name you install.
CHECK="git jq tmux rsync rg python3 node npm ttyd"
case "$AF_AGENT" in
  claude) CHECK="$CHECK claude" ;;
  codex)  CHECK="$CHECK codex" ;;
  both)   CHECK="$CHECK claude codex" ;;
esac
for c in $CHECK; do
  if ! command -v "$c" >/dev/null 2>&1; then missing="$missing $c"; fi
done
if [ -n "$missing" ]; then die "missing after install:$missing"; fi

printf '[bootstrap] ok: node %s, tmux %s, agent=%s\n' \
  "$(node --version 2>/dev/null)" \
  "$(tmux -V 2>/dev/null | awk '{print $2}')" \
  "$AF_AGENT"
