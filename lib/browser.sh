#!/usr/bin/env bash
# Optional module: a watchable browser on the machines, a file inbox, and
# browser-assisted login. Nothing in the core path sources this file - skip it
# entirely and agentfleet still provisions, syncs and reports.
#
#   agentfleet browser <host|all>        Xvfb + Chromium/CDP + x11vnc + noVNC
#   agentfleet drop <file> [host|all]    copy a file into the machines' inbox
#   agentfleet login <host> <command>    finish an OAuth flow that starts remotely
#
# Three browsers, on purpose. A machine's Chromium is a fresh datacenter profile
# with no cookies, so every sign-in wall stops it dead, and an OAuth prompt in a
# browser nobody can see is a dead end ("waiting for the browser to open...").
# Logging in from a datacenter IP also invites 2FA challenges and has to be
# redone on every machine. So:
#
#   the machine's Chromium    default: throwaway, parallel, unauthenticated work
#   the operator's browser    every login/OAuth/2FA, via `agentfleet login`
#   the laptop's CDP profile  opt-in tunnel, for automation against real
#                             sessions (AF_MAC_CHROME, off by default - read the
#                             warning on af_mac_chrome below before enabling it)
#
# Collapsing those three into one is how agents end up parked at a sign-in wall.

# Defaults for the optional AF_* keys. Set here rather than in common.sh so a
# config that never mentions the browser still loads under `set -u`.
af_browser_defaults() {
  : "${AF_CDP_PORT:=9222}"
  : "${AF_NOVNC_PORT:=6080}"
  : "${AF_VNC_BIND:=}"
  : "${AF_DROP_SRC:=$HOME/Screenshots}"
  : "${AF_CLIP_HOST:=}"
  : "${AF_CLIP_PORT:=8899}"
  : "${AF_MAC_CHROME:=0}"
  : "${AF_MAC_CHROME_PORT:=9223}"
  : "${AF_MAC_CHROME_LOCAL_PORT:=9333}"
  : "${AF_MAC_CHROME_ORIGINS:=}"
  : "${AF_CHROME_BIN:=}"
}

# Xvfb geometry for the machine's browser. A constant, not a setting: noVNC
# scales the desktop to whatever window you open it in.
AF_BROWSER_SCREEN=1600x1000x24

# ---------------------------------------------------------------- tunnels
#
# ssh control sockets, not `pkill -f "ssh .*-L 5000:..."`. The pattern match was
# matching on command-line text: it broke whenever an ssh option moved and it
# could hit an unrelated ssh whose arguments happened to end the same way.
# `ssh -O exit -S <socket>` closes exactly the tunnel we opened and nothing else.
af_tun_sock() {
  mkdir -p "$AF_CACHE/tunnels"
  printf '%s/tunnels/%s-%s-%s.sock' "$AF_CACHE" "$1" "$2" "$3"
}

af_tun_close() {
  local sock="$1"
  [ -e "$sock" ] || return 0
  ssh -O exit -S "$sock" agentfleet-tunnel >/dev/null 2>&1 || true
  rm -f "$sock"
}

# Is anything accepting connections on a local port? Used to prove a tunnel is
# live before anything depends on it. nc when present, bash's /dev/tcp otherwise.
af_port_open() {
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$1" >/dev/null 2>&1
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1
  fi
}

# ---------------------------------------------------------------- browser

af_browser_usage() {
  cat <<'EOF'
agentfleet browser <host|all>          start the browser stack on the machine(s)
agentfleet browser mac-chrome start    launch the laptop's dedicated CDP browser
agentfleet browser mac-chrome up|down|status [host|all]

The stack is Xvfb, Chromium with CDP on AF_CDP_PORT, x11vnc and noVNC. Agents
drive it over CDP; you watch and take over at http://<host>:<AF_NOVNC_PORT>/vnc.html

That browser is a fresh datacenter profile with no cookies, so it cannot get
through a sign-in wall. To finish a login or an OAuth flow, use your own
browser: agentfleet login <host> <command...>
EOF
}

cmd_browser() {
  af_browser_defaults
  case "${1:-}" in
    ""|-h|--help) af_browser_usage; return 0 ;;
    mac-chrome)   shift; af_mac_chrome "$@"; return $? ;;
  esac
  local host
  for host in $(af_expand_hosts "$@"); do
    af_browser_start "$host"
  done
}

