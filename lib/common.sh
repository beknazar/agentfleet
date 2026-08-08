#!/usr/bin/env bash
# Shared plumbing: config loading, host resolution, ssh helpers.
#
# Sourced by the `agentfleet` entrypoint before anything else, so every
# subcommand and every provider can assume AF_* is populated and af_ssh works.
#
# Bash 3.2 compatible on purpose - that is what ships with macOS, and the
# control plane runs on the operator's laptop. No associative arrays, no
# `mapfile`, no `${x^^}`.

set -euo pipefail

AF_VERSION="0.1.0"

af_log()  { printf '%s\n' "$*" >&2; }
af_warn() { printf 'warning: %s\n' "$*" >&2; }
af_die()  { printf 'agentfleet: %s\n' "$*" >&2; exit 1; }
af_need() { command -v "$1" >/dev/null 2>&1 || af_die "missing dependency: $1"; }

# ---------------------------------------------------------------- config

# Search order: $AGENTFLEET_CONFIG, ./agentfleet.conf, ~/.config/agentfleet/config.
# A repo-local file wins over the global one so you can keep a throwaway fleet
# next to a project without disturbing your main config.
af_config_path() {
  if [ -n "${AGENTFLEET_CONFIG:-}" ]; then printf '%s' "$AGENTFLEET_CONFIG"; return; fi
  if [ -f ./agentfleet.conf ]; then printf '%s' "$PWD/agentfleet.conf"; return; fi
  printf '%s' "$HOME/.config/agentfleet/config"
}

af_load_config() {
  AF_CONFIG="$(af_config_path)"

  # Defaults first, then the config file overrides them. Every one of these is
  # documented in agentfleet.conf.example.
  AF_NAME="agentfleet"
  AF_PROVIDER="ssh"
  AF_HOSTS=""
  # id -un, not a bare $USER: under `set -u` an unexported USER kills every
  # command with "unbound variable", and USER is routinely absent from cron,
  # systemd units, containers and `env -i` - exactly where an unattended sync
  # or status run lives.
  AF_USER="${USER:-$(id -un)}"
  AF_HOME=""
  AF_KEY=""
  AF_WORKDIR=""
  AF_REPO=""
  AF_AGENT="claude"
  AF_SYNC_PATHS=""
  AF_SECRETS=""
  AF_TAILNET="auto"
  AF_DASH_PORT="8788"
  AF_SUBAGENT_CAP=""
  AF_SWAP_GB="16"
  AF_SESSION="main"
  AF_PROVISION_HOOK=""
  AF_READY_HOOK=""

  if [ -f "$AF_CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$AF_CONFIG"
  elif [ "${AF_CONFIG_OPTIONAL:-0}" != 1 ]; then
    af_die "no config at $AF_CONFIG - run: agentfleet init"
  fi

  # Derived defaults, applied after the config so they can depend on it.
  [ -n "$AF_KEY" ]     || AF_KEY="$HOME/.ssh/$AF_NAME"
  [ -n "$AF_HOME" ]    || AF_HOME="/home/$AF_USER"
  [ -n "$AF_WORKDIR" ] || AF_WORKDIR="$AF_HOME/work"

  AF_SSH_CONF="$HOME/.ssh/$AF_NAME.conf"
  AF_CACHE="$HOME/.cache/agentfleet"

  # Address cache for this run, keyed by the control process. $$ is the same
  # inside every subshell, so all the legs of one command share one file, and a
  # later run never reads a dead one's entries. Cleared in case the pid was
  # recycled, and old files (nothing resolved into them for ten minutes) are
  # swept so a long-lived dashboard does not litter the cache directory.
  AF_ADDR_CACHE="$AF_CACHE/addr.$$"
  rm -f "$AF_ADDR_CACHE" 2>/dev/null || true
  find "$AF_CACHE" -maxdepth 1 -type f -name 'addr.*' -mmin +10 -delete 2>/dev/null || true

  af_ssh_opts_init

  case "$AF_PROVIDER" in
    ssh|azure) ;;
    *) af_die "unknown provider: $AF_PROVIDER (have: ssh, azure)" ;;
  esac
}

# ---------------------------------------------------------------- providers

# A provider only has to answer five questions. Everything else in agentfleet is
# provider-neutral, which is why `ssh` (a static host list, no cloud account at
# all) is a first-class backend and not a degraded mode.
#
#   provider_list                 -> one host name per line
#   provider_addr   <host>        -> an address ssh can reach, or empty
#   provider_create <host> [size] -> make the machine, print its address
#   provider_start  <host>        -> resume a stopped machine
#   provider_stop   <host> [--delete]
af_provider_load() {
  local p="$AF_DIR/providers/$AF_PROVIDER.sh"
  [ -f "$p" ] || af_die "provider not found: $p"
  # shellcheck disable=SC1090
  . "$p"
}

