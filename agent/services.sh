#!/usr/bin/env bash
# Install the machine's own services as systemd --user units.
#
# WHY units and not tmux sessions: stopping a machine you are not using is the
# whole cost story of a fleet, and stop/start has to be a no-touch operation.
# Anything started inside a tmux session - the status collector, the web
# terminal, the browser stack - is gone after that cycle, and the machine comes
# back looking healthy while being half-equipped until the next provision. As
# lingering user units they come back by themselves.
#
# Run by `agentfleet provision`; idempotent.
#
# No `set -e`: install every unit even if one of them cannot start, then report
# and exit nonzero. A service that could not start is not a pass.
set -uo pipefail

AF_NAME="${AF_NAME:-agentfleet}"
AF_WORKDIR="${AF_WORKDIR:-$HOME}"
AF_SESSION="${AF_SESSION:-main}"
AF_BROWSER="${AF_BROWSER:-0}"
AF_NOVNC_PORT="${AF_NOVNC_PORT:-6080}"
AF_CDP_PORT="${AF_CDP_PORT:-9222}"
AF_VNC_BIND="${AF_VNC_BIND:-}"
AF_STATUS_INTERVAL="${AF_STATUS_INTERVAL:-15}"
# Xvfb geometry for the browser stack. noVNC scales the view to whatever window
# you open it in, so this is a constant rather than a setting.
AF_BROWSER_SCREEN=1600x1000x24
# Same port the dashboard's "term" link points at. Empty there means "do not
# offer the link", not "do not run the terminal".
AF_TERM_PORT="${AF_TERM_PORT:-}"
if [ -z "$AF_TERM_PORT" ]; then AF_TERM_PORT=7681; fi

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
BIN_DIR="$HOME/.local/bin"
STATE_DIR="$HOME/.agentfleet"

fail=0
say() { printf '  %s\n' "$*"; }
bad() { printf '  FAILED: %s\n' "$*" >&2; fail=1; }

# The web terminal starts tmux in the work directory, and tmux exits if that
# directory does not exist - which reads as a broken unit, not a missing folder.
mkdir -p "$UNIT_DIR" "$BIN_DIR" "$STATE_DIR" "$AF_WORKDIR"

# ---------------------------------------------------------------- lingering

# Without lingering, every user unit is killed the moment the last ssh session
# closes, so the machine you stopped last night comes back with nothing running
# and the dashboard shows it as silent. This is the single step that quietly
# does not happen, so it gets verified rather than assumed.
sudo loginctl enable-linger "$(id -un)" 2>/dev/null
if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != "yes" ]; then
  printf '  FAILED: lingering is not enabled for %s - user units will die at logout\n' "$(id -un)" >&2
  exit 1
fi

# `systemctl --user` needs to find the user bus, and a non-interactive ssh
# command does not always arrive with it set.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
if ! systemctl --user show-environment >/dev/null 2>&1; then
  printf '  FAILED: no systemd user bus at %s\n' "$XDG_RUNTIME_DIR" >&2
  exit 1
fi

units=""

# ---------------------------------------------------------------- status collector

# The collector is what answers "which of my agents needs me", so it runs on a
# timer rather than as a daemon: if it crashes on one bad transcript, the next
# tick still reports.
collector=""
for c in "$AGENT_DIR/af-status.py" "$AGENT_DIR/af-status.sh" "$AGENT_DIR/status.py" "$AGENT_DIR/status.sh"; do
  if [ -f "$c" ]; then collector="$c"; break; fi
done

if [ -z "$collector" ]; then
  printf '  WARNING: no status collector in %s - the dashboard will show nothing for this machine\n' "$AGENT_DIR" >&2
else
  case "$collector" in
    *.py) collector_cmd="/usr/bin/env python3 $collector" ;;
    *)    collector_cmd="/bin/bash $collector" ;;
  esac
  # No Environment= lines: the collector reads its own settings file
  # (~/.config/agentfleet/agent.env), which provisioning rewrites every run.
  # Baking values into the unit would mean regenerating the unit as well.
  cat >"$UNIT_DIR/$AF_NAME-status.service" <<EOF