af_browser_start() {
  local host="$1" bin="$AF_HOME/.local/bin"
  local unit="$AF_HOME/.config/systemd/user/$AF_NAME-browser.service"

  af_ssh "$host" "mkdir -p '$bin' '$AF_HOME/.config/systemd/user'" \
    || af_die "$host: unreachable"

  # af-open is this module's alone, so it is always refreshed.
  af_browser_open_script | af_put_text "$host" "$bin/af-open" 755

  if af_ssh "$host" "test -f '$unit'"; then
    # Provisioning already owns this unit (AF_BROWSER=1). Rewriting it here
    # would start a tug of war where each side undoes the other on its next
    # run, so this command becomes "start or repair it now" and nothing else.
    #
    # Repair has to include the missing browser. The provisioned stack
    # (agent/services.sh) finds Chrome only through the playwright glob, and
    # agent/bootstrap.sh downgrades a failed chromium download to a WARN that
    # still provisions green - so the machine this command exists to fix is
    # exactly the one with nothing to launch. Without the retry below, a restart
    # only feeds Restart=always a stack that prints "no chromium" and exits, and
    # af_browser_verify dies thirty seconds later.
    # shellcheck disable=SC2016  # $HOME and the glob belong to the machine
    if ! af_ssh "$host" 'ls "$HOME"/.cache/ms-playwright/chromium-*/chrome-linux*/chrome >/dev/null 2>&1'; then
      af_log "[browser] $host: the provisioned stack has no chromium - downloading it (a minute or two)"
      af_ssh "$host" 'command -v playwright >/dev/null 2>&1 && playwright install chromium \
        || { command -v npx >/dev/null 2>&1 && npx --yes playwright install chromium; }' \
        >/dev/null 2>&1 \
        || af_warn "$host: the chromium download failed - fix it there ('playwright install chromium'), the restart below will not have a browser to launch"
    fi
    af_log "[browser] $host: restarting the provisioned browser unit"
    af_ssh "$host" "systemctl --user reset-failed '$AF_NAME-browser' >/dev/null 2>&1; \
      systemctl --user restart '$AF_NAME-browser'" \
      || af_die "$host: the browser unit would not start (journalctl --user -u $AF_NAME-browser)"
  else
    af_browser_stack_script | af_put_text "$host" "$bin/$AF_NAME-browser-stack" 755
    { af_browser_env; af_browser_launch_script; } | af_ssh "$host" "bash -s" \
      || af_die "$host: could not start the browser stack"
  fi

  af_browser_verify "$host"

  af_log "[browser] $host: watch and take over -> http://$host:$AF_NOVNC_PORT/vnc.html"
  af_log "[browser] $host: agents open pages with: af-open <url>   (CDP on :$AF_CDP_PORT)"
  af_log "[browser] $host: the noVNC endpoint has NO password. Keep these machines"
  af_log "[browser] $host: off the public internet (that is what AF_TAILNET is for)."
}

# Config the launch script needs, as an env prelude, so it can be written
# verbatim with no local expansion and no escaping games.
af_browser_env() {
  printf "export AF_CDP_PORT='%s' AF_NOVNC_PORT='%s' AF_VNC_BIND='%s'\n" \
    "$AF_CDP_PORT" "$AF_NOVNC_PORT" "$AF_VNC_BIND"
  printf "export AF_BROWSER_SCREEN='%s' AF_NAME='%s'\n" "$AF_BROWSER_SCREEN" "$AF_NAME"
}

af_browser_launch_script() {
  cat <<'REMOTE'
set -uo pipefail
BIN="$HOME/.local/bin"
UNIT="$HOME/.config/systemd/user/${AF_NAME}-browser.service"

if ! command -v Xvfb >/dev/null 2>&1 || ! command -v x11vnc >/dev/null 2>&1 \
   || ! command -v websockify >/dev/null 2>&1; then
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "browser stack needs Xvfb, x11vnc, websockify and noVNC; install them and re-run" >&2
    exit 1
  fi
  sudo -n true >/dev/null 2>&1 || echo "installing packages needs sudo on this machine" >&2
  if ! sudo apt-get update -qq \
     || ! sudo apt-get install -y -qq xvfb x11vnc novnc websockify fonts-liberation >/dev/null; then
    echo "package install failed" >&2
    exit 1
  fi
fi

# Stopping a cloud machine to save money and starting it again loses everything
# that was running in a tmux session, so a resumed machine used to come back
# looking healthy with no browser on it. A supervised user unit with lingering
# enabled brings the stack back by itself.
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  sudo -n loginctl enable-linger "$USER" >/dev/null 2>&1 \
    || echo "could not enable-linger: the stack will stop when you log out" >&2
  cat > "$UNIT" <<UNITEOF
[Unit]
Description=agentfleet browser stack (Xvfb + Chromium/CDP + x11vnc + noVNC)

[Service]
Environment=AF_CDP_PORT=$AF_CDP_PORT
Environment=AF_NOVNC_PORT=$AF_NOVNC_PORT
Environment=AF_VNC_BIND=$AF_VNC_BIND
Environment=AF_BROWSER_SCREEN=$AF_BROWSER_SCREEN
Environment=AF_NAME=$AF_NAME
ExecStart=$BIN/${AF_NAME}-browser-stack
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNITEOF
  systemctl --user daemon-reload
  systemctl --user reset-failed "${AF_NAME}-browser" >/dev/null 2>&1 || true
  systemctl --user enable "${AF_NAME}-browser" >/dev/null 2>&1 || true
  systemctl --user restart "${AF_NAME}-browser" || { echo "unit failed to start" >&2; exit 1; }
else
  echo "no systemd --user here: starting unsupervised, it will not survive a reboot" >&2
  pkill -f "${AF_NAME}-browser-stack" >/dev/null 2>&1 || true
  nohup "$BIN/${AF_NAME}-browser-stack" >"/tmp/${AF_NAME}-browser-stack.log" 2>&1 &
fi
REMOTE
}

