#!/usr/bin/env bash
# `up` and `provision`: turn a machine into an agent machine.
#
# Everything in here is idempotent and re-runnable, on purpose. Provisioning
# fails in the middle far more often than it fails at the start - a package
# mirror stalls, a laptop lid closes, a tunnel drops - and "run it again" has to
# be the whole recovery procedure.
#
# The machine-side work lives in agent/*.sh. Those are pushed and executed
# there, which means the hardening scripts no longer depend on the operator's
# ssh config having been generated first.

# shellcheck source=lib/init.sh
. "$AF_DIR/lib/init.sh"

AF_AGENT_DIR="$AF_DIR/agent"
AF_REMOTE_DIR="$AF_HOME/.agentfleet"

# What we actually need before pushing anything: the login user works, it can
# sudo without a password, and the package manager is free.
#
# Deliberately NOT cloud-init's own status. A package download that stalls
# leaves cloud-init reporting "running" forever on a box that is already
# perfectly usable, and waiting on that report has stranded machines that were
# fine. Probe for the capability, not for someone else's opinion of it.
AF_READY_PROBE='id -u >/dev/null 2>&1 && sudo -n true 2>/dev/null && { ! command -v fuser >/dev/null 2>&1 || ! sudo -n fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; }'

# ---------------------------------------------------------------- up

cmd_up() {
  case "${1:-}" in
    ''|-h|--help) af_die "usage: agentfleet up <host> [size]   (cloud providers only)" ;;
  esac
  local host="$1" size="${2:-}"

  if [ "$AF_PROVIDER" = ssh ]; then
    af_die "provider=ssh does not create machines. Add $host to AF_HOSTS in $AF_CONFIG, then: agentfleet provision $host"
  fi

  af_log "[up] creating $host"
  provider_create "$host" "$size" || af_die "provider_create failed for $host"
  # The machine did not exist a moment ago, so anything cached about its address
  # is a stale miss.
  AF_ADDR_CACHE=""
  cmd_provision "$host"
}

# ---------------------------------------------------------------- provision

cmd_provision() {
  case "${1:-}" in
    ''|-h|--help) af_die "usage: agentfleet provision <host|all>" ;;
  esac
  local hosts host rc=0 failed=""
  hosts="$(af_expand_hosts "$@")"
  if [ -z "$hosts" ]; then af_die "no hosts to provision (check AF_HOSTS or your provider)"; fi

  af_need ssh
  af_need scp
  af_need rsync

  # One machine per subshell, and the loop keeps going.
  #
  # Everything below af_provision_one reports failure by af_die (exit) or, for
  # the sync leg, by a nonzero return under `set -e`. Called inline, either one
  # ends the whole process: `provision all` would stop at the first machine
  # with a failing healthcheck or a blocked repo, never touch the other nine,
  # and print nothing to say it had stopped. A fleet command must survive one
  # bad machine - and then name it, because a failure 200 lines up is a failure
  # nobody sees.
  for host in $hosts; do
    if ! ( af_provision_one "$host" ); then
      failed="$failed $host"
      rc=1
    fi
  done

  if [ -n "$failed" ]; then
    af_warn "provision did not complete for:$failed"
    af_warn "each is idempotent, so re-run just those: agentfleet provision <host>"
  fi

  # Hosts that just joined the tailnet have a new primary address; the ssh
  # config is only useful if it knows about it. Outside the failure branch on
  # purpose: the machines that DID build still need their entries.
  if ! ( cmd_sshconfig >/dev/null ); then
    af_warn "ssh config was not regenerated (see above): agentfleet sshconfig"
    rc=1
  fi
  return $rc
}

