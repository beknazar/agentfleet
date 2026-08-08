#!/usr/bin/env bash
# Stop an agent machine from freezing itself out of existence.
#
# This is the highest-value file in the repo, and the reason is boring: a coding
# agent WILL wedge a box. Fan out enough subagents, let one of them run a build,
# and RAM is gone. Linux does not OOM-kill fast enough, the machine goes into
# swapless thrash, and sshd can no longer fork - so the machine is unreachable
# while the provider still reports it as running. Even the provider's own guest
# agent stops completing commands. There is no way in. You rebuild it.
#
# Four layers, cheapest first:
#   1. swap       turns a hard wall into slow. Slow you can log into.
#   2. earlyoom   kills the single worst hog at a threshold, instead of letting
#                 the kernel freeze everything while it thinks about it.
#   3. sshd guard sshd is made OOM-immune, so a rescue login always works. This
#                 is the layer that turns "rebuild the machine" into "ssh in and
#                 kill it", and it is worth more than the other three combined.
#   4. agent cap  a fan-out setting tuned on a 64GB laptop is not survivable on
#                 a smaller machine, and config sync will happily copy it over.
#
# Run by `agentfleet provision`; idempotent, and safe to run by hand on a
# machine that is currently misbehaving.
#
# No `set -e`: every layer is attempted even if an earlier one fails, because
# partial hardening beats none. Failures are collected and reported at the end,
# and the script exits nonzero - a layer that could not be applied is not a pass.
set -uo pipefail

AF_NAME="${AF_NAME:-agentfleet}"
AF_AGENT="${AF_AGENT:-claude}"
AF_SWAP_GB="${AF_SWAP_GB:-}"
AF_SUBAGENT_CAP="${AF_SUBAGENT_CAP:-}"
AF_EARLYOOM_PREFER="${AF_EARLYOOM_PREFER:-}"

fail=0
say()  { printf '  %s\n' "$*"; }
bad()  { printf '  FAILED: %s\n' "$*" >&2; fail=1; }

MEM_GB="$(awk '/^MemTotal:/ {printf "%d", int($2/1048576 + 0.5)}' /proc/meminfo)"
if [ -z "$MEM_GB" ] || [ "$MEM_GB" -lt 1 ]; then MEM_GB=1; fi
printf '== %s: %sGB RAM ==\n' "$(hostname)" "$MEM_GB"

# ---------------------------------------------------------------- 1. swap

# Cloud images ship with no swap at all, which is what makes the failure so
# abrupt: the machine is fine, and then it is gone. Default to matching RAM,
# capped, because past that you are only buying a longer thrash.
SWAPON="$(command -v swapon 2>/dev/null || printf '/usr/sbin/swapon')"
swap_gb="$AF_SWAP_GB"
case "$swap_gb" in
  '') swap_gb="$MEM_GB"; if [ "$swap_gb" -gt 32 ]; then swap_gb=32; fi ;;
  *[!0-9]*) bad "AF_SWAP_GB is not a number: $swap_gb - using RAM size instead"
            swap_gb="$MEM_GB" ;;
esac

if [ "$swap_gb" = 0 ]; then
  say "swap: disabled by config"
elif "$SWAPON" --show 2>/dev/null | grep -q .; then
  say "swap: already on ($("$SWAPON" --show=SIZE --noheadings 2>/dev/null | tr -d ' ' | head -1))"
else
  if ! sudo fallocate -l "${swap_gb}G" /swapfile 2>/dev/null; then
    sudo dd if=/dev/zero of=/swapfile bs=1M count="$((swap_gb * 1024))" status=none
  fi
  sudo chmod 600 /swapfile
  sudo mkswap -q /swapfile >/dev/null 2>&1
  if sudo swapon /swapfile; then
    grep -q '^/swapfile' /etc/fstab || printf '/swapfile none swap sw 0 0\n' | sudo tee -a /etc/fstab >/dev/null
    # Reclaim page cache before swapping out an agent's working set: swapping
    # the thing you are actively waiting on is how "slow" becomes "hung".
    printf 'vm.swappiness=10\n' | sudo tee "/etc/sysctl.d/99-$AF_NAME-swap.conf" >/dev/null
    sudo sysctl -q -w vm.swappiness=10
    say "swap: enabled ${swap_gb}G, swappiness 10"
  else
    sudo rm -f /swapfile
    bad "could not enable a ${swap_gb}G swapfile (disk space?)"
  fi
fi

# ---------------------------------------------------------------- 2. earlyoom

# Which processes to sacrifice matters as much as the killing. Never sshd,
# systemd, the tmux server or the session bus: killing any of those turns a
# recoverable overload into a machine you cannot reach or a session you cannot
# find. Prefer the runtimes an agent spawns, which are both the biggest and the
# cheapest to restart.
#
# No whitespace in either pattern. systemd expands EARLYOOM_ARGS into the unit's
# command line and splits it on spaces without re-parsing quotes, so a pattern
# containing a space silently becomes two broken arguments.
EARLYOOM_AVOID='(^|/)(sshd|systemd|dbus-daemon)$|^tmux'
if [ -z "$AF_EARLYOOM_PREFER" ]; then
  AF_EARLYOOM_PREFER='(^|/)(node|claude|codex|chrome|chromium|python3|vitest|esbuild)$'