# ---------------------------------------------------------------- hosts

# TAILNET FIRST, ALWAYS.
#
# Cloud firewalls are typically pinned to the operator's current public IP, so
# the moment that changes - different wifi, ISP re-lease, a train - every host
# becomes unreachable while being perfectly healthy. That stranded an entire
# fleet once. A tailnet address does not care what your egress IP is.
#
# Resolution is cached for the run: host_addr gets called in loops and shelling
# out to `tailscale status` - or worse, a cloud CLI - ten times to run one ssh is
# pure latency.
#
# The cache has to live in a FILE, not in this variable. Every call site captures
# af_host_addr in a command substitution, so an in-memory assignment lands in a
# subshell and dies with it: the cache this comment used to describe never hit
# once. AF_ADDR_CACHE now holds the path and keeps its second job unchanged -
# setting it to "" turns caching off for the rest of the process, which is how
# lib/provision.sh invalidates after creating a machine or joining one to the
# tailnet, i.e. exactly when the address it would have cached just changed.
AF_ADDR_CACHE=""
af_tailscale_bin() {
  if command -v tailscale >/dev/null 2>&1; then command -v tailscale; return 0; fi
  local mac="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  [ -x "$mac" ] && { printf '%s' "$mac"; return 0; }
  return 1
}

af_tailnet_addr() {
  [ "$AF_TAILNET" = off ] && return 1
  local ts; ts="$(af_tailscale_bin)" || return 1
  local ip
  ip="$("$ts" status 2>/dev/null | awk -v h="$1" '$2==h {print $1; exit}')"
  [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
  return 1
}

af_host_addr() {
  local host="$1" hit=""
  if [ -n "$AF_ADDR_CACHE" ] && [ -f "$AF_ADDR_CACHE" ]; then
    hit="$(awk -F'\t' -v h="$host" '$1==h {print $2; exit}' "$AF_ADDR_CACHE" 2>/dev/null || true)"
    [ -n "$hit" ] && { printf '%s' "$hit"; return 0; }
  fi

  local addr=""
  addr="$(af_tailnet_addr "$host" || true)"
  [ -n "$addr" ] || addr="$(provider_addr "$host" 2>/dev/null || true)"
  [ -n "$addr" ] || return 1

  # Appended, never rewritten: the parallel fan-outs (af_ssh_all, the sync loop)
  # each write from their own subshell, and one short O_APPEND line does not
  # interleave with another. A failed write is not fatal - it only costs the
  # next caller another lookup.
  if [ -n "$AF_ADDR_CACHE" ]; then
    ( umask 077
      mkdir -p "$(dirname "$AF_ADDR_CACHE")" \
        && printf '%s\t%s\n' "$host" "$addr" >>"$AF_ADDR_CACHE" ) 2>/dev/null || true
  fi
  printf '%s' "$addr"
}

# "all" expands to every host the provider knows about.
#
# An explicit name is checked against the fleet you declared. Without the check a
# typo is not an error at all: providers/ssh.sh answers "the name IS the address",
# so `agentfleet secrets push w1` on a fleet of hz1..hz3 resolves "w1" through
# whatever search domain the current network hands out and starts pushing
# credential FILES at it. Only AF_HOSTS is consulted up front because reading it
# is free; a name missing from it makes the provider enumerate once (a cloud call)
# before we refuse, and a cloud fleet that does not use AF_HOSTS pays nothing and
# is still gated by provider_addr failing on a machine it does not know.
# AF_ANY_HOST=1 is the escape hatch for a machine that is not in the list yet.
af_expand_hosts() {
  if [ "${1:-all}" = all ]; then provider_list; return; fi
  local host known="" declared
  declared=" $(printf '%s' "${AF_HOSTS:-}" | tr '\n\t' '  ') "
  if [ -n "${AF_HOSTS:-}" ] && [ "${AF_ANY_HOST:-0}" != 1 ]; then
    for host in $(printf '%s\n' "$@" | tr ' ' '\n' | grep -v '^$'); do
      case "$declared" in *" $host "*) continue ;; esac
      # Only reached on a miss, and only once per command.
      [ -n "$known" ] || known="$(provider_list 2>/dev/null || true)"
      printf '%s\n' "$known" | grep -qxF -- "$host" || af_die \
        "$host is not in your fleet: not in AF_HOSTS (\"$AF_HOSTS\") and provider $AF_PROVIDER does not list it. Add it in ${AF_CONFIG:-your config}, or re-run with AF_ANY_HOST=1 to target a machine that is not listed."
    done
  fi
  printf '%s\n' "$@" | tr ' ' '\n' | grep -v '^$'
}

# ---------------------------------------------------------------- ssh

