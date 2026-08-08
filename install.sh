#!/usr/bin/env bash
# agentfleet installer.
#
# All it does: check a few commands exist, then symlink the `agentfleet`
# entrypoint from this checkout into a directory on your PATH.
#
# It downloads nothing, writes no config, and contacts no network. The link
# points back at this checkout, so `git pull` here updates the installed tool.
# Uninstall is `rm` on the symlink it prints.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SELF_DIR/agentfleet"

if [ ! -f "$SRC" ]; then
  echo "install.sh: no agentfleet next to this script - run it from inside the checkout" >&2
  exit 1
fi
chmod +x "$SRC" 2>/dev/null || true

# ---------------------------------------------------------------- dependencies

missing=""
for c in bash ssh scp rsync; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [ -n "$missing" ]; then
  echo "install.sh: required commands are not installed:$missing" >&2
  exit 1
fi

# Not fatal: each one gates a single command, and the rest of the tool works.
command -v jq   >/dev/null 2>&1 || echo "note: jq is not installed - 'agentfleet ls' needs it"
command -v node >/dev/null 2>&1 || echo "note: node is not installed - 'agentfleet dash' needs it"

# ---------------------------------------------------------------- link target

on_path() { case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }

# Prefer a directory that is ALREADY on PATH. Choosing ~/.local/bin first meant
# the next command in the README - `agentfleet init` - died with "command not
# found" on a stock macOS, where the login PATH is /usr/local/bin:/usr/bin:/bin
# and friends and has no ~/.local/bin. mkdir -p makes the writability test on
# ~/.local/bin always pass, so it can never lose on its own.
DEST=""
USE_SUDO=0
for d in "$HOME/.local/bin" /usr/local/bin "$HOME/bin"; do
  if on_path "$d" && [ -d "$d" ] && [ -w "$d" ]; then DEST="$d"; break; fi
done
if [ -z "$DEST" ]; then
  if mkdir -p "$HOME/.local/bin" 2>/dev/null && [ -w "$HOME/.local/bin" ]; then
    DEST="$HOME/.local/bin"
  elif [ -w /usr/local/bin ]; then
    DEST=/usr/local/bin
  elif command -v sudo >/dev/null 2>&1; then
    DEST=/usr/local/bin
    USE_SUDO=1
    echo "install.sh: ~/.local/bin is not writable, using sudo for /usr/local/bin"
  else
    echo "install.sh: no writable directory found for the link (tried ~/.local/bin and /usr/local/bin)" >&2
    exit 1
  fi
fi

LINK="$DEST/agentfleet"
if [ "$USE_SUDO" = 1 ]; then
  sudo ln -sfn "$SRC" "$LINK"
else
  ln -sfn "$SRC" "$LINK"
fi

echo "installed: $LINK -> $SRC"

# ---------------------------------------------------------------- PATH

# Nothing on this side can change the PATH of the shell that ran us, so the
# quickstart cannot work by printing advice alone: persist the line for future
# shells, and print the one-liner for this one.
if ! on_path "$DEST"; then
  RC=""
  case "${SHELL:-}" in
    */zsh)  RC="$HOME/.zshrc" ;;
    */bash) RC="$HOME/.bashrc" ;;
    *)      [ -f "$HOME/.zshrc" ] && RC="$HOME/.zshrc" || RC="$HOME/.profile" ;;
  esac
  # Idempotent: the marker is what makes re-running install.sh (after a git
  # pull, say) not stack a fifth copy of the same export on the file.
  MARK="# added by agentfleet install.sh"
  # $PATH stays literal on purpose: it is expanded by the shell that later reads
  # the rc file, not by this one.
  # shellcheck disable=SC2016
  LINE="export PATH=\"$DEST:\$PATH\""
  if [ -n "$RC" ] && grep -qF "$MARK" "$RC" 2>/dev/null; then
    echo "PATH: $RC already sets it up"
  elif [ -n "$RC" ] && printf '\n%s\n%s\n' "$MARK" "$LINE" >>"$RC" 2>/dev/null; then
    echo "PATH: added $DEST to $RC (new shells pick it up)"
  else
    echo "PATH: could not write a shell rc file - add $DEST to your PATH yourself" >&2
  fi
  cat <<EOF

For THIS shell, run:
  export PATH="$DEST:\$PATH"
EOF
fi

cat <<'EOF'

Next: agentfleet init
EOF