af_browser_stack_script() {
  cat <<'REMOTE'
#!/usr/bin/env bash
# Xvfb -> Chromium (CDP) -> x11vnc -> noVNC, as one process group so the
# supervisor can restart the whole thing. Written by `agentfleet browser`.
set -uo pipefail
CDP_PORT="${AF_CDP_PORT:-9222}"
VNC_PORT="${AF_NOVNC_PORT:-6080}"
SCREEN="${AF_BROWSER_SCREEN:-1600x1000x24}"

# The VNC desktop has no password, and it is a full interactive session on the
# machine: whoever opens it can read the ssh keys and the pushed credentials and
# open a writable shell. So a wildcard bind is REFUSED here, not merely
# discouraged in the docs. A tailnet adds an interface, it does not remove the
# public one, and the ssh/BYO provider ships no host firewall. Same resolution
# as agent/services.sh, deliberately: these are two writers of one stack script
# and they must not disagree about who can reach it.
# Set AF_VNC_BIND to a SPECIFIC address to serve somewhere else on purpose.
VNC_WILDCARD=""
VNC_BIND=""
case "${AF_VNC_BIND:-}" in
  '') ;;
  '0.0.0.0'|'::'|'*'|'[::]') VNC_WILDCARD="$AF_VNC_BIND" ;;
  *) VNC_BIND="$AF_VNC_BIND" ;;
esac
if [ -z "$VNC_BIND" ]; then
  VNC_ADDR=""
  if ip link show tailscale0 >/dev/null 2>&1; then
    VNC_ADDR="$(ip -4 -o addr show tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  fi
  VNC_BIND="${VNC_ADDR:-127.0.0.1}"
fi
[ -n "$VNC_WILDCARD" ] && echo "noVNC: ignoring AF_VNC_BIND=$VNC_WILDCARD (no password on that desktop); using $VNC_BIND" >&2
DISP="${AF_BROWSER_DISPLAY:-:99}"
# Same profile directory agent/services.sh gives the provisioned stack. They are
# two writers of one stack script, and a machine that flips AF_BROWSER from 0 to
# 1 would otherwise come back with a different profile and none of the sessions
# you had signed into.
PROFILE="$HOME/.${AF_NAME:-agentfleet}-chrome"

find_chrome() {
  local c
  for c in "$HOME"/.cache/ms-playwright/chromium-*/chrome-linux*/chrome; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  for c in chromium chromium-browser google-chrome google-chrome-stable; do
    command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return 0; }
  done
  return 1
}

CHROME="$(find_chrome)" || {
  # Try once, then give up loudly. Under a supervisor a hard exit here would
  # spin; the sleep keeps a broken machine from hammering itself.
  if command -v npx >/dev/null 2>&1; then npx --yes playwright install chromium >/dev/null 2>&1 || true; fi
  CHROME="$(find_chrome)" || { echo "no chromium on this machine" >&2; sleep 15; exit 1; }
}

NOVNC=""
for d in /usr/share/novnc /usr/share/webapps/novnc /usr/local/share/novnc; do
  [ -d "$d" ] && { NOVNC="$d"; break; }
done
[ -n "$NOVNC" ] || { echo "noVNC web root not found" >&2; sleep 15; exit 1; }

# One display, one browser. Leftovers from a previous run hold the X lock and
# the CDP port, and the new stack dies on startup while looking like it started.
pkill -x Xvfb >/dev/null 2>&1 || true
pkill -x x11vnc >/dev/null 2>&1 || true
sleep 1

