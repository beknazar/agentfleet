# Configuration

Every setting lives in one file, which is plain shell and gets sourced. Search
order, first hit wins:

1. `$AGENTFLEET_CONFIG`, if set
2. `./agentfleet.conf` in the current directory
3. `~/.config/agentfleet/config`

A repo-local `agentfleet.conf` beating the global one is deliberate: you can keep
a throwaway fleet next to a project without disturbing your main config.
`agentfleet init` writes `agentfleet.conf.example` to option 3 and never
overwrites a file that exists.

Because the file is shell, you can compute values in it. Nothing in it is secret:
keys and tokens are referenced by path, never stored here.

Below, "default" means the value you get when the setting is absent or empty.
Some defaults come from `lib/common.sh`, some from the command that reads the
setting; where that matters it is called out.

---

## The basics

### `AF_NAME`
Default `agentfleet`. Names the fleet, and is used to derive the ssh key path
(`~/.ssh/$AF_NAME`), the generated ssh config (`~/.ssh/$AF_NAME.conf`), the
systemd user unit prefix on each machine (`$AF_NAME-status`, `$AF_NAME-cost`,
`$AF_NAME-ttyd`, `$AF_NAME-browser`, `$AF_NAME-clipboard`), and the profile
drop-ins it writes
(`/etc/profile.d/$AF_NAME-path.sh`, `/etc/profile.d/$AF_NAME-agent.sh`). Change
it if you run two independent fleets from one laptop, and change it before you
provision anything: renaming later orphans the units on every machine.

### `AF_PROVIDER`
Default `ssh`. Either `ssh` (you bring the machines, listed in `AF_HOSTS`) or
`azure` (agentfleet creates and destroys them). Anything else is rejected at
load. Adding your own is `docs/providers.md`.

### `AF_HOSTS`
Default empty. `AF_PROVIDER=ssh` only: the machines, space or newline separated.
These names are the host names you use everywhere (`agentfleet say w1 ...`) and
they are also handed to `ssh` verbatim as the destination, so each must resolve
on its own - DNS, a tailnet name, `/etc/hosts`, or a `Host` block in
`~/.ssh/config`. With `AF_PROVIDER=azure` this is ignored; the provider lists the
machines instead.

Pointing a name at an ssh alias you already have works because `agentfleet
sshconfig` reads `~/.ssh/config` first and skips writing its own block for any
name you declared there - otherwise agentfleet's `Include`, which is *prepended*
so it beats wildcard blocks, would override your alias with `HostName <name>` and
your machine would stop resolving. It says which names it kept. Two limits: only
exact literal names count (a pattern block like `Host web-*` is meant to be
beaten, so it is), and only the top-level `~/.ssh/config` is read, not files it
`Include`s. If your alias lives in an included file, either move that `Host` line
into the main file or give the machine a different name in `AF_HOSTS`.

### `AF_USER`
Default: your local `$USER` (the shipped example sets `ubuntu`). The login user
on every machine. It needs passwordless sudo there.

### `AF_KEY`
Default `~/.ssh/$AF_NAME`. Private key used for every ssh, scp and rsync. Every
connection runs with `BatchMode=yes`, so a passphrase-protected key hangs unless
it is already loaded in an agent. `agentfleet init` generates an ed25519 pair
with no passphrase; point this elsewhere if you would rather use an
agent-backed key.

---

## The agent

### `AF_AGENT`
Default `claude`. Which coding agent the machines run. `claude` or `codex` for
normal use; the machine bootstrap also accepts `both` (installs both CLIs) and
`none` (installs neither), but the status collector picks one transcript format
and `agentfleet run` has no default command for `both`, so with either of those
you must also set `AF_STATUS_TRANSCRIPTS` and `AF_RUN_CMD` yourself.

This one setting drives three things: which CLI gets installed, which transcript
layout the status collector parses, and which on-screen patterns it matches to
spot a permission prompt or an expired login.

### `AF_STATUS_TRANSCRIPTS`
Default empty, meaning the standard layout for `AF_AGENT`
(`~/.claude/projects/**/*.jsonl` or `~/.codex/sessions/**/*.jsonl`). A glob,
evaluated on the machine, newest match by mtime wins - so a session started in
any directory is visible, not just one repo. Set it if your agent writes
transcripts somewhere else.

