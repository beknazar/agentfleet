# Writing a provider

A provider answers five questions about machines. Everything else in agentfleet -
provisioning, sync, `ls`, the dashboard, `run`, `attach` - is provider-neutral,
which is why `ssh` (a static host list, no cloud account at all) is a first-class
backend and not a degraded mode.

```
provider_list                 -> one host name per line
provider_addr   <host>        -> an address ssh can reach, or empty + nonzero
provider_create <host> [size] -> make the machine, print its address
provider_start  <host>        -> resume a stopped machine
provider_stop   <host> [--delete]
```

A provider is one file, `providers/<name>.sh`, sourced by `af_provider_load`
after the config is loaded. Everything in `lib/common.sh` is already available to
it: `AF_*` settings, `af_die`, `af_log`, `af_warn`, `af_need`, `af_ssh`,
`af_put_text`, `AF_CACHE`, `AF_KEY`. It runs under `set -euo pipefail` and must
be bash 3.2 compatible, because the control plane runs on the operator's laptop
and that is what ships with macOS: no associative arrays, no `mapfile`, no
`${x^^}`.

**One thing that is not obvious:** `lib/common.sh` validates `AF_PROVIDER`
against a hardcoded list and rejects anything else. Adding `providers/hetzner.sh`
is not enough on its own; you also have to add the name to that `case` in
`af_load_config`. It is a two-line edit and it is easy to miss, because the error
you get otherwise ("unknown provider") reads like the file is missing.

---

## The minimal example: providers/ssh.sh

Forty lines, and it implements the interface completely by declining three
quarters of it.

```sh
provider_list() {
  [ -n "$AF_HOSTS" ] || af_die "AF_HOSTS is empty in $AF_CONFIG - list your machines there ..."
  # Deliberate word splitting: AF_HOSTS is written space- or newline-separated.
  # shellcheck disable=SC2086
  printf '%s\n' $AF_HOSTS
}
```

The inventory is a config variable. Note what it does when empty: it dies with an
instruction, rather than returning nothing. An empty list and a broken backend
must not look the same, because "no machines" renders as a clean empty table and
you will believe it.

```sh
provider_addr() {
  [ -n "${1:-}" ] || return 1
  printf '%s' "$1"
}
```

The name **is** the address. That is the whole idea of this provider: ssh config
aliases, `/etc/hosts`, real DNS and tailnet MagicDNS names all resolve on their
own, so agentfleet does not keep an inventory of addresses that can go stale
behind your back. A cloud provider cannot do this and has to ask its API.

```sh
ssh_no_lifecycle() {
  af_die "provider=ssh does not manage machines, so there is nothing to '$1' for ${2:-this host}.
  Machines in AF_HOSTS are expected to already exist and be reachable over ssh.
  ..."
}

provider_create() { ssh_no_lifecycle create "${1:-}"; }
provider_start()  { ssh_no_lifecycle start  "${1:-}"; }
provider_stop()   { ssh_no_lifecycle stop   "${1:-}"; }
```

Not implementing a verb is legitimate, and the way you decline matters more than
the fact that you did. Someone who typed `agentfleet up` with the default config
needs a sentence telling them what to do next, not a shell trace. `agentfleet
down` and `agentfleet start` also check whether `provider_stop` / `provider_start`
is defined at all, and say so plainly if it is not.

---

## What each function must guarantee

### `provider_list`

One host name per line on stdout, exit 0. Names are used as tmux-adjacent
identifiers, ssh destinations and file names, so keep them to
`[A-Za-z0-9._-]`. Called often - every `ls`, every `sync`, every dashboard
inventory refresh (60 second TTL) - so it should be one API call or less.

Distinguish "no machines yet" from "I could not ask". The azure provider only
treats `ResourceGroupNotFound` as an empty fleet and dies on anything else,
because a broken cloud login that returns zero rows silently produces an empty
dashboard.

### `provider_addr <host>`

Print one address ssh can connect to, or print nothing and return nonzero. It
may be an IPv4, an IPv6 or a name. It must match `^[A-Za-z0-9._:-]{1,255}$` - the
dashboard rejects anything else at boot, in particular anything starting with `-`
that ssh would read as a flag.

Called in loops. `af_host_addr` caches per process and tries the tailnet first,
falling back to this, so a slow implementation costs you once per command rather
than once per host - but it is still worth caching inside your provider if the
API call is expensive.

### `provider_create <host> [size]`

The contract is not "the API returned 200". When this returns 0, all of the
following must be true, or provisioning will fail in a way that looks like
agentfleet's fault:

1. A machine exists with this name, and `provider_addr <host>` resolves to it.
   The address may not be answering yet - `af_wait_ready` polls for up to
   `AF_PROVISION_TIMEOUT` seconds - but it must be the right one and it should be
   stable across a stop/start, because the generated ssh config caches it.
2. `AF_USER` exists on it, `AF_KEY.pub` is in that user's `authorized_keys`, and
   that user has **passwordless sudo**. The readiness probe checks exactly this,
   plus a free dpkg lock, and nothing else.
3. It runs Debian or Ubuntu with `apt`. `agent/bootstrap.sh` says so out loud and
   refuses otherwise.
4. If `AF_HOME` is set, the user's home directory is that exact path. Only a
   provider that creates the account can honour path mirroring; see
   `configuration.md`. The azure provider does it with a cloud-init `homedir:`.
5. ssh is not open to the world, if your platform lets you say so. The azure
   provider resolves your egress IP *before* creating anything and refuses to
   create a machine it cannot then lock, because the create call itself opens
   port 22 to the internet for the second in between.

Print the address on stdout as the last line. Fail nonzero and loudly on
anything you could not do; a machine that half-exists is worse than no machine.

Do not provision anything here. `cmd_up` calls `cmd_provision` immediately
afterwards, and everything the machine needs is installed there, where it is
idempotent and re-runnable.

### `provider_start <host>`

Resume a stopped machine. Returning 0 should mean it is booting; the caller waits
for reachability separately.

Two callers: `agentfleet start <host...|all>` and the dashboard's start button.
`agentfleet up` is not one of them - it calls `provider_create`, which on a
machine that already exists either fails outright or waits out the provision
timeout on a box that is still deallocated. That is why resuming is its own verb.
A provider that does not define `provider_start` gets a plain "this provider does
not manage machine lifecycle" from `agentfleet start`, the same way `down`
handles a missing `provider_stop`.

### `provider_stop <host> [--delete]`

Without `--delete`, stop compute billing and keep the disk and everything on it.
With `--delete`, destroy the machine; `agentfleet down --delete` has already
confirmed with the human before calling you.

Say what you left behind. `az vm delete` removes the VM object only - the disk,
NIC, public IP and NSG are separate resources that keep billing - so the azure
provider prints the command that lists the leftovers. Anyone who has been
surprised by a storage bill after "deleting" ten machines will thank you.

---

## Optional: `provider_status`

Not part of the five, and only the dashboard reads it. Print one line per
machine, tab separated:

```
<host>\t<power>\t<region>\t<size>
```

`power` becomes the machine's on/off state in the UI (`off` is what makes the
`start` button appear). Providers that cannot answer simply do not define the
function, and those columns report unknown rather than a guess. Neither shipped
provider defines it today.

---

## A checklist for a new one

Take Hetzner as the example. `hcloud` gives you all five in one call each.

1. Copy `providers/ssh.sh` to `providers/hetzner.sh` and add `hetzner` to the
   `case "$AF_PROVIDER"` list in `lib/common.sh`.
2. `af_need hcloud` at the top of the file, and set your defaults with
   `: "${AF_HZ_TYPE:=cx42}"` so a config that omits them still loads under
   `set -u`. Document each new variable in `agentfleet.conf.example`; that file
   is what `agentfleet init` installs, so an undocumented setting effectively
   does not exist.
3. `provider_list`: `hcloud server list -o noheader -o columns=name`, with the
   empty-versus-broken distinction above.
4. `provider_addr`: `hcloud server ip "$1"`, returning nonzero when the server is
   not there.
5. `provider_create`: `hcloud server create` with `--ssh-key` pointing at an
   uploaded copy of `$AF_KEY.pub`, and cloud-init `--user-data-from-file` to make
   the `AF_USER` account with passwordless sudo and, if you want path mirroring,
   the right `homedir`. `providers/azure-cloud-init.yaml` is a working template:
   render it with `sed` the way `az_render_cloud_init` does, and check afterwards
   that no `{{PLACEHOLDER}}` survived - one that does means a machine boots
   without your ssh key and you find out twenty minutes later over a connection
   that never opens.
6. `provider_stop`: `hcloud server poweroff`, or `delete` with `--delete`. Note
   in the log line that a powered-off Hetzner server still bills, which is a real
   difference from Azure's deallocate and exactly the kind of thing the operator
   needs told once. `provider_start`: `hcloud server poweron`, which is what
   `agentfleet start` and the dashboard's start button call.
7. Test with the tailnet off first (`AF_TAILNET=off`), so failures are about your
   provider and not about the overlay network.

Then `agentfleet up hz1 && agentfleet ls`. CI runs `shellcheck -x` over
`providers/*.sh`, so keep it clean.