[Unit]
Description=agentfleet status collector

[Service]
Type=oneshot
ExecStart=$collector_cmd
EOF
  # AccuracySec: systemd batches timers to one minute by default to save power,
  # which would turn a 15 second interval into a minute and make the dashboard
  # feel dead.
  cat >"$UNIT_DIR/$AF_NAME-status.timer" <<EOF
[Unit]
Description=agentfleet status collector timer

[Timer]
OnBootSec=30s
OnUnitActiveSec=${AF_STATUS_INTERVAL}s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
  units="$units $AF_NAME-status.timer"
fi

# ---------------------------------------------------------------- cost collector

# The other half of what the dashboard reads. Nothing else in the fleet ever
# runs af-cost.py, so without this pair cost.json is never written and the TODAY
# column is "-" on every row forever, on a machine that provisioned cleanly.
# Slower than the status timer on purpose: pricing a day of transcripts is a
# full scan and the number moves in cents, not in seconds.
if [ -f "$AGENT_DIR/af-cost.py" ]; then
  # EnvironmentFile here, unlike the status collector, because af-cost.py reads
  # AF_COST_PRICES from the process environment only - it never opens agent.env
  # itself. Without this line the timer would run at the built-in price guesses
  # and the operator's override in the config would silently do nothing, which
  # is worse than an empty column. Leading `-`: a machine whose agent.env has
  # not been written yet still starts.
  cat >"$UNIT_DIR/$AF_NAME-cost.service" <<EOF
[Unit]
Description=agentfleet token cost collector

[Service]
Type=oneshot
EnvironmentFile=-$HOME/.config/agentfleet/agent.env
ExecStart=/usr/bin/env python3 $AGENT_DIR/af-cost.py
EOF
  cat >"$UNIT_DIR/$AF_NAME-cost.timer" <<EOF
[Unit]
Description=agentfleet token cost collector timer

[Timer]
OnBootSec=60s
OnUnitActiveSec=300s

[Install]
WantedBy=timers.target
EOF
  units="$units $AF_NAME-cost.timer"
fi

# ---------------------------------------------------------------- web terminal

# ttyd runs with -W (writable): anyone who can reach the port has a shell as
# this user, with no password. That is only acceptable because it is bound to
# an interface nobody else is on, so the binding is checked here rather than
# left to a sentence in the docs. No tailnet means loopback only, and you reach
# it with `ssh -L`.
if ! command -v ttyd >/dev/null 2>&1; then
  bad "ttyd is not installed - no web terminal on this machine"
else
  if ip link show tailscale0 >/dev/null 2>&1; then
    TTYD_IFACE=tailscale0
    TTYD_NOTE="tailnet only"
  else
    TTYD_IFACE=lo
    TTYD_NOTE="loopback only, no tailnet interface here; reach it with ssh -L $AF_TERM_PORT:localhost:$AF_TERM_PORT"
  fi
  cat >"$UNIT_DIR/$AF_NAME-ttyd.service" <<EOF
[Unit]
Description=agentfleet web terminal

[Service]
ExecStart=$(command -v ttyd) -W -i $TTYD_IFACE -p $AF_TERM_PORT tmux new -A -s $AF_SESSION -c $AF_WORKDIR
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
  units="$units $AF_NAME-ttyd.service"
  say "web terminal: port $AF_TERM_PORT ($TTYD_NOTE)"
fi

# ---------------------------------------------------------------- browser stack