# BatchMode: never hang a script on a password prompt.
# accept-new: trust on first use, but still detect a changed key afterwards.
# ServerAliveInterval: a wedged box drops the connection instead of hanging.
#
# Built once by af_load_config so callers never rebuild it in a loop.
af_ssh_opts_init() {
  AF_SSH_OPTS=(-i "$AF_KEY"
    -o StrictHostKeyChecking=accept-new
    -o BatchMode=yes
    -o "ConnectTimeout=${AF_SSH_TIMEOUT:-15}"
    -o ServerAliveInterval=30)
}

af_ssh() {
  local host="$1"; shift
  local addr; addr="$(af_host_addr "$host")" || af_die "cannot resolve host: $host"
  # SC2029: the command expanding locally is the point - callers build the
  # remote command string deliberately, and anything untrusted rides base64.
  # shellcheck disable=SC2029
  ssh "${AF_SSH_OPTS[@]}" "$AF_USER@$addr" "$@"
}

af_ssh_tty() {
  local host="$1"; shift
  local addr; addr="$(af_host_addr "$host")" || af_die "cannot resolve host: $host"
  ssh "${AF_SSH_OPTS[@]}" -t "$AF_USER@$addr" "$@"
}

af_scp() {
  local host="$1" src="$2" dst="$3"
  local addr; addr="$(af_host_addr "$host")" || af_die "cannot resolve host: $host"
  scp "${AF_SSH_OPTS[@]}" "$src" "$AF_USER@$addr:$dst"
}

# rsync splits its -e/--rsh value on whitespace, and rsync implementations do not
# agree on quoting inside it (none of them unescape backslashes, and old ones
# parse no quotes at all). So an ssh option containing a space - AF_KEY, which
# defaults under $HOME and can be pointed anywhere - arrives at ssh as two
# arguments: ssh takes the tail of the key path as the hostname and the real
# destination as the remote command. af_ssh and af_scp never had this because
# they pass "${AF_SSH_OPTS[@]}" as argv, which is why only `sync` and `provision`
# would break. Handing rsync a ONE-TOKEN path to a wrapper is the portable fix:
# the wrapper holds the options as real argv entries again.
af_rsh_wrapper() {
  local dir="${TMPDIR:-/tmp}" f opt
  # The wrapper's own path has to survive that same whitespace split, so it does
  # not go under $HOME (the thing that may contain the space in the first place).
  case "$dir" in ''|*[[:space:]]*) dir=/tmp ;; esac
  f="$(mktemp "${dir%/}/agentfleet-rsh.XXXXXX")" || return 1
  { printf '#!/bin/sh\n# Written by agentfleet for one rsync call. Safe to delete.\nexec ssh'
    for opt in "${AF_SSH_OPTS[@]}"; do
      printf " '%s'" "$(printf '%s' "$opt" | sed "s/'/'\\\\''/g")"
    done
    printf ' "$@"\n'
  } >"$f" || return 1
  printf '%s' "$f"
}

af_rsync() {
  local host="$1" src="$2" dst="$3"; shift 3
  local addr; addr="$(af_host_addr "$host")" || af_die "cannot resolve host: $host"
  local rsh rc=0
  rsh="$(af_rsh_wrapper)" || af_die "could not write the rsync ssh wrapper in ${TMPDIR:-/tmp}"
  # "sh <path>" rather than the bare path: two whitespace-free tokens, so the
  # wrapper needs no exec bit and still works when the temp directory is
  # mounted noexec.
  rsync -a "$@" -e "sh $rsh" "$src" "$AF_USER@$addr:$dst" || rc=$?
  rm -f "$rsh"
  return "$rc"
}

# Run the same command on every host at once, printing "<host>  <output>".
# Serial iteration is the wrong default here: one wedged box must never decide
# how long the other nine take.
af_ssh_all() {
  local cmd="$1" host pids="" tmp
  tmp="$(mktemp -d)"
  for host in $(provider_list); do
    ( af_ssh "$host" "$cmd" >"$tmp/$host.out" 2>"$tmp/$host.err" || echo "(unreachable)" >"$tmp/$host.out" ) &
    pids="$pids $!"
  done
  # shellcheck disable=SC2086
  wait $pids 2>/dev/null || true
  for host in $(provider_list); do
    printf '%-10s %s\n' "$host" "$(head -1 "$tmp/$host.out" 2>/dev/null)"
  done
  rm -rf "$tmp"
}

# ---------------------------------------------------------------- misc

# Ship text to a remote file without quoting hell, and without ever putting the
# content on a command line where `ps` can read it.
af_put_text() {
  local host="$1" dst="$2" mode="${3:-644}"
  af_ssh "$host" "umask 077; cat > '$dst' && chmod $mode '$dst'"
}

af_confirm() {
  [ "${AF_YES:-0}" = 1 ] && return 0
  printf '%s [y/N] ' "$1" >&2
  local a; read -r a
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
