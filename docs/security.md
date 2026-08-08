# Security

agentfleet holds an ssh key to machines that run a coding agent with broad
permissions, it can push credential files to them, and it can serve a web page
that executes commands on all of them. This document says what each of those
means and what to do about it.

The short version: keep the machines off the public internet, keep the dashboard
on a private interface, and treat every machine in the fleet as one trust
boundary. Anything you put on one machine, you have effectively put on all of
them and given to the agent.

---

## The dashboard is remote code execution on the whole fleet

`agentfleet dash` serves a page whose buttons run, on any machine in the
inventory: `say` (type into the live agent session), `run` (start a detached
agent job), `interrupt`, `clear`, `sync`, `provision`, `browser`, `start` and
`stop`. There is no read-only mode. An authenticated request can make an agent
that runs with permission prompts disabled do anything on that machine.

**Authentication.** A password is generated on first run, printed once to the
terminal, and stored mode 0600 at `~/.local/state/agentfleet/dashboard.pw`
(`$XDG_STATE_HOME` is honoured). The session cookie is an HMAC of an expiry
signed with a secret in `dashboard.secret`, so there is no session store to lose
and a login survives a restart. It is `HttpOnly`, `SameSite=Lax`, 30 days, and
`Secure` only when the request actually arrived over TLS - a `Secure` cookie on a
plain-http tailnet address would never be sent back. Password comparison is
timing-safe.

What that authentication is not: there is no rate limiting, no second factor and
no per-action confirmation. It is one shared password in front of the fleet.

**Binding.** `AF_DASH_BIND` defaults to `tailnet`, which is your Tailscale
address: reachable from your phone, not reachable by anyone else. `local` binds
127.0.0.1. Setting it to `0.0.0.0` on a laptop that joins cafe wifi hands the
fleet to the room, with only that one password in the way. Do not do it. If you
want the page on the open internet, put it behind `tailscale funnel`, which
terminates TLS and turns the `Secure` cookie flag on by itself.

**What the page can reach.** Host names are checked against the configured
inventory, session names against `^[A-Za-z0-9_.-]{1,32}$`, and prompts are capped
at 2000 characters, because those values are concatenated into a remote shell
command and those checks are the only thing between a POST body and execution on
the machine. Machine deletion is deliberately absent from the API: stopping keeps
the disk, destroying stays a decision you make at a terminal.

**Do this.** Leave `AF_DASH_BIND` at `tailnet` or set it to `local`. Read the
password off the first run and store it in your password manager. To rotate it,
delete `dashboard.pw` and restart; delete `dashboard.secret` too if you want to
invalidate every existing cookie.

---

## What `AF_SECRETS` actually does, and what it implies

`agentfleet secrets push` reads each file listed in `AF_SECRETS` from your laptop
and writes it to the same `$HOME`-relative path on each machine. That is the
whole feature. There is no vault, no encryption at rest, no reconciliation and no
rotation.

The transfer itself is careful in the ways that matter. Content goes over ssh on
stdin and never in `argv`, where every other process on the box could read it out
of `ps` and where a shell or a CLI might log it. `umask 077` is set before the
file is created, not fixed with `chmod` afterwards, so there is no window where
the cleartext is world readable. It is written to a temporary name and moved into
place, so an interrupted transfer cannot leave a truncated credential behind.
Paths must be `$HOME`-relative, may not contain `..`, and may only use
`[A-Za-z0-9._/-]`. Empty or missing files are refused - overwriting a good copy
with nothing is worse than not running. The whole list is parsed and validated
before anything is sent, because a half-distributed set of credentials is worse
than none. You see the plan and confirm it, unless `AF_YES=1`.

**The trust model this implies.** Plaintext credentials now sit on every machine
you pushed to, readable by the agent, by anything the agent runs, and by anyone
with a shell there. If one machine is compromised, treat every secret on the
fleet as compromised. Scope accordingly: prefer keys that are cheap to rotate and
narrow in what they grant, and never push the credential that can reach your
other credentials.

**Three kinds of file do not belong here**, each for a reason someone has already
paid for.

- **Single-session credentials.** Some protocols bind a session to one client.
  Using the same session from two machines gets it killed on both, and the
  machine that was working stops working. Log each machine in separately with
  `agentfleet login <host> <command>`.
- **Rotating OAuth token files.** Refresh tokens rotate on use, so overwriting a
  machine that just refreshed can invalidate the token family for the entire
  fleet at once.
- **Authorization grants.** An approval granted on one machine must not widen
  authority on the other nine just because a sync ran.

Also note that the same filename can mean different things on different operating
systems: a tool that keeps its token in a config file on Linux may keep it in the
system keychain on your laptop, so pushing one over the other hands the machine a
credential path that is stale by construction.

**Do this.** Push per-service API keys and nothing else. Use
`agentfleet login <host> ...` for anything interactive, which starts the login
command on the machine, forwards the callback port back to it, verifies the
forward works, and only then opens the tab in your browser. Keep it out of
`AF_SYNC_PATHS`: that channel is a blind one-way overwrite on every run, and it
refuses credential-shaped paths for exactly this reason.

---

## The optional browser tunnel

`AF_MAC_CHROME=1` plus `agentfleet browser mac-chrome up <host>` reverse-tunnels
a Chrome DevTools port from your laptop onto a machine.

**Exactly what that grants.** Anything on that machine - your agent, anything
your agent runs, anyone with a shell there - can drive that browser over CDP:
open any page, read and write its cookies, read the DOM of any authenticated
session, and act as you on every site that profile is logged into. There is no
per-request approval and no audit trail.