if [ "$AF_BROWSER" = 1 ]; then
  # Same rule as ttyd above, for the same reason: x11vnc runs -nopw, so whoever
  # reaches the noVNC port owns the desktop - and the Chromium on it reads
  # file:///home/<user>/.ssh and the pushed API keys, then opens
  # http://127.0.0.1:$AF_TERM_PORT for a writable shell, which is exactly the
  # thing pinning ttyd to an interface was supposed to prevent. A tailnet adds
  # an interface, it does not take the public IP away, and the ssh/BYO provider
  # ships no host firewall - so a wildcard bind is refused here rather than
  # trusted to a sentence in the docs. Set AF_VNC_BIND to a SPECIFIC address
  # (a LAN IP, say) to serve somewhere else on purpose.
  VNC_WILDCARD=""
  case "$AF_VNC_BIND" in
    '') ;;
    '0.0.0.0'|'::'|'*'|'[::]') VNC_WILDCARD="$AF_VNC_BIND" ;;
    *) VNC_BIND="$AF_VNC_BIND"; VNC_NOTE="explicit AF_VNC_BIND" ;;
  esac
  if [ -z "${VNC_BIND:-}" ]; then
    VNC_ADDR=""
    if ip link show tailscale0 >/dev/null 2>&1; then
      VNC_ADDR="$(ip -4 -o addr show tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    fi
    if [ -n "$VNC_ADDR" ]; then
      VNC_BIND="$VNC_ADDR"
      VNC_NOTE="tailnet only"
    else
      VNC_BIND="127.0.0.1"
      VNC_NOTE="loopback only, no tailnet address here; reach it with ssh -L $AF_NOVNC_PORT:localhost:$AF_NOVNC_PORT"
    fi
  fi
  if [ -n "$VNC_WILDCARD" ]; then
    say "noVNC: ignoring AF_VNC_BIND=$VNC_WILDCARD - the VNC desktop has no password and that bind would publish it on every interface, public IP included"
  fi
  say "noVNC: port $AF_NOVNC_PORT on $VNC_BIND ($VNC_NOTE)"
  cat >"$BIN_DIR/$AF_NAME-browser-stack" <<EOF
#!/usr/bin/env bash
# Managed by agentfleet: Xvfb -> Chrome -> x11vnc -> noVNC, as one supervised
# process tree so systemd can restart the whole thing as a unit.
set -uo pipefail
CHROME=\$(ls ~/.cache/ms-playwright/chromium-*/chrome-linux*/chrome 2>/dev/null | head -1)
[ -n "\$CHROME" ] || { echo "no chromium: run 'playwright install chromium'"; sleep 30; exit 1; }
pkill -x Xvfb 2>/dev/null; pkill -x x11vnc 2>/dev/null; sleep 1
Xvfb :99 -screen 0 $AF_BROWSER_SCREEN &
sleep 2
# --no-sandbox: current Ubuntu blocks unprivileged user namespaces via AppArmor,
# which Chrome's sandbox needs. Acceptable here and only here: one user, no
# other tenants, and the display is not reachable off the tailnet.
DISPLAY=:99 "\$CHROME" --no-sandbox --no-first-run --no-default-browser-check \\
  --remote-debugging-port=$AF_CDP_PORT --user-data-dir="\$HOME/.$AF_NAME-chrome" about:blank &
sleep 2
# -nopw with -localhost: the VNC port itself never leaves the machine, so the
# only exposed surface is the noVNC bind below.
x11vnc -display :99 -forever -shared -nopw -quiet -localhost &
exec websockify --web /usr/share/novnc $VNC_BIND:$AF_NOVNC_PORT localhost:5900
EOF
  chmod +x "$BIN_DIR/$AF_NAME-browser-stack"
  cat >"$UNIT_DIR/$AF_NAME-browser.service" <<EOF
[Unit]
Description=agentfleet headful Chrome and noVNC

[Service]
ExecStart=$BIN_DIR/$AF_NAME-browser-stack
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
  units="$units $AF_NAME-browser.service"
fi

# ---------------------------------------------------------------- start

# Anything left running from an earlier hand-started copy is squatting the port
# these units want. A squatted port turns Restart=always into an infinite
# failure loop that looks like a broken unit file.
tmux kill-session -t ttyd 2>/dev/null
tmux kill-session -t browser 2>/dev/null
pkill -x ttyd 2>/dev/null

systemctl --user daemon-reload
for u in $units; do
  systemctl --user enable --now "$u" >/dev/null 2>&1
done
sleep 5

for u in $units; do
  state="$(systemctl --user is-active "$u" 2>/dev/null)"
  case "$state" in
    active|activating|waiting) say "$u: $state" ;;
    *) bad "$u: $state ($(systemctl --user is-failed "$u" 2>/dev/null) - journalctl --user -u $u)" ;;
  esac
done

exit "$fail"
