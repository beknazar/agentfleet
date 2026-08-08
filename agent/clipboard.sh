#!/usr/bin/env bash
# Optional module: make "copy" inside a remote tmux land on the laptop clipboard.
#
# THE GAP THIS CLOSES: when a TUI copies, it emits an OSC 52 escape. tmux takes
# that into its own buffer, says "copied N chars", and re-emits OSC 52 outward -
# which several common terminals, macOS Terminal among them, simply ignore. Net
# effect: the app says copied, the tmux buffer holds the text, and the laptop
# clipboard still has whatever was in it before. Nothing in the chain is broken
# enough to complain, so you find out by pasting the wrong thing.
#
# Two halves, and you need both:
#
#   on the laptop:  clipboard.sh bridge      a tiny HTTP clipboard endpoint
#   on a machine:   clipboard.sh install     shims + a poller + tmux bindings
#
# `install` runs on the machine (agentfleet copies this file there). It reads
# AF_CLIP_HOST and AF_CLIP_PORT to know where the bridge is.
#
# SECURITY: the bridge has no authentication. Anything that can reach its port
# can read your clipboard, write it, and ask your browser to open a URL. Bind it
# to a private interface - a tailnet address is the intended setup - and never
# to a public one. AF_CLIP_BIND controls that and defaults to the tailnet
# address when there is one.

set -uo pipefail

AF_CLIP_HOST="${AF_CLIP_HOST:-}"
# Left empty here, not defaulted: the bridge has to be able to tell "the
# operator said nothing" from "the operator said 8899" before it consults the
# config file below. Defaulted at the point of use.
AF_CLIP_PORT="${AF_CLIP_PORT:-}"
AF_CLIP_BIND="${AF_CLIP_BIND:-}"
AF_NAME="${AF_NAME:-agentfleet}"
AF_CLIP_PORT_DEFAULT=8899

die() { printf 'clipboard: %s\n' "$*" >&2; exit 1; }

# The bridge is started by hand, so unlike every `agentfleet` subcommand it
# never loaded the operator's config - while the other half of the pair did:
# lib/browser.sh bakes AF_CLIP_PORT from that same config into the pbcopy and
# af-open shims it installs on the machines. Put AF_CLIP_PORT=9000 in the file
# and without this the machines dial 9000 while the bridge listens on 8899,
# both halves configured from one line. Environment still wins over the file.
config_get() {
  local key="$1" cfg
  if [ -n "${AGENTFLEET_CONFIG:-}" ]; then cfg="$AGENTFLEET_CONFIG"
  elif [ -f ./agentfleet.conf ]; then cfg="$PWD/agentfleet.conf"
  else cfg="$HOME/.config/agentfleet/config"
  fi
  [ -f "$cfg" ] || return 0
  # Subshell: the config is a shell file of AF_* assignments and none of the
  # other keys in it belong in this script's namespace.
  ( set +u; . "$cfg" >/dev/null 2>&1 || true; eval "printf '%s' \"\${$key:-}\"" )
}

# ---------------------------------------------------------------- machine side