Xvfb "$DISP" -screen 0 "$SCREEN" &
sleep 2

# --no-sandbox is a real constraint here, not laziness: Chromium's sandbox needs
# unprivileged user namespaces, which the default AppArmor policy on current
# Ubuntu denies, and without the flag the browser exits immediately. It is
# acceptable on a single-tenant machine that already runs an agent with a shell,
# and nowhere else.
DISPLAY="$DISP" "$CHROME" --no-sandbox --no-first-run --no-default-browser-check \
  --remote-debugging-port="$CDP_PORT" --user-data-dir="$PROFILE" about:blank &
sleep 2

# -localhost: x11vnc has no password (-nopw) because noVNC in front of it is the
# intended door. Binding it to loopback keeps the raw, unauthenticated VNC port
# off every other interface.
x11vnc -display "$DISP" -localhost -forever -shared -nopw -quiet &

exec websockify --web "$NOVNC" "${VNC_BIND}:${VNC_PORT}" localhost:5900
REMOTE
}

# Validate the RESPONSE BODY, never curl's exit code. A browser that is up but
# refusing debug connections still answers, with a 404 page, and an
# exit-code-only check reads that as healthy. That is how a whole fleet of dead
# endpoints once reported green while serving nothing.
af_browser_verify() {
  local host="$1" i out=""
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    out="$(af_ssh "$host" "curl -s -m 3 http://127.0.0.1:$AF_CDP_PORT/json/version" 2>/dev/null || true)"
    case "$out" in *'"Browser"'*) break ;; esac
    out=""
    sleep 2
  done
  [ -n "$out" ] || af_die "$host: CDP never came up on :$AF_CDP_PORT (logs: journalctl --user -u $AF_NAME-browser)"
  af_log "[browser] $host: $(printf '%s' "$out" | sed -n 's/.*"Browser": *"\([^"]*\)".*/\1/p')"
}

# The URL opener installed on each machine. Agents call `af-open <url>`; symlink
# it as xdg-open yourself if you want the system opener to route here too.
af_browser_open_script() {
  cat <<'HEAD'
#!/usr/bin/env bash
# af-open - open a URL from this machine. Written by `agentfleet browser`.
set -uo pipefail

usage() {
  cat <<'USAGE'
af-open <url>       this machine's own Chromium. Right for agent work; nobody
                    is watching it unless you open the noVNC view.
af-open -l <url>    the operator's real browser, with their sessions. The only
                    path that can finish a login, an OAuth flow or 2FA.
af-open -m <url>    the laptop's CDP browser over the reverse tunnel, for
                    automation that needs those logged-in sessions.
USAGE
}
HEAD
  cat <<EOF
CDP_PORT="\${AF_CDP_PORT:-$AF_CDP_PORT}"
MAC_PORT="\${AF_MAC_CHROME_PORT:-$AF_MAC_CHROME_PORT}"
CLIP_HOST="\${AF_CLIP_HOST:-$AF_CLIP_HOST}"
CLIP_PORT="\${AF_CLIP_PORT:-$AF_CLIP_PORT}"
VNC_PORT="\${AF_NOVNC_PORT:-$AF_NOVNC_PORT}"
EOF
  cat <<'REMOTE'

MODE=vm
case "${1:-}" in
  -l|--local)  MODE=local; shift ;;
  -m|--mac)    MODE=mac;   shift ;;
  -h|--help)   usage; exit 0 ;;
esac
url="${1:-about:blank}"

# Byte-wise percent encoding, so this needs no python and no jq on the machine.
# LC_ALL=C makes the substring walk step one BYTE at a time, and the mask undoes
# printf's sign extension - without it a non-ASCII byte encodes as %FFFFFFC3.
urlencode() {
  local LC_ALL=C s="$1" i c n out=""
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out="$out$c" ;;
      *) n="$(printf '%d' "'$c")"; out="$out$(printf '%%%02X' "$((n & 0xFF))")" ;;
    esac
  done
  printf '%s' "$out"
}

# Chrome changed /json/new to require PUT; older builds only accept GET. Send
# both rather than picking one and breaking against half the browser versions
# in the fleet.
cdp_open() {
  local port="$1" enc; enc="$(urlencode "$2")"
  curl -s -m 5 -X PUT "http://127.0.0.1:$port/json/new?$enc" >/dev/null 2>&1 && return 0
  curl -s -m 5 "http://127.0.0.1:$port/json/new?$enc" >/dev/null 2>&1
}