### `AF_WORKDIR`
Default `$AF_HOME/work`, and the shipped example leaves it empty so it follows
`AF_USER` and `AF_HOME` without you having to remember it. Where the agent works:
`attach`, `run` and the web terminal all start there, `AF_REPO` is cloned there,
and the dashboard reads its git ahead/behind/dirty counts from it. Set it only to
put the work tree somewhere other than `~/work`.

### `AF_REPO`
Default empty. A git URL cloned into `AF_WORKDIR` on provision and kept in sync
afterwards. Empty means `sync` does the config leg only and says so.

### `AF_REPO_BRANCH`
Default `main`. The branch every machine converges on. A machine checked out on
anything else is skipped by `sync` entirely and left alone, so parking one on a
job branch is supported rather than something the tool will undo behind you.

### `AF_SESSION`
Default `main`. The tmux session the interactive agent lives in. `attach`, `say`
and the web terminal target it; `run` creates its own session instead.

### `AF_RUN_CMD`
Default empty, meaning the built-in default for `AF_AGENT`:

- `claude` -> `claude -p --permission-mode bypassPermissions`
- `codex` -> `codex exec --dangerously-bypass-approvals-and-sandbox`

Both hand the agent full autonomy on the machine, on the assumption that the
machine is the sandbox. The prompt is appended as one argument. Set this to
something narrower if that assumption does not hold for you.

---

## Path mirroring

### `AF_HOME`
Default `/home/$AF_USER`. This is the least obvious setting here and the most
useful one.

Set it to **your laptop's home directory path**, and a cloud provider that
creates the machine's user will give that user exactly that home directory. Then
an absolute path means the same thing on both sides.

Worked example. Your laptop home is `/Users/you`. Your agent config is full of
absolute paths - a hook at `/Users/you/.claude/hooks/pre-commit.sh`, a skill that
reads `/Users/you/notes/style.md`, a `settings.json` pointing at
`/Users/you/bin/lint`. Without mirroring, the remote user's home is
`/home/ubuntu`, every one of those paths is dead on the machine, and syncing the
config means rewriting them - forever, on every change. With:

```sh
AF_HOME="/Users/you"
AF_WORKDIR="/Users/you/work"     # or leave AF_WORKDIR empty and let it derive
AF_SYNC_PATHS="
.claude/CLAUDE.md
.claude/agents
.claude/skills
"
```

the remote user's home is `/Users/you`, `rsync` puts the same tree at the same
absolute path, and every one of those references resolves on both machines with
no translation layer at all.

Two constraints come with it. First, only a provider that creates the user can
apply it: the azure cloud-init sets `homedir:` at first boot. With
`AF_PROVIDER=ssh` nothing creates the account, so `AF_HOME` must already match
the real home of `AF_USER` on those machines, or every remote path agentfleet
computes lands somewhere that does not exist. Second, no strictly confined snaps
on a mirrored machine: their AppArmor profiles cannot read a home outside
`/home`, so the snap installs cleanly and then cannot see one file the agent
owns. The provisioner uses apt and vendor installers for exactly this reason.

---

## Syncing

### `AF_SYNC_PATHS`
Default empty. Paths pushed laptop to machine on `agentfleet sync`, one per line,
relative to `$HOME` on both ends. This is how your agent's config, skills,
commands and prompts reach every machine.

One way, and a blind overwrite of whatever the machine has, which is why two
kinds of path are refused outright rather than discovered after ten machines are
flattened: credential stores and credential-shaped filenames (`.ssh`, `.aws`,
`.gnupg`, `.config/gcloud`, `.env*`, `*.pem`, `*.key`, `id_rsa*`, `.netrc`,
`.npmrc`, `auth.json`, `credentials.json`, and friends - use `AF_SECRETS`), and
files that mix shared config with per-machine state (`.claude.json`,
`*.local.json` - sync the directories around them instead). Absolute paths and
`..` are rejected. `.git` and `node_modules` are excluded, and `--delete` is
never passed: a stale file on a machine is a nuisance, deleting one the machine
legitimately owns is data loss, and this side cannot tell which is which.

Change detection is a hash of name, size and mtime across the whole surface,
stamped per machine after a clean run, so the common no-op sync costs one local
`find` and no network walk. That is what makes it safe to put on a timer.

### `AF_SECRETS`
Default empty. Files distributed by `agentfleet secrets push`, one `name|path`
per line, path relative to `$HOME` on both ends (a bare path works, the name is
then the basename). Never carried by `sync`. Read
[security.md](security.md) before using it.

