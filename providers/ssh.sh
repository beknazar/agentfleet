#!/usr/bin/env bash
# provider: ssh - you bring the machines.
#
# The default backend, and deliberately the one that needs no cloud account.
# Everything above this file (sync, dashboard, run, attach) is provider-neutral,
# so a rented dedicated box, a spare workstation and an instance you clicked
# together in some console all behave identically once they are in AF_HOSTS.
#
# Sourced by af_provider_load, so AF_* and af_* are already available here.

provider_list() {
  [ -n "$AF_HOSTS" ] || af_die "AF_HOSTS is empty in $AF_CONFIG - list your machines there (AF_HOSTS=\"w1 w2 w3\"), or set AF_PROVIDER to a backend that creates them"
  # Deliberate word splitting: AF_HOSTS is written space- or newline-separated.
  # shellcheck disable=SC2086
  printf '%s\n' $AF_HOSTS
}

# The name IS the address. That is the point of this provider: ~/.ssh/config
# aliases, /etc/hosts, real DNS and tailnet MagicDNS names all resolve on their
# own, so agentfleet does not have to keep an inventory of addresses that can go
# stale behind your back.
provider_addr() {
  [ -n "${1:-}" ] || return 1
  printf '%s' "$1"
}

# One message for all three lifecycle verbs. Someone who typed `agentfleet up`
# with the default config needs to know what to do next, not a shell trace.
ssh_no_lifecycle() {
  af_die "provider=ssh does not manage machines, so there is nothing to '$1' for ${2:-this host}.
  Machines in AF_HOSTS are expected to already exist and be reachable over ssh.
  Do that yourself, or switch AF_PROVIDER to a cloud backend that owns the
  machine lifecycle (see the azure section of agentfleet.conf.example) and re-run.
  Everything else - provision, sync, run, ls, dash - works on machines you bring."
}

provider_create() { ssh_no_lifecycle create "${1:-}"; }
provider_start()  { ssh_no_lifecycle start  "${1:-}"; }
provider_stop()   { ssh_no_lifecycle stop   "${1:-}"; }