install_machine() {
  [ -n "$AF_CLIP_HOST" ] || die "set AF_CLIP_HOST to the laptop's hostname or tailnet address"
  # No agentfleet config on a machine - the caller passes the port in the env.
  [ -n "$AF_CLIP_PORT" ] || AF_CLIP_PORT="$AF_CLIP_PORT_DEFAULT"
  local bin="$HOME/.local/bin" frag="$HOME/.config/$AF_NAME/tmux-clipboard.conf"
  mkdir -p "$bin" "$(dirname "$frag")"

  # Named pbcopy/pbpaste on purpose: tools and muscle memory already reach for
  # those names, and on a Linux machine nothing else owns them.
  cat > "$bin/pbcopy" <<EOF
#!/usr/bin/env bash
# pbcopy shim - pipe stdin to the operator's clipboard over the private network.
set -uo pipefail
HOST="\${AF_CLIP_HOST:-$AF_CLIP_HOST}"
PORT="\${AF_CLIP_PORT:-$AF_CLIP_PORT}"
if ! curl -s -m 4 --data-binary @- "http://\${HOST}:\${PORT}/" >/dev/null 2>&1; then
  echo "pbcopy: cannot reach the clipboard bridge at \${HOST}:\${PORT}" >&2
  echo "        (is the laptop reachable, and is the agentfleet clipboard bridge running?)" >&2
  exit 1
fi
EOF

  cat > "$bin/pbpaste" <<EOF
#!/usr/bin/env bash
# pbpaste shim - print the operator's clipboard. See pbcopy for why.
set -uo pipefail
HOST="\${AF_CLIP_HOST:-$AF_CLIP_HOST}"
PORT="\${AF_CLIP_PORT:-$AF_CLIP_PORT}"
curl -s -m 4 "http://\${HOST}:\${PORT}/" \\
  || { echo "pbpaste: bridge unreachable at \${HOST}:\${PORT}" >&2; exit 1; }
EOF

  cat > "$bin/af-clip-bridge" <<'EOF'
#!/usr/bin/env bash
# Poll the tmux buffer and forward anything new to the operator's clipboard.
#
# Polling looks crude, and it is the only reliable interception point: tmux's
# OSC 52 path does not go through the set-buffer command, so `set-hook
# after-set-buffer` never fires for an app's copy (verified - the hook works for
# an explicit `tmux set-buffer` and is silent for OSC 52). Cost is one
# `tmux show-buffer` per second against a local socket.
set -uo pipefail
PB="$HOME/.local/bin/pbcopy"

digest() {
  if command -v sha1sum >/dev/null 2>&1; then sha1sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum | cut -d' ' -f1
  else cksum | cut -d' ' -f1
  fi
}

last=""
while true; do
  if tmux has-session >/dev/null 2>&1; then
    cur="$(tmux show-buffer 2>/dev/null || true)"
    if [ -n "$cur" ]; then
      sig="$(printf '%s' "$cur" | digest)"
      # Only mark it sent if the send worked, so a bridge that is down for a
      # minute does not silently drop the copy you made during that minute.
      if [ "$sig" != "$last" ] && printf '%s' "$cur" | "$PB" 2>/dev/null; then
        last="$sig"
      fi
    fi
  fi
  sleep 1
done
EOF

  chmod 755 "$bin/pbcopy" "$bin/pbpaste" "$bin/af-clip-bridge"

  cat > "$frag" <<EOF
# agentfleet clipboard bindings. Sourced from ~/.tmux.conf.
set -g set-clipboard on

# Mouse OFF on purpose. A full-screen TUI captures mouse events itself, so tmux
# never sees the drag: the selection copies nothing and the laptop clipboard
# keeps its old contents, which reads exactly like a broken clipboard. With
# mouse off, the terminal's own selection works again and copy behaves normally.
# For text inside a TUI use copy-mode: prefix + [ , move, Space, select, y.
set -g mouse off

setw -g mode-keys vi
bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-no-clear "$bin/pbcopy"
bind -T copy-mode-vi y                 send -X copy-pipe-and-cancel "$bin/pbcopy"
bind -T copy-mode-vi Enter             send -X copy-pipe-and-cancel "$bin/pbcopy"

# prefix + p pastes the LAPTOP clipboard into the pane.
bind p run "tmux set-buffer -- \"\$($bin/pbpaste)\"; tmux paste-buffer"

# Covers an explicit \`tmux set-buffer\`. An app's OSC 52 copy does not fire this
# hook - that is what af-clip-bridge is for.
set-hook -g after-set-buffer 'run-shell "tmux save-buffer - | $bin/pbcopy"'
EOF

  touch "$HOME/.tmux.conf"
  if ! grep -q "tmux-clipboard.conf" "$HOME/.tmux.conf" 2>/dev/null; then
    printf 'source-file -q %s\n' "$frag" >> "$HOME/.tmux.conf"
  fi
  tmux source-file "$HOME/.tmux.conf" >/dev/null 2>&1 || true

  install_service "$bin"

  printf 'clipboard: installed. bridge target %s:%s\n' "$AF_CLIP_HOST" "$AF_CLIP_PORT"
  printf 'clipboard: check it with:  echo hello | pbcopy\n'
}

install_service() {
  local bin="$1" unit="$HOME/.config/systemd/user/$AF_NAME-clipboard.service"
  if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
    printf 'clipboard: no systemd --user here. Start the poller yourself:\n  nohup %s/af-clip-bridge >/dev/null 2>&1 &\n' "$bin" >&2
    return 0
  fi
  mkdir -p "$(dirname "$unit")"
  # Lingering, so the poller is back after the machine is stopped and started
  # again. Without it the clipboard quietly stops working on a resumed machine.
  sudo -n loginctl enable-linger "$USER" >/dev/null 2>&1 \
    || printf 'clipboard: could not enable-linger; the poller stops when you log out\n' >&2
  cat > "$unit" <<EOF
[Unit]
Description=agentfleet clipboard bridge (tmux buffer -> operator clipboard)

[Service]
Environment=AF_CLIP_HOST=$AF_CLIP_HOST
Environment=AF_CLIP_PORT=$AF_CLIP_PORT
ExecStart=$bin/af-clip-bridge
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable "$AF_NAME-clipboard" >/dev/null 2>&1 || true
  systemctl --user restart "$AF_NAME-clipboard" \
    || die "the clipboard service failed to start (journalctl --user -u $AF_NAME-clipboard)"
}

# ---------------------------------------------------------------- laptop side