### `AF_SYNC_HEALTHCHECK`
Default empty. A command run on each machine right after a config push, which
must exit 0. Pushing config is exactly the operation that can break the thing it
configures, so it is worth making the machine prove it still works; a failure is
reported loudly and the machine is not stamped, so the next run retries instead
of considering it done. Something like `claude --version` is enough to start.

### `AF_REQUIRED_ENV`
Default empty. Space-separated variable *names* (not values) that must be
non-empty in the agent's login shell, checked after every config push. Worth
setting whenever `AF_SYNC_PATHS` includes shell startup files: one bad push can
strip the API key the agent authenticates with, and the only symptom is every
agent quietly asking you to log in again.

### `AF_AUTOCOMMIT`
Default `0`. When `1`, `sync` commits whatever an agent left in the working tree
and pushes it, unattended, on every run. Off by default and worth thinking about:
it publishes everything `.gitignore` does not exclude, including files an agent
downloaded or wrote. Credential-shaped filenames are unstaged and named rather
than committed, oversized files are left behind, and `--no-verify` is never
passed so your pre-commit hooks still run - but `.gitignore` and those hooks are
the only guards. With it off, only work an agent committed itself travels home.

### `AF_REPO_LOCAL_PATHS`
Default empty. Tracked files you rewrite per machine, repo-relative, one per line
or space separated. They are never auto-committed, so a per-machine rewrite
cannot travel home and ten machines cannot fight over one file.

### `AF_MAX_BLOB_MB`
Default `90`. Files larger than this are left uncommitted with a warning instead
of being staged. One oversized artifact dropped by an agent otherwise blocks that
machine's push forever, and hosted git remotes reject pushes carrying blobs over
100MB.

---

## Status collector

These travel to the machines as `~/.config/agentfleet/agent.env` during
provisioning, and are read by `agent/af-status.py` running behind a systemd
timer. It writes `~/.cache/agentfleet/status.json`, which is what makes a
ten-machine page cheap: the dashboard reads files, it never makes the machines
think.

**Only `agentfleet provision` writes that file.** `agentfleet sync` does not
touch it, and `AF_STATUS_INTERVAL` is additionally baked into the systemd timer,
so after changing anything in this section re-run
`agentfleet provision <host|all>` - which is idempotent and safe on a machine
that is already built - rather than `sync`.

### `AF_STATUS_INTERVAL`
Default `15` seconds. The collector timer period, and therefore the resolution of
the whole dashboard: nothing can be fresher than this. Keep
`AF_SUMMARY_MIN_INTERVAL` above it (not merely equal to it), or every tick
calls the model.

### `AF_SUMMARY_PROVIDER`
Default `none`. Optional one-line prose summary of what each agent is doing,
written by a small model. `none`, `anthropic` (Messages API), or `openai` (any
OpenAI-compatible `/chat/completions` endpoint).

This is a garnish, not the mechanism. State, whether a machine needs you, and
what is still running are all computed deterministically from the transcript and
the screen; the model is never asked what state a machine is in, because a
hallucinated `waiting_for_human` pages you for nothing and a hallucinated `done`
strands a machine that is blocked. With `none` the deterministic fallback fills
the summary line from the session title, the last prompt or the last message.

### `AF_SUMMARY_MODEL`, `AF_SUMMARY_URL`
Default empty, meaning the provider's small-and-cheap default
(`claude-haiku-4-5` at `api.anthropic.com/v1/messages`, or `gpt-4o-mini` at
`api.openai.com/v1/chat/completions`). Set `AF_SUMMARY_URL` to point at a local
or proxied endpoint.