# Runs inside a subshell (see cmd_provision), which means `set -e` is suspended
# for everything it calls. Every step therefore states its own failure - an
# unchecked command here fails silently instead of aborting.
af_provision_one() {
  local host="$1" rc=0
  af_log "[provision] $host"

  af_wait_ready "$host"
  af_push_agent_scripts "$host"
  af_run_agent_script "$host" bootstrap.sh toolchain
  af_join_tailnet "$host"
  # A machine is not ready until it cannot wedge itself out of reach and its
  # services survive a stop/start. Both of those are cheap now and impossible to
  # add later, from a box you can no longer log in to.
  af_run_agent_script "$host" harden.sh hardening
  af_write_agent_env "$host"
  af_run_agent_script "$host" services.sh services

  # The sync leg is per-host and reports per-host problems: one rsync path that
  # failed, a healthcheck that came back red, a repo left BLOCKED by a rebase
  # conflict. None of those unbuilds this machine and none of them says
  # anything about the next one, so they are recorded, not fatal.
  if ! af_sync_host "$host"; then
    af_warn "$host: sync leg reported a problem (above) - the machine is built"
    rc=1
  fi

  af_run_hook "$host" "${AF_PROVISION_HOOK:-}" provision
  af_run_hook "$host" "${AF_READY_HOOK:-}" ready

  if [ "$rc" = 0 ]; then
    af_log "[provision] $host ready: agentfleet ls | agentfleet attach $host"
  else
    af_log "[provision] $host built, but its config/repo sync did not finish: agentfleet sync $host"
  fi
  return $rc
}

# Classify one failed probe as "keep waiting" or "waiting will not help", and
# say it in words. Prints "<soft|hard><TAB><reason>".
#
# ssh has the answer in its stderr every single time; throwing it away is what
# turns a forgotten ssh-copy-id into twenty minutes of one unexplained line.
af_probe_reason() {
  case "$1" in
    *"cannot resolve host"*)
      # agentfleet's own message: the provider has not handed out an address
      # yet. Normal for the first seconds of a machine's life, so: keep waiting.
      printf 'soft\tno address for it yet (the provider has not published one)' ;;
    *"Could not resolve hostname"*|*"Name or service not known"*|*"nodename nor servname"*)
      printf 'hard\tthe name does not resolve' ;;
    *"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*)
      printf 'hard\tthe host key does not match ~/.ssh/known_hosts' ;;
    *"Permission denied"*|*"Too many authentication failures"*|*"No such identity"*)
      printf 'hard\tssh refused the key' ;;
    *"Connection refused"*)
      printf 'soft\tconnection refused - sshd is not answering yet' ;;
    *"timed out"*|*"No route to host"*|*"Network is unreachable"*)
      printf 'soft\tno answer on the network yet' ;;
    *sudo*)
      printf 'soft\tlogged in, but sudo still wants a password' ;;
    '')
      # ssh connected and the probe itself returned false: the probe silences
      # its own stderr, so an empty string here means "not ready", not "broken".
      printf 'soft\tlogged in, still busy (dpkg lock or sudo not ready)' ;;
    *)
      printf 'soft\t%s' "$(printf '%s' "$1" | grep -v '^Warning: Permanently added' | tail -1)" ;;
  esac
}

# The remedy follows the reason. "Read the cloud-init log" is useless advice
# for a machine ssh cannot reach at all, and doubly so for provider=ssh, where
# there is no cloud-init and the usual cause is a missing ssh-copy-id.
af_wait_ready_hint() {
  local host="$1" why="${2:-}"
  case "$why" in
    "logged in"*)
      printf 'ssh works, so the machine is the problem: agentfleet ssh %s -- sudo -n true; agentfleet ssh %s -- sudo tail -30 /var/log/cloud-init-output.log' "$host" "$host"
      return 0 ;;
  esac
  if [ "$AF_PROVIDER" = ssh ]; then
    printf 'check the name resolves and the key is installed: ssh-copy-id -i %s.pub %s@%s' \
      "$AF_KEY" "$AF_USER" "$host"
  else
    printf 'the machine is not answering ssh at all: check it booted and has an address, then read its console log in the provider'
  fi
}