# Resolve the platform's clipboard and URL-opener commands once, and refuse to
# start without them rather than serving an endpoint that answers 200 and does
# nothing.
detect_laptop_tools() {
  # Running the bridge on a machine that already has the shims would have it
  # forward the clipboard to itself, forever.
  case "$(command -v pbcopy 2>/dev/null)" in
    "$HOME/.local/bin/pbcopy") die "this machine has the clipboard shims installed - the bridge belongs on your laptop" ;;
  esac
  if command -v pbcopy >/dev/null 2>&1; then
    CLIP_COPY="pbcopy"; CLIP_PASTE="pbpaste"
  elif command -v wl-copy >/dev/null 2>&1; then
    CLIP_COPY="wl-copy"; CLIP_PASTE="wl-paste --no-newline"
  elif command -v xclip >/dev/null 2>&1; then
    CLIP_COPY="xclip -selection clipboard"; CLIP_PASTE="xclip -selection clipboard -o"
  else
    die "no clipboard tool found (pbcopy, wl-copy or xclip)"
  fi
  if command -v open >/dev/null 2>&1; then CLIP_OPEN="open"
  elif command -v xdg-open >/dev/null 2>&1; then CLIP_OPEN="xdg-open"
  else CLIP_OPEN=""
  fi
}

# Default to the tailnet address. Binding a no-auth clipboard to 0.0.0.0 on a
# laptop that joins cafe wifi is a different thing entirely, so that has to be
# something you type on purpose.
detect_bind() {
  [ -n "$AF_CLIP_BIND" ] && { printf '%s' "$AF_CLIP_BIND"; return 0; }
  local ts=""
  if command -v tailscale >/dev/null 2>&1; then ts="$(command -v tailscale)"
  elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  fi
  if [ -n "$ts" ]; then
    local ip; ip="$("$ts" ip -4 2>/dev/null | head -1)"
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
  fi
  return 1
}

run_bridge() {
  command -v python3 >/dev/null 2>&1 || die "the bridge needs python3"
  detect_laptop_tools
  [ -n "$AF_CLIP_PORT" ] || AF_CLIP_PORT="$(config_get AF_CLIP_PORT)"
  [ -n "$AF_CLIP_PORT" ] || AF_CLIP_PORT="$AF_CLIP_PORT_DEFAULT"
  [ -n "$AF_CLIP_BIND" ] || AF_CLIP_BIND="$(config_get AF_CLIP_BIND)"
  # Caught here rather than as a python traceback three lines later.
  case "$AF_CLIP_PORT" in
    *[!0-9]*) die "AF_CLIP_PORT is not a number: $AF_CLIP_PORT" ;;
  esac
  local bind
  bind="$(detect_bind)" || die "no tailnet address found - set AF_CLIP_BIND explicitly (127.0.0.1 to test)"

  printf 'clipboard: bridge on %s:%s - no authentication, anything that reaches this port\n' "$bind" "$AF_CLIP_PORT" >&2
  printf 'clipboard: can read and write your clipboard and open URLs in your browser.\n' >&2

  # The server source goes to python3 on stdin, never through a file. It used to
  # be written to ${TMPDIR:-/tmp}/af-clip-bridge.py, which on Linux is a fixed
  # name in a world-writable directory: another local account can pre-create it
  # (or symlink it at one of your files), and because this script has no `set -e`
  # a refused write just prints "Permission denied" and then execs whatever was
  # already sitting there - code execution as the operator holding the fleet ssh
  # key. bash's own heredoc temp file is created safely and unlinked, so there is
  # nothing left on disk to swap under us.
  AF_CLIP_BIND="$bind" AF_CLIP_PORT="$AF_CLIP_PORT" \
  AF_CLIP_COPY="$CLIP_COPY" AF_CLIP_PASTE="$CLIP_PASTE" AF_CLIP_OPEN="$CLIP_OPEN" \
    exec python3 - <<'PY'
import os
import shlex
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

COPY = shlex.split(os.environ["AF_CLIP_COPY"])
PASTE = shlex.split(os.environ["AF_CLIP_PASTE"])
OPEN = shlex.split(os.environ.get("AF_CLIP_OPEN", ""))
MAX_BODY = 4 * 1024 * 1024


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        raw = body if isinstance(body, bytes) else body.encode("utf-8", "replace")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/open":
            url = (parse_qs(parsed.query).get("url") or [""])[0]
            # Only real web URLs. file:// and javascript: would turn a clipboard
            # endpoint into local code execution on the operator's laptop.
            if not url.startswith(("http://", "https://")):
                return self.reply(400, "only http and https URLs\n")
            if not OPEN:
                return self.reply(501, "no URL opener on this machine\n")
            subprocess.run(OPEN + [url], check=False)
            return self.reply(200, "opened\n")
        if parsed.path == "/":
            return self.reply(200, subprocess.run(PASTE, capture_output=True).stdout)
        self.reply(404, "not found\n")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            return self.reply(413, "too large\n")
        subprocess.run(COPY, input=self.rfile.read(length), check=False)
        self.reply(200, "copied\n")

    def log_message(self, fmt, *args):
        sys.stderr.write("clip %s - %s\n" % (self.address_string(), fmt % args))


HTTPServer((os.environ["AF_CLIP_BIND"], int(os.environ["AF_CLIP_PORT"])), Handler).serve_forever()
PY
}

case "${1:-}" in
  install) install_machine ;;
  bridge)  run_bridge ;;
  *)
    sed -n '2,25p' "$0"
    exit 1 ;;
esac