fi
case "$AF_EARLYOOM_PREFER" in
  *[[:space:]]*) bad "AF_EARLYOOM_PREFER contains whitespace, which systemd will split into broken arguments: $AF_EARLYOOM_PREFER"
                 AF_EARLYOOM_PREFER='(^|/)(node|claude|codex|chrome|chromium|python3|vitest|esbuild)$' ;;
esac

if ! command -v earlyoom >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq earlyoom >/dev/null 2>&1
fi
if command -v earlyoom >/dev/null 2>&1; then
  # Rewritten every run, not only on first install: otherwise a changed prefer
  # list never reaches a machine that already has earlyoom.
  printf 'EARLYOOM_ARGS="-m 6 -s 12 -r 60 --avoid %s --prefer %s"\n' \
    "$EARLYOOM_AVOID" "$AF_EARLYOOM_PREFER" | sudo tee /etc/default/earlyoom >/dev/null
  sudo systemctl enable earlyoom >/dev/null 2>&1
  sudo systemctl restart earlyoom >/dev/null 2>&1
  if systemctl is-active --quiet earlyoom; then
    say "earlyoom: active (kills at 6% free)"
  else
    bad "earlyoom installed but not active: systemctl status earlyoom"
  fi
else
  bad "earlyoom is not installed and could not be installed"
fi

# ---------------------------------------------------------------- 3. sshd

# The rescue path. Everything else can fail as long as you can still get a shell
# and kill the offender yourself.
# ssh.service first: on Debian and Ubuntu that is the real unit and
# sshd.service is only an alias, and a drop-in directory for an alias is
# ignored - the protection would look applied and do nothing.
SSHD_UNIT=""
for u in ssh.service sshd.service; do
  if systemctl cat "$u" >/dev/null 2>&1; then SSHD_UNIT="$u"; break; fi
done
if [ -z "$SSHD_UNIT" ]; then
  bad "no ssh unit found - cannot protect the rescue login"
else
  sudo mkdir -p "/etc/systemd/system/$SSHD_UNIT.d"
  sudo tee "/etc/systemd/system/$SSHD_UNIT.d/oom.conf" >/dev/null <<'EOF'
[Service]
# Managed by agentfleet: keep a login available on an out-of-memory machine.
OOMScoreAdjust=-900
OOMPolicy=continue
EOF
  sudo systemctl daemon-reload
  # Restarting the listener does not disturb established sessions, including
  # this one - the connection you are reading this over survives.
  sudo systemctl restart "$SSHD_UNIT" >/dev/null 2>&1
  if systemctl show "$SSHD_UNIT" -p OOMScoreAdjust 2>/dev/null | grep -q -- '-900'; then
    say "sshd: OOM-protected ($SSHD_UNIT, $(systemctl is-active "$SSHD_UNIT"))"
  else
    bad "OOM protection did not apply to $SSHD_UNIT - a wedged machine will be unreachable"
  fi
fi

# ---------------------------------------------------------------- 4. agent cap

# Roughly one subagent per 3GB, which is what survives in practice once each one
# is running its own toolchain. Written to a file the machine owns, so it wins
# over whatever value gets synced down from a much larger laptop.
cap="$AF_SUBAGENT_CAP"
case "$cap" in
  *[!0-9]*|'')
    if [ -n "$cap" ]; then bad "AF_SUBAGENT_CAP is not a number: $cap - computing from RAM"; fi
    cap=$((MEM_GB / 3))
    if [ "$cap" -lt 2 ]; then cap=2; fi
    ;;
esac
tool_cap=$((cap * 3 / 2))
if [ "$tool_cap" -lt 4 ]; then tool_cap=4; fi

CAP_FILE="/etc/profile.d/$AF_NAME-agent.sh"
{
  printf '# Managed by agentfleet: fan-out cap for this machine (%sGB RAM).\n' "$MEM_GB"
  printf '# A laptop-sized concurrency setting will freeze a machine this size\n'
  printf '# hard enough that sshd cannot fork. These exports override it.\n'
  printf 'export AGENTFLEET_SUBAGENT_CAP=%s\n' "$cap"
  case "$AF_AGENT" in
    claude|both)
      printf 'export CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=%s\n' "$cap"
      printf 'export CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=%s\n' "$tool_cap"
      ;;
  esac
} | sudo tee "$CAP_FILE" >/dev/null
sudo chmod 644 "$CAP_FILE"

# /etc/profile.d only reaches login shells. The shells that actually run agents
# are the ones tmux spawns, so source it from the per-user rc files too.
for rc in "$HOME/.zshenv" "$HOME/.bashrc"; do
  if ! grep -q "$AF_NAME-agent.sh" "$rc" 2>/dev/null; then
    printf '\n[ -f %s ] && . %s\n' "$CAP_FILE" "$CAP_FILE" >>"$rc"
  fi
done
say "agent cap: $cap subagents, $tool_cap concurrent tool calls"

# ---------------------------------------------------------------- report

free -m | awk '/^Mem:/ {printf "  memory: %sMB total, %sMB available\n", $2, $7}'
"$SWAPON" --show=NAME,SIZE --noheadings 2>/dev/null | awk '{printf "  swap:   %s %s\n", $1, $2}'
exit "$fail"