# A dead browser must never look like a successful open: an agent that gets a
# silent success will carry on and report work it never did. Probe first, and
# on failure print the URL (the human's manual fallback) plus the exact command
# that fixes it, and exit non-zero.
cdp_alive() {
  curl -s -m 3 "http://127.0.0.1:$1/json/version" 2>/dev/null | grep -q '"Browser"'
}

fail() { printf '%s\n' "$@" >&2; printf 'URL: %s\n' "$url" >&2; exit 1; }

case "$MODE" in
  local)
    [ -n "$CLIP_HOST" ] \
      || fail "af-open: no operator bridge configured (set AF_CLIP_HOST and start the agentfleet clipboard bridge on your laptop)"
    curl -s -m 6 "http://${CLIP_HOST}:${CLIP_PORT}/open?url=$(urlencode "$url")" | grep -q opened \
      || fail "af-open: cannot reach the operator bridge at ${CLIP_HOST}:${CLIP_PORT}" \
              "         (is the laptop on the same private network, and is the bridge running?)"
    echo "opened in the operator's browser: $url" ;;
  mac)
    cdp_alive "$MAC_PORT" && cdp_open "$MAC_PORT" "$url" \
      || fail "af-open: no tunnel to the laptop browser on :$MAC_PORT" \
              "         run on the laptop: agentfleet browser mac-chrome up $(hostname)"
    echo "opened in the laptop's CDP browser: $url" ;;
  vm)
    cdp_alive "$CDP_PORT" && cdp_open "$CDP_PORT" "$url" \
      || fail "af-open: no Chromium on $(hostname)" \
              "         run on the laptop: agentfleet browser $(hostname)"
    echo "opened in this machine's Chromium: $url"
    echo "  watch/click: http://$(hostname):$VNC_PORT/vnc.html"
    echo "  needs your login? re-run: af-open --local '$url'" ;;
esac
REMOTE
}

# ---------------------------------------------------------------- drop

cmd_drop() {
  af_browser_defaults
  local src="" targets="" host base remote
  # The inbox on each machine. Under $AF_HOME so it follows path mirroring, and
  # fixed so the path `drop` prints is the same on every machine.
  local dropdir="$AF_HOME/drop"

  case "${1:-}" in
    -h|--help)
      cat <<'EOF'
agentfleet drop                  newest file in AF_DROP_SRC -> every machine
agentfleet drop <file>           that file -> every machine
agentfleet drop <file> <host>    that file -> one machine
agentfleet drop -c               the clipboard image -> every machine

A path you paste into a remote agent session points at the LAPTOP's filesystem,
so the agent cannot read it. This copies the file into ~/drop on each machine
and prints - and copies - the path that does work there.
EOF
      return 0 ;;
    -c|--clipboard)
      shift
      command -v pngpaste >/dev/null 2>&1 || af_die "-c needs pngpaste (brew install pngpaste)"
      src="/tmp/agentfleet-clip-$(date +%s).png"
      pngpaste "$src" || af_die "no image in the clipboard" ;;
  esac

  if [ -z "$src" ]; then
    if [ -n "${1:-}" ] && [ -e "$1" ]; then
      src="$1"; shift
    else
      # No file given: take the newest one from the screenshot folder. This is
      # the "I have a screenshot of the error" path and it should stay one word.
      # ls -t rather than find, because BSD find has no -printf to sort on.
      # shellcheck disable=SC2012
      src="$(ls -t "$AF_DROP_SRC"/* 2>/dev/null | head -1 || true)"
      [ -n "$src" ] || af_die "nothing in $AF_DROP_SRC - take a screenshot first, or pass a path"
    fi
  fi

  targets="${1:-all}"
  # Spaces in the name survive the copy but break every paste of the path.
  base="$(basename "$src" | tr ' ' '_')"
  remote="$dropdir/$base"

  for host in $(af_expand_hosts "$targets"); do
    af_ssh "$host" "mkdir -p '$dropdir'" || af_die "$host: unreachable"
    af_scp "$host" "$src" "$remote" >/dev/null || af_die "$host: copy failed"
    printf '%-10s %s\n' "$host" "$remote"
  done

  if af_clip_put "$remote"; then
    af_log "(path copied to your clipboard - paste it into the agent session)"
  fi
}

af_clip_put() {
  if command -v pbcopy >/dev/null 2>&1; then printf '%s' "$1" | pbcopy; return $?; fi
  if command -v wl-copy >/dev/null 2>&1; then printf '%s' "$1" | wl-copy; return $?; fi
  if command -v xclip  >/dev/null 2>&1; then printf '%s' "$1" | xclip -selection clipboard; return $?; fi
  return 1
}