**What keeps it bounded.** The tunnel is initiated from the laptop, so nothing
listens on the laptop and no port is opened there. With `GatewayPorts` at its
default, it lands only on the machine's loopback interface, so it is not
published to the network - the trust you are extending is to that machine, not to
the internet. It only ever attaches to a dedicated profile under
`~/.cache/agentfleet/chrome-profile`, never your everyday one, so an agent cannot
touch the tabs you are working in. `--remote-allow-origins` is not passed unless
you set `AF_MAC_CHROME_ORIGINS`; setting it to `*` lets any page open in any
browser on your laptop connect to that debug port and drive the logged-in
profile, so name the one origin that needs it or leave it empty.

**Do this.** Leave `AF_MAC_CHROME=0` unless you specifically need automation
against already-authenticated sessions. When you do need it, log that dedicated
profile into only the sites the task needs, bring the tunnel up for one machine
rather than `all`, and run `agentfleet browser mac-chrome down <host>` when the
task is finished. For a login that just needs to be completed once, use
`agentfleet login` instead - it hands you the browser tab and grants the machine
nothing.

---

## Auto-commit is off, and should usually stay off

With `AF_AUTOCOMMIT=1`, every `sync` stages whatever the agent left in the
working tree, commits it, and pushes it to your git remote unattended. That
publishes everything in the tree that `.gitignore` does not exclude, including
files an agent downloaded, generated or pasted, on machines you were not watching
at the time.

There are guards, and you should know their limits. Credential-shaped filenames
(`.env`, `*.pem`, `*.key`, `id_rsa*`, `.netrc`, `.npmrc`, `credentials.json`,
`auth.json` and similar) are unstaged and named in the output - but that is a
name check, not a content scanner, and a secret in `config.yaml` sails straight
through. Files over `AF_MAX_BLOB_MB` are left uncommitted rather than jamming
that machine's push forever. Paths in `AF_REPO_LOCAL_PATHS` are never committed.
`--no-verify` is never passed, so your own pre-commit hooks still run; a hook that
rejects the snapshot blocks that machine and says so, which you can fix, whereas
a silently bypassed hook publishes exactly what it existed to catch.

**Do this.** Leave it at `0` and let agents commit their own work, which is the
default and means only deliberate commits travel home. If you turn it on, run a
real secret scanner as a pre-commit hook on that repo first, and keep the remote
private.

---

## Agents run with wide permissions, by design

`agentfleet run` defaults to `claude -p --permission-mode bypassPermissions` or
`codex exec --dangerously-bypass-approvals-and-sandbox`. Nothing will stop and
ask. That is the point of a detached job on a remote machine: the machine is the
sandbox, and an agent parked on a permission prompt at 3am is a machine doing
nothing.

The consequences follow from that, so plan for them rather than being surprised:

- **One agent machine is single-tenant.** Do not put anyone else's work, data or
  credentials on it. Chromium there runs with `--no-sandbox`, because current
  Ubuntu's AppArmor policy denies the unprivileged user namespaces its sandbox
  needs; that is acceptable on a single-tenant box and nowhere else.
- **The web terminal is a passwordless shell.** `ttyd` runs writable, so anyone
  who can reach `AF_TERM_PORT` gets a shell as `AF_USER`. Provisioning binds it
  to the `tailscale0` interface, or to loopback when the machine has no tailnet,
  in which case you reach it with `ssh -L 7681:localhost:7681 <host>`.
- **noVNC has no password either.** `AF_VNC_BIND` defaults to `0.0.0.0`, which is
  only safe because the machines are meant to be unreachable from the internet.
  Set it to `127.0.0.1` if you would rather tunnel.
- **The clipboard bridge has no authentication.** Anything that can reach
  `AF_CLIP_PORT` on your laptop can read and write your clipboard and ask your
  browser to open a URL (restricted to `http` and `https`, so `file://` and
  `javascript:` cannot turn it into local code execution). It binds to your
  tailnet address and refuses to start without one.
- **Scope any cloud identity you give a machine.** The azure provider grants each
  machine's managed identity `Reader` on one resource group by default. Widen it
  only if the agents genuinely need to change cloud resources.

**Do this.** Keep every machine on a private network. `AF_TAILNET=auto` is the
supported way and it is also what makes an IP-pinned firewall rule survivable.
With `AF_PROVIDER=azure`, leave `AF_AZ_LOCK_SSH=1` so port 22 is narrowed to your
egress IP the moment the machine exists; creation fails rather than leaving it
open if your IP cannot be determined. If you narrow `AF_RUN_CMD` to something
that does prompt, remember that nobody is at the terminal to answer it, and set
`AF_NOTIFY_URL` or watch the dashboard for the `waiting` state.

---

## Two smaller things worth knowing

**The ssh key has no passphrase.** `agentfleet init` generates one that way
because every ssh in the tool runs with `BatchMode=yes` and would otherwise hang
on the prompt. The key is your entire access to the fleet, so it is only as safe
as your laptop's disk encryption. If that trade is wrong for you, point `AF_KEY`
at an agent-backed key instead.

`agentfleet sshconfig` prepends an `Include` line to `~/.ssh/config` (prepends,
because ssh keeps the first value it finds for each keyword) and backs the
original up to `~/.ssh/config.agentfleet-backup` first.

**Provisioning runs vendor install scripts over the network.** nvm is pinned to a
specific tag so an upstream release cannot change what every machine installs on
the same afternoon. The Tailscale and Claude Code installers are fetched from
their vendors' current URLs and are not pinned. If that is not acceptable in your
environment, install those two by hand or from your own mirror in
`AF_PROVISION_HOOK`, and set `AF_TAILNET=off`.