### `AF_SUMMARY_KEY_FILE`
Default empty. Path **on the machine** to a file containing the API key - a path,
never the key itself. Empty falls back to the provider's usual environment
variable (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`) in the agent's environment. Get
the file there with `agentfleet secrets push`.

### `AF_SUMMARY_MIN_INTERVAL`
Default `60` seconds. Minimum time between model calls per machine. The
summarizer is called only when the transcript actually changed and never by the
dashboard's request path, so an idle machine costs nothing. Raise it to spend
less.

### `AF_COST_PRICES`
Default empty. Path on the machine to a JSON file overriding the built-in token
price table used by `agent/af-cost.py`; see the comment at the top of that file
for the shape. The built-in numbers are a static estimate and they drift, and the
`TODAY` column says so.

`agent/services.sh` gives `af-cost.py` its own timer, `$AF_NAME-cost.timer`,
running every 300 seconds - slower than the status collector on purpose, because
pricing a day of transcripts is a full scan and the number moves in cents, not in
seconds. Unlike the status collector, `af-cost.py` reads only the process
environment, never `agent.env` itself, so that unit carries an
`EnvironmentFile=-~/.config/agentfleet/agent.env` line to get `AF_COST_PRICES`
to it. To check it by hand:
`agentfleet ssh w1 -- python3 ~/.agentfleet/agent/af-cost.py`.

---

## Machine toolchain

What `agentfleet provision` installs. The core (tmux, git, ripgrep, jq, python3,
node, ttyd, your agent CLI) is not configurable because the rest of the tool
assumes it; these add to it.

### `AF_PROVISION_TIMEOUT`
Default `1200` seconds. How long to wait for a freshly created machine to become
usable. Generous on purpose: several first boots at once hammer the same package
mirror, and giving up early just means giving up on a machine that was about to
work. Readiness is probed as a capability - the user exists, sudo works, the
dpkg lock is free - and deliberately not as cloud-init's own status, which
reports "running" forever behind one stalled download.

### `AF_NODE_VERSION`
Default `22`. Installed via nvm and symlinked into `/usr/local/bin` so systemd
units and `ssh host <cmd>` can find it, neither of which reads a login profile.

### `AF_PKG_EXTRA`, `AF_NPM_EXTRA`
Default empty. Extra apt packages and extra npm globals, space separated. Your
toolchain goes here.

---

## Networking

### `AF_TAILNET`
Default `auto`: prefer a Tailscale address for every machine, fall back to the
provider's. `off` always uses the provider address and skips the Tailscale
install during provisioning.

Strongly recommended at `auto`. A cloud firewall pinned to your current public IP
stops answering the moment you change wifi, and every machine goes unreachable
while being perfectly healthy. A tailnet address does not care what your egress
IP is.

### `AF_TS_AUTHKEY_FILE`
Default empty. Path on your laptop to a file holding a **reusable** Tailscale
auth key. With it, provisioning joins each machine with no clicks; without it,
provisioning warns and tells you to finish the join by hand. The file is read on
the laptop and sent over ssh into a mode-600 file, never onto a command line
where `ps` could read it.

### `AF_DASH_PORT`
Default `8788`. Port for `agentfleet dash` on your laptop.

### `AF_DASH_BIND`
Default `tailnet`. What the dashboard listens on: `tailnet` (your Tailscale
address, so your phone can reach it and nothing else can), `local` (127.0.0.1),
or an explicit address. Every authenticated request can type into a live agent
session, so this port is remote code execution on the whole fleet with one
password in front of it. Do not set it to `0.0.0.0`. See
[security.md](security.md).

### `AF_PROBE_TIMEOUT`
Default `8` seconds. How long `agentfleet ls` gives one machine to answer before
printing it as unreachable, and the connect budget the dashboard's probes use.
Machines are probed in parallel, so this is the longest the table can take.

### `AF_TERM_PORT`
Default `7681`. The web terminal (ttyd) port on each machine, and the port the
dashboard's per-row `term` link points at. Set it empty to stop offering the
link; the terminal still runs, on 7681.

`ttyd` runs writable, so anyone who can reach that port has a shell as `AF_USER`
with no password. `agent/services.sh` therefore binds it to the `tailscale0`
interface, or to loopback when the machine has no tailnet - in which case you
reach it with `ssh -L 7681:localhost:7681 w1`.

The dashboard's other per-row link, `screen`, points at `AF_NOVNC_PORT` in the
browser section below. Both links open in **your** browser, so they only resolve
from a network that can reach the machine directly. A tailnet can; the public
internet should not.

---

## Dashboard

Read only by `agentfleet dash`.

### `AF_DASH_SERVICES`
Default empty. Health checks rendered as the status dots on each row, one
`key|check` per line, where check is `unit:<systemd-user-unit>` or `port:<n>`
(does anything answer HTTP there):

```sh
AF_DASH_SERVICES="
ttyd|port:7681
myworker|unit:my-worker
"
```

Only services listed here can raise an alarm. An unlisted one reports "not
configured" rather than a permanently red dot, and a check that could not run is
never counted as a pass. Empty means "watch the optional modules this config
turned on": the web terminal, plus the browser ports if `AF_BROWSER` or
`AF_MAC_CHROME` is set. A malformed entry is a boot-time error, not a silently
skipped check.

### `AF_DASH_STALL_SEC`
Default `900` seconds. How long a machine may have work in flight without its
transcript moving before the dashboard calls it stalled. A background shell or a
running subagent is healthy work, not a problem; flagging those on sight puts
every busy machine in the "needs you" list and makes the count worthless.
Stopped moving is the signal.

### `AF_DASH_MEM_PCT`
Default `88`. Memory use percentage that counts as trouble. Suits a machine with
tens of GB running several subagents; lower it on small machines.

Not settings, but worth knowing because they are the two things people go looking
for a knob for:

- **Where the caches live.** Each machine's collector writes
  `~/.cache/agentfleet/status.json` and `~/.cache/agentfleet/cost.json`, and both
  `ls` and the dashboard read exactly those paths. They are fixed on all four
  sides deliberately: a reader path that could drift from the writer's produced
  a fleet that rendered on the web page while `ls` said "no status cache yet" for
  every machine. (`AF_STATUS_OUT` in the environment can move the writer for a
  single hand-run, for debugging.)
- **How "the agent is mid-turn" is recognised** on the tmux screen: the regex
  `esc to interrupt|tokens`, in `dashboard/server.mjs` and in
  `agent/af-status.py`'s per-agent adapters. That wording belongs to the agent
  CLI and does change, but it has to be changed in both places at once, so it is
  a constant in each rather than a setting that could only ever fix half of it.
  If every machine suddenly looks idle after an agent CLI upgrade, that pair is
  what to look at.

---

## Hardening

### `AF_SWAP_GB`
Default `16`. Swapfile size created on each machine, with `vm.swappiness=10` so
the kernel reclaims page cache before swapping out the agent's working set. `0`
disables it; an explicitly empty value means "match this machine's RAM, capped at
32GB". A machine that already has swap on is left alone. Cloud images ship with no swap at all, which is what makes the
out-of-memory failure so abrupt: the machine is fine, and then it is gone and you
cannot ssh in to find out why. Swap turns a hard wall into slow, and slow you can
log into.

### `AF_SUBAGENT_CAP`
Default empty, which does **not** mean "skip" (the shipped example says so too) -
the machine computes a cap from
its own RAM instead, roughly one subagent per 3GB with a floor of 2, and a tool
concurrency limit at 1.5x that with a floor of 4. Written to
`/etc/profile.d/$AF_NAME-agent.sh` and sourced from `~/.zshenv` and `~/.bashrc`,
because the shells that actually run agents are the ones tmux spawns, not login
shells. The machine writing this itself is the point: a fan-out setting tuned on
a 64GB laptop will be synced down to a 16GB machine and freeze it.

### `AF_EARLYOOM_PREFER`
Default empty, meaning
`(^|/)(node|claude|codex|chrome|chromium|python3|vitest|esbuild)$` - the runtimes
an agent spawns, which are both the biggest and the cheapest to restart. Must
contain no whitespace: systemd splits this into the unit's arguments without
re-parsing quotes, and a pattern with a space silently becomes two broken ones
(this is checked, and a bad value falls back to the default). sshd, systemd, the
tmux server and the session bus are never targeted, and that list is not
configurable, because killing one of those loses you the machine instead of the
job.

---

## Hooks

### `AF_PROVISION_HOOK`
Default empty. Run on your laptop after provisioning a machine, with the host
name as `$1`. Run through `sh -c`, so both a script path and a short command line
work. Use it for whatever your setup needs that agentfleet should not know about.

### `AF_READY_HOOK`
Default empty. Same signature, run last. A machine is not "ready" until this
exits 0, and provisioning fails loudly if it does not - a half-configured agent
machine is worse than an obviously broken one.

### `AF_NOTIFY_URL`
Default empty. URL a machine POSTs to when an `agentfleet run` job finishes, body
`agentfleet: <host>/<session> finished rc=N`. Baked into the job script at write
time and omitted entirely when unset, so a machine never carries a half-written
curl to nowhere.

---

## Browser module

Read by `agentfleet browser`, which starts or repairs a real browser on a
machine: Xvfb, Chromium with a debugging port your agent drives, x11vnc, and
noVNC so you can watch it and take the mouse when it gets stuck.

### `AF_BROWSER`
Default `0`. `1` installs the browser packages during provisioning and keeps the
whole stack running as a systemd user unit, so it survives a stop/start like
everything else. Off by default: it is a few hundred MB and most fleets never
open it. With it off, `agentfleet browser <host>` still installs and starts the
stack on demand.

### `AF_CDP_PORT`
Default `9222`. The machine's Chromium DevTools port, on loopback. `af-open` on
the machine drives it.

### `AF_NOVNC_PORT`
Default `6080`. The noVNC web port you open in your own browser, at
`http://<host>:6080/vnc.html`, and the port the dashboard's per-row `screen` link
points at. Set it empty to stop offering that link; the listener still runs, on
6080.

### `AF_VNC_BIND`
Default empty, which resolves to your tailnet address, or to `127.0.0.1` when
there is none. Interface websockify binds the noVNC endpoint to. There is no
password on it, so this is only safe while the machines are unreachable from the
internet, which is what `AF_TAILNET=auto` gives you. Set `127.0.0.1` to require
an ssh tunnel instead. (The raw VNC port underneath is always loopback-only.)

Note that `agent/services.sh` refuses a wildcard bind (`0.0.0.0`, `::`, `*`) for
the *provisioned* stack and falls back to the tailnet address, or loopback if
there is none - the desktop has no password and a wildcard would publish it on
the machine's public IP too. Set a specific address to serve somewhere else on
purpose. The Xvfb geometry behind it is a constant, `1600x1000x24`; noVNC scales
the desktop to whatever window you open it in.

---

## Laptop browser tunnel

### `AF_MAC_CHROME`
Default `0`, and think before turning it on. With it enabled,
`agentfleet browser mac-chrome up <host>` reverse-tunnels a DevTools port from
your laptop onto a machine. Anything on that machine can then drive that browser:
read and write its cookies and act as you on every site it is logged into. What
it buys is automation against real, already authenticated sessions without
logging in from a datacenter IP and tripping 2FA on every machine. It stays
bounded because the tunnel is initiated from the laptop - nothing listens on the
laptop - and lands only on the machine's loopback interface. See
[security.md](security.md).

### `AF_MAC_CHROME_PORT`
Default `9223`. Loopback port the tunnel lands on, on the machine. `af-open -m`
uses it.

### `AF_MAC_CHROME_LOCAL_PORT`
Default `9333`. Debug port of the dedicated browser profile on your laptop. This
is a separate profile, never your everyday one: current Chrome refuses the debug
port on the default profile and only lets you attach through a consent dialog
every time, and a separate profile also means an agent cannot touch the tabs you
are working in. Log in inside that window once; it persists.

### `AF_CHROME_BIN`
Default empty, meaning "find Chrome or Chromium" in the usual macOS application
paths and then on `PATH`.

### `AF_MAC_CHROME_ORIGINS`
Default empty. Value for `--remote-allow-origins` on that profile. Leave empty
unless a specific CDP client demands it, and then name that exact origin: with
`*`, any page open in any browser on your laptop can connect to the debug port
and drive the logged-in profile.

---

## Drop and clipboard

`agentfleet drop` copies a file into `$AF_HOME/drop` on each machine and prints -
and copies to your clipboard - the path that works there. A path you paste into a
remote agent session points at your laptop's filesystem, so the agent cannot read
it. The inbox directory itself is fixed, so the path `drop` prints is the same on
every machine in the fleet.

### `AF_DROP_SRC`
Default `$HOME/Screenshots`. Where `agentfleet drop` with no argument looks for
the newest file. Point it at wherever your screenshots land.

### `AF_CLIP_HOST`, `AF_CLIP_PORT`
Defaults empty and `8899`. The optional clipboard bridge (`agent/clipboard.sh`):
text copied inside a remote tmux lands on your laptop's clipboard, and `af-open
-l <url>` on a machine opens a URL in your real browser. `AF_CLIP_HOST` is how
the machines reach your laptop - a tailnet name or address. Empty disables the
whole thing.

The bridge is not wired into an `agentfleet` subcommand. Run it yourself on the
laptop with `agent/clipboard.sh bridge`, and install the machine half with
`agentfleet ssh w1 -- AF_CLIP_HOST=... bash ~/.agentfleet/agent/clipboard.sh install`.

### `AF_CLIP_BIND`
Default empty, meaning the laptop's tailnet address; the bridge refuses to start
if there is no tailnet rather than falling back to something public. Read only by
`agent/clipboard.sh`. The bridge has no authentication: anything that can reach
the port can read and write your clipboard and open URLs in your browser.

---

## Azure

Read only when `AF_PROVIDER=azure`.

### `AF_AZ_GROUP`
Default `$AF_NAME` (the shipped example sets `agentfleet`). The resource group.
`provider_list` lists the machines in it, so this group defines the fleet.

### `AF_AZ_REGION`
Default `westus2`. Passed explicitly at create time, so a machine does not have
to live in its group's region - which is the trick that gets you past a
per-region CPU quota without a second group.

### `AF_AZ_SIZE`
Default `Standard_D8as_v5`. Overridable per machine: `agentfleet up w1 <size>`.

### `AF_AZ_IMAGE`
Default `Canonical:ubuntu-24_04-lts:server:latest`. The provisioner assumes
Debian or Ubuntu with apt.

### `AF_AZ_DISK_GB`
Default `200`. OS disk size. Note that a deallocated machine keeps paying for
this; that is the trade `agentfleet down` makes.

### `AF_AZ_LOCK_SSH`
Default `1`. Narrow the ssh firewall rule to your current public IP right after
create. Azure opens port 22 to the entire internet during create, so a machine
that cannot be locked is a machine agentfleet refuses to create. Set `0` to
accept an open port.

Note: the rule points at the IP you had at create time. Re-point it at your
current one with `agentfleet unlock [host...]` (no arguments means every machine)
after changing networks. With `AF_TAILNET=auto` you rarely need it, because ssh
goes over the tailnet anyway.

### `AF_AZ_IP_URL`
Default `https://api.ipify.org`. Where to ask what your current public IP is, for
that rule. Any service that answers with a bare address works. Creation fails
rather than leaving a machine open to the internet if this cannot be reached.

### `AF_AZ_IDENTITY_ROLE`
Default `Reader`, scoped to `AF_AZ_GROUP` only. The role granted to each
machine's managed identity, which is what lets `az login --identity` work on the
machine with no interactive login. Widen it to `Contributor` only if your agents
actually need to change cloud resources. Granting it needs Owner or User Access
Administrator on your side; if it fails, the machine still boots and the warning
says so.

Each machine also gets **your laptop's timezone**, read from `/etc/localtime` and
applied by cloud-init at create time, so an agent's timestamps match your clock.
Not a setting: matching your clock is the whole point of it. `UTC` is the
fallback when `/etc/localtime` is not a symlink into the zoneinfo tree.

---

## Environment variables

Not config-file settings; these are read from the environment at run time.

| Variable | Effect |
| --- | --- |
| `AGENTFLEET_CONFIG` | Config file path, beats both default locations |
| `AF_YES` | `1` answers every confirmation prompt yes (the dashboard sets it for its own child commands) |
| `AF_ANY_HOST` | `1` lets a command target a machine that is not in `AF_HOSTS` and that the provider does not list. Named in the error you get without it |
| `AF_SSH_TIMEOUT` | ssh `ConnectTimeout` in seconds, default `15` |
| `AF_PROVISION_GRACE` | Seconds at the start of `provision` during which an otherwise-fatal ssh error (name does not resolve, key refused) is still treated as "keep waiting". `provider=ssh` only, default `60` |
| `AF_DIR` | Set by the entrypoint to the checkout root; the dashboard reads it |
| `AF_ENV_FILE` | On a machine: where `af-status.py` reads its settings, default `~/.config/agentfleet/agent.env` |
| `AF_CACHE_DIR` | On a machine: cache directory, default `~/.cache/agentfleet` |
| `AF_STATUS_OUT` | On a machine: full path `af-status.py` writes, wins over `AF_CACHE_DIR` |
| `AF_SUMMARY_API_KEY` | On a machine: last-resort summarizer key if no key file and no provider env var |
| `AF_BROWSER_DISPLAY` | On a machine: X display for the stack `agentfleet browser` starts on demand, default `:99`. The provisioned unit (`AF_BROWSER=1`) always uses `:99` |

Settings from `agent.env` can also be overridden per invocation through the
environment, which is what makes the machine-side scripts debuggable by hand.