# ---------------------------------------------------------------- login
#
# The flow: start the login command on the machine, read the auth URL out of its
# terminal, forward the callback port back to the machine, prove the forward
# works, and only then open the tab in the operator's browser.

cmd_login() {
  af_browser_defaults
  case "${1:-}" in
    -h|--help)
      cat <<'EOF'
agentfleet login <host> <command...>

Runs the login command on the machine, reads the auth URL out of its terminal,
forwards the callback port back there, and opens the tab in YOUR browser - the
one with your sessions and your 2FA. A machine's own Chromium cannot finish an
OAuth flow: fresh datacenter profile, no cookies, and nobody watching it.

  agentfleet login w1 claude              authenticate the agent CLI
  agentfleet login w1 claude mcp login notion
EOF
      return 0 ;;
  esac
  local host="${1:-}"
  [ -n "$host" ] || af_die "usage: agentfleet login <host> <command...>   (e.g. agentfleet login w1 claude mcp login notion)"
  shift
  [ $# -gt 0 ] || af_die "usage: agentfleet login <host> <command...>   - the login command to run on the machine"

  local sess="aflogin" log="/tmp/aflogin.log" i url port

  # The $HOME and $PATH below belong to the machine, so they must reach it
  # unexpanded.
  # shellcheck disable=SC2016
  { printf '#!/usr/bin/env bash\n'
    printf 'export PATH="$HOME/.local/bin:$HOME/.bun/bin:/usr/local/bin:$PATH"\n'
    printf 'cd %s 2>/dev/null || true\n' "'$AF_WORKDIR'"
    printf '%s\n' "$*"
  } | af_put_text "$host" /tmp/af-login-cmd.sh 700

  af_ssh "$host" "command -v tmux >/dev/null" || af_die "$host: unreachable, or tmux is not installed"
  af_ssh "$host" "tmux kill-session -t $sess 2>/dev/null; rm -f $log; \
    tmux new-session -d -s $sess 'bash /tmp/af-login-cmd.sh 2>&1 | tee $log'" \
    || af_die "$host: could not start the login command"

  url=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 3
    url="$(af_login_url "$host" "$sess")"
    [ -n "$url" ] && break
  done
  [ -n "$url" ] || af_die "no auth URL appeared. Last line: $(af_ssh "$host" "tail -1 $log" 2>/dev/null || true)"

  port="$(printf '%s' "$url" | grep -oE '(localhost|127\.0\.0\.1)(%3[Aa]|:)[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)"
  if [ -n "$port" ]; then
    af_login_tunnel "$host" "$port"
  else
    af_warn "no callback port in the URL - if the browser callback fails, the login needs a tunnel this could not infer"
  fi

  # Print it unconditionally. If the tab opens somewhere unexpected, or not at
  # all, the operator still has the one thing they need.
  printf '%s\n' "$url"

  # The machine chose that URL. It came off a terminal on a box that runs an
  # agent with a shell and a web browser, so opening it unprompted lets a
  # compromised or prompt-injected machine point the operator's most privileged
  # browser - the one holding every session they are signed into - anywhere it
  # likes. The scheme filter in af_login_url keeps it to https, which bounds
  # this to phishing rather than code execution, but the destination still has
  # to be named and agreed to. AF_YES=1 keeps the old unattended behaviour.
  local urlhost
  urlhost="$(printf '%s' "$url" | sed -e 's|^https://||' -e 's|[/?#].*$||')"
  if af_confirm "[login] open $urlhost in your browser?"; then
    af_open_operator_browser "$url" || af_log "[login] open the URL above in your browser"
  else
    af_log "[login] not opened - use the URL above if you want to continue"
  fi
  af_log "[login] approve it; waiting up to 3 minutes"

  local rc
  for i in $(seq 1 90); do
    # Only tmux's own "no such session" (1) means the login command exited. An
    # ssh failure is 255, and reading that as "finished" would report a login
    # that never happened.
    rc=0; af_ssh "$host" "tmux has-session -t $sess >/dev/null 2>&1" || rc=$?
    if [ "$rc" = 1 ]; then
      af_log "[login] $host: the command finished. Last line: $(af_ssh "$host" "tail -1 $log" 2>/dev/null || true)"
      return 0
    fi
    if af_ssh "$host" "grep -qiE 'authenticated|login succe|logged in' $log 2>/dev/null"; then
      af_ssh "$host" "tmux kill-session -t $sess 2>/dev/null" || true
      af_log "[login] $host: authenticated"
      return 0
    fi
    sleep 2
  done
  af_warn "$host: still pending. Attach with: agentfleet attach $host $sess"
  return 1
}