af_wait_ready() {
  local host="$1" timeout="${AF_PROVISION_TIMEOUT:-1200}" deadline grace
  local err class why last=""
  deadline=$((SECONDS + timeout))
  # provider=ssh only: a short window in which an unrecoverable error is still
  # allowed to be a blip (DNS re-resolving, a laptop rejoining a network).
  grace=$((SECONDS + ${AF_PROVISION_GRACE:-60}))
  af_log "  waiting for $host to become usable (up to ${timeout}s)"
  # Generous by default: several machines provisioned at once hammer the same
  # package mirror, and a first boot that would take four minutes alone can take
  # fifteen in a batch. A short timeout here just means giving up on a machine
  # that was about to work.
  while :; do
    # Subshell: a machine created seconds ago may not have an address the
    # provider will admit to yet, and that is a reason to wait, not to stop.
    # Keep stderr (that is the diagnosis), drop stdout (that is probe noise).
    if err="$( ( af_ssh "$host" "$AF_READY_PROBE" ) 2>&1 >/dev/null )"; then
      return 0
    fi
    why="$(af_probe_reason "$err")"
    class="${why%%	*}"; why="${why#*	}"
    # Once per distinct reason, so a state change (refused -> publickey ->
    # ready) is visible without a line every fifteen seconds.
    if [ "$why" != "$last" ]; then
      af_log "    $host: $why"
      last="$why"
    fi
    # A name that does not resolve or a key ssh will not take does not fix
    # itself by waiting. Only for provider=ssh: on a cloud provider both are
    # normal for the first minute of a machine's life, while cloud-init is
    # still installing the key and the address is still propagating.
    if [ "$class" = hard ] && [ "$AF_PROVIDER" = ssh ] && [ "$SECONDS" -ge "$grace" ]; then
      af_die "$host: $why - waiting will not change that.
  $(af_wait_ready_hint "$host" "$why")"
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      af_die "$host never became usable in ${timeout}s (last: ${last:-no reason reported}).
  $(af_wait_ready_hint "$host" "$last")"
    fi
    sleep 15
  done
}

# Both legs name their own failure: everything after this point runs the
# scripts this pushes, so a silent rsync failure here surfaces as a confusing
# error three steps later - or, under a suspended `set -e`, as nothing at all.
af_push_agent_scripts() {
  local host="$1"
  af_ssh "$host" "mkdir -p '$AF_REMOTE_DIR/agent'" \
    || af_die "$host: could not create $AF_REMOTE_DIR/agent - $host is NOT provisioned"
  af_rsync "$host" "$AF_AGENT_DIR/" "$AF_REMOTE_DIR/agent/" \
    || af_die "$host: could not push the agent scripts (rsync) - $host is NOT provisioned"
}

# Quote a value for safe reuse inside a remote command line.
af_shq() {
  printf "'%s'" "$(printf '%s' "${1:-}" | sed "s/'/'\\\\''/g")"
}

# The machine-side scripts are configured entirely through the environment, so
# they stay runnable by hand on the machine itself when something needs poking.
# NAME or NAME=default, in the order the prefix emits them; the first eight are
# ones af_load_config always populates.
af_env_prefix() {
  local spec name val out=""
  for spec in AF_NAME AF_USER AF_HOME AF_WORKDIR AF_AGENT AF_SESSION \
              AF_SWAP_GB AF_SUBAGENT_CAP AF_EARLYOOM_PREFER \
              AF_NODE_VERSION=22 AF_PKG_EXTRA AF_NPM_EXTRA \
              AF_BROWSER=0 AF_TERM_PORT=7681 AF_NOVNC_PORT=6080 \
              AF_CDP_PORT=9222 AF_VNC_BIND AF_STATUS_INTERVAL=15; do
    name="${spec%%=*}"
    eval "val=\${$name:-}"
    case "$spec" in *=*) [ -n "$val" ] || val="${spec#*=}" ;; esac
    out="$out $name=$(af_shq "$val")"
  done
  printf '%s' "${out# }"
}