# The terminal is the only place the URL appears in a usable form. Rendered pane
# text glues OSC 8 hyperlinks together, so the same URL shows up twice back to
# back with the next word stuck on the end; awk cuts just before the second
# "https://" (the URL starts at offset 9 of the doubled string, hence i + 7).
# The raw log copy is not a substitute - it carries escape sequences that some
# providers reject.
af_login_url() {
  af_ssh "$1" "tmux capture-pane -p -J -t $2" 2>/dev/null \
    | tr -d '\n' \
    | grep -oE 'https://[^ ]+' \
    | head -1 \
    | awk '{ i = index(substr($0, 9), "https://"); print (i ? substr($0, 1, i + 7) : $0) }' \
    | sed 's/Waiting.*$//' \
    || true
}

AF_LOGIN_SOCK=""
af_login_cleanup() {
  # The callback port is one-shot. A forward left open here is exactly what
  # steals the next login on a different machine, so it goes away with us.
  af_tun_close "$AF_LOGIN_SOCK"
  return 0
}

af_login_tunnel() {
  local host="$1" port="$2" sock other i
  sock="$(af_tun_sock L "$port" "$host")"

  # Agent CLIs reuse the same callback port per service, so a forward left over
  # from a DIFFERENT machine silently answers this login's callback. Close every
  # forward we know about on this port before opening ours.
  for other in "$AF_CACHE"/tunnels/L-"$port"-*.sock; do
    [ -e "$other" ] || continue
    af_tun_close "$other"
  done
  sleep 1

  # Anything still holding the port is not ours and we cannot safely kill it.
  # Stop here rather than opening a tab whose callback lands somewhere else.
  if af_port_open "$port"; then
    af_die "something is already listening on 127.0.0.1:$port - close it, then re-run"
  fi

  trap af_login_cleanup EXIT INT TERM
  AF_LOGIN_SOCK="$sock"
  local addr; addr="$(af_host_addr "$host")" || af_die "cannot resolve host: $host"
  # ExitOnForwardFailure: without it ssh backgrounds happily even when the
  # forward could not be set up, and every later step reports success.
  ssh "${AF_SSH_OPTS[@]}" -o ExitOnForwardFailure=yes -M -S "$sock" -f -N \
    -L "${port}:localhost:${port}" "$AF_USER@$addr" \
    || af_die "could not open the callback tunnel on $port"

  # Prove the forward accepts a connection BEFORE handing over a browser tab. A
  # dead tunnel shows up as a connection reset on the callback, which burns the
  # one-time code and leaves the machine waiting until it times out.
  for i in 1 2 3 4 5 6 7 8; do
    af_port_open "$port" && break
    sleep 1
  done
  af_port_open "$port" || af_die "the callback tunnel on $port never came up - not opening the browser"
  af_log "[login] callback tunnel 127.0.0.1:$port -> $host verified"
}

af_open_operator_browser() {
  if command -v open >/dev/null 2>&1; then open "$1" >/dev/null 2>&1 && return 0; fi
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1 && return 0; fi
  return 1
}

# ---------------------------------------------------------------- mac-chrome
#
# READ THIS BEFORE ENABLING IT.
#
# This reverse-tunnels a DevTools port from the laptop onto a machine. Whatever
# runs on that machine - your agent, anything your agent runs, anyone with a
# shell there - can then drive that browser: read and write its cookies, open
# any page as you, and act with your identity on every site that browser is
# logged into. It is off unless AF_MAC_CHROME=1.
#
# What keeps it bounded: the tunnel is initiated FROM the laptop (no sshd or
# open port on the laptop at all) and, with GatewayPorts left at its default,
# lands only on the machine's loopback interface. Nothing is published to the
# network. The trust you are extending is to the machine, not to the internet.

af_mac_chrome() {
  af_browser_defaults
  local sub="${1:-status}"; shift || true
  [ "$AF_MAC_CHROME" = 1 ] || af_die \
    "AF_MAC_CHROME is off. Enabling it gives every agent on every machine full control of a browser holding your logged-in sessions - read the entry in agentfleet.conf.example first."

  local host
  case "$sub" in
    start) af_mac_chrome_start ;;
    up)     for host in $(af_expand_hosts "$@"); do af_mac_chrome_up "$host"; done ;;
    down)   for host in $(af_expand_hosts "$@"); do af_tun_close "$(af_tun_sock R "$AF_MAC_CHROME_PORT" "$host")"; af_log "[mac-chrome] $host: tunnel closed"; done ;;
    status) local seen
            for host in $(af_expand_hosts "$@"); do
              seen="$(af_ssh "$host" "curl -s -m 4 http://127.0.0.1:$AF_MAC_CHROME_PORT/json/version" 2>/dev/null \
                | sed -n 's/.*"Browser": *"\([^"]*\)".*/\1/p' || true)"
              printf '%-10s %s\n' "$host" "${seen:-no tunnel}"
            done ;;
    *) af_browser_usage; return 1 ;;
  esac
}

# Never point this at your everyday profile. Current Chrome refuses
# --remote-debugging-port on the default profile, so the only way in there is a
# consent dialog on every single attach. A separate profile launched with the
# flag from the start has no prompt, agents never touch the tabs you are working
# in, and a runaway agent cannot reach your main session. Log in once inside
# this window and it persists.
af_mac_chrome_start() {
  local profile="$AF_CACHE/chrome-profile" bin="$AF_CHROME_BIN" i
  if [ -z "$bin" ]; then
    for i in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
             "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
      [ -x "$i" ] && { bin="$i"; break; }
    done
  fi
  if [ -z "$bin" ]; then
    for i in google-chrome google-chrome-stable chromium chromium-browser; do
      command -v "$i" >/dev/null 2>&1 && { bin="$(command -v "$i")"; break; }
    done
  fi
  [ -n "$bin" ] || af_die "no Chrome or Chromium found - set AF_CHROME_BIN"

  if af_mac_cdp_port >/dev/null; then
    af_log "[mac-chrome] already up on :$AF_MAC_CHROME_LOCAL_PORT"
    return 0
  fi

  mkdir -p "$profile"
  # --remote-allow-origins is deliberately absent by default. With it set to '*'
  # any page in any browser on this laptop can open the DevTools websocket and
  # drive this fully logged-in profile. Set AF_MAC_CHROME_ORIGINS only for a
  # specific client that needs it, and only to that exact origin.
  local origins=()
  [ -n "$AF_MAC_CHROME_ORIGINS" ] && origins=(--remote-allow-origins="$AF_MAC_CHROME_ORIGINS")
  "$bin" --user-data-dir="$profile" --remote-debugging-port="$AF_MAC_CHROME_LOCAL_PORT" \
    --no-first-run --no-default-browser-check "${origins[@]+"${origins[@]}"}" \
    >/dev/null 2>&1 &

  # The CDP endpoint is not listening when the process forks, so anything that
  # reads it immediately gets a stale or empty answer.
  for i in $(seq 1 20); do
    sleep 1
    af_mac_cdp_port >/dev/null && { af_log "[mac-chrome] up on :$AF_MAC_CHROME_LOCAL_PORT (profile $profile)"; return 0; }
  done
  af_die "the browser did not come up on :$AF_MAC_CHROME_LOCAL_PORT"
}

# Same rule as everywhere else in this file: the body must say "Browser". A
# browser that answers with a 404 is not a browser you can drive.
af_mac_cdp_port() {
  curl -s -m 2 "http://127.0.0.1:$AF_MAC_CHROME_LOCAL_PORT/json/version" 2>/dev/null \
    | grep -q '"Browser"' || return 1
  printf '%s' "$AF_MAC_CHROME_LOCAL_PORT"
}

af_mac_chrome_up() {
  local host="$1" sock addr port
  port="$(af_mac_cdp_port)" \
    || af_die "no drivable browser on 127.0.0.1:$AF_MAC_CHROME_LOCAL_PORT - run: agentfleet browser mac-chrome start"

  sock="$(af_tun_sock R "$AF_MAC_CHROME_PORT" "$host")"
  af_tun_close "$sock"
  addr="$(af_host_addr "$host")" || af_die "cannot resolve host: $host"

  ssh "${AF_SSH_OPTS[@]}" -o ExitOnForwardFailure=yes -M -S "$sock" -f -N \
    -R "${AF_MAC_CHROME_PORT}:127.0.0.1:${port}" "$AF_USER@$addr" \
    || af_die "$host: could not open the reverse tunnel (a stale listener on :$AF_MAC_CHROME_PORT?)"

  af_ssh "$host" "curl -s -m 4 http://127.0.0.1:$AF_MAC_CHROME_PORT/json/version" 2>/dev/null \
    | grep -q '"Browser"' \
    || af_die "$host: the tunnel opened but nothing answers on :$AF_MAC_CHROME_PORT"
  af_log "[mac-chrome] $host: 127.0.0.1:$AF_MAC_CHROME_PORT -> your laptop browser (af-open -m)"
}