# The machine-side collector runs without a shell profile, so its settings
# arrive as a plain KEY=value file at the path it already looks in. Writing the
# file rather than baking values into the unit means a new knob in your config
# reaches an existing machine on the next run, with no unit to regenerate.
af_write_agent_env() {
  local host="$1" v val
  af_ssh "$host" "mkdir -p '$AF_HOME/.config/agentfleet'" \
    || af_die "$host: could not create $AF_HOME/.config/agentfleet - $host is NOT provisioned"
  {
    for v in AF_NAME AF_AGENT AF_HOME AF_WORKDIR AF_SESSION \
      AF_STATUS_TRANSCRIPTS AF_STATUS_INTERVAL \
      AF_SUMMARY_PROVIDER AF_SUMMARY_MODEL AF_SUMMARY_URL AF_SUMMARY_KEY_FILE \
      AF_SUMMARY_MIN_INTERVAL AF_COST_PRICES; do
      eval "val=\${$v:-}"
      printf '%s="%s"\n' "$v" "$(printf '%s' "$val" | sed 's/[\\"]/\\&/g')"
    done
  } | af_put_text "$host" "$AF_HOME/.config/agentfleet/agent.env" 644 \
    || af_die "$host: could not write agent.env - the status collector would run on stale settings"
}

af_run_agent_script() {
  local host="$1" script="$2" label="$3"
  af_log "  $label"
  # The output is indented for readability, but the exit status is the point:
  # a hardening run that silently failed produces exactly the machine that
  # freezes itself out of ssh a week later. pipefail makes ssh's status win.
  if ! af_ssh "$host" "$(af_env_prefix) bash '$AF_REMOTE_DIR/agent/$script'" 2>&1 | sed 's/^/    /'; then
    af_die "$label failed on $host (agent/$script) - $host is NOT provisioned"
  fi
}

# ---------------------------------------------------------------- tailnet

af_join_tailnet() {
  local host="$1" keyfile="${AF_TS_AUTHKEY_FILE:-}" remote_key
  if [ "$AF_TAILNET" = off ]; then
    af_log "  tailnet: off (AF_TAILNET=off)"
    return 0
  fi

  if ! af_ssh "$host" 'command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh' >/dev/null 2>&1; then
    af_die "tailscale install failed on $host (set AF_TAILNET=off to run on provider addresses only)"
  fi

  if af_ssh "$host" 'tailscale ip -4 >/dev/null 2>&1'; then
    af_log "  tailnet: already joined"
    return 0
  fi

  if [ -z "$keyfile" ] || [ ! -s "$keyfile" ]; then
    af_warn "no reusable auth key (AF_TS_AUTHKEY_FILE) - finish the join by hand:"
    af_warn "  agentfleet ssh $host -- sudo tailscale up --ssh"
    return 0
  fi

  # The key goes over ssh into a mode-600 file rather than onto a command line,
  # where anyone with a shell on the machine could read it out of ps.
  remote_key="/tmp/$AF_NAME-tsauth.key"
  af_put_text "$host" "$remote_key" 600 <"$keyfile"
  # shellcheck disable=SC2016
  af_ssh "$host" "sudo tailscale up --ssh --hostname=$(af_shq "$host") --auth-key=\"\$(cat '$remote_key')\" >/dev/null 2>&1; rm -f '$remote_key'"

  if ! af_ssh "$host" 'tailscale ip -4' >/dev/null 2>&1; then
    af_die "$host did not get a tailnet address (expired or single-use auth key in $keyfile?)"
  fi
  # Its primary address just changed, so everything cached about it is wrong.
  # shellcheck disable=SC2034  # read by af_host_addr in lib/common.sh
  AF_ADDR_CACHE=""
  af_log "  tailnet: joined"
}

# ---------------------------------------------------------------- sync + hooks

af_sync_host() {
  local host="$1"
  if ! command -v cmd_sync >/dev/null 2>&1; then
    [ -f "$AF_DIR/lib/sync.sh" ] || af_die "lib/sync.sh missing (broken install)"
    # shellcheck source=lib/sync.sh
    . "$AF_DIR/lib/sync.sh"
  fi
  cmd_sync "$host"
}

# Run through a shell so both a bare script path and a short command line work.
#
# Fail closed. A hook exists precisely because the tool cannot know what "ready"
# means for your setup, so a hook that did not pass is not a machine you should
# hand work to. A check that could not run is not a pass.
af_run_hook() {
  local host="$1" hook="${2:-}" kind="$3"
  if [ -z "$hook" ]; then return 0; fi
  af_log "  $kind hook"
  if ! sh -c "$hook \"\$@\"" "agentfleet-$kind-hook" "$host"; then
    af_die "$kind hook failed for $host - $host is NOT provisioned"
  fi
}
