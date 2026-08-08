#!/usr/bin/env node
// agentfleet dashboard - one screen for every machine, and the buttons to act on them.
//
// Runs on YOUR LAPTOP because that is where the ssh key, the cloud login and the
// tailnet live. A PaaS deploy cannot replace this: the control plane has to sit
// where it can already reach the machines. For phone access, expose this same
// server over your tailnet (or `tailscale funnel` for a public HTTPS URL) - the
// password below is what makes that safe.
//
//   node dashboard/server.mjs      -> http://<your-tailnet-ip>:8788
//
// SECURITY, read this before changing AF_DASH_BIND: every authenticated request
// can type into a live agent session and run fleet commands, so this port is
// remote code execution on every machine in the fleet. Binding it to 0.0.0.0
// hands that to anyone who can reach the port, and the only thing between them
// and the fleet is one password. Bind to the tailnet (default) or to localhost.
//
// Probes run in parallel with hard timeouts: one wedged machine must never stall
// the page. A box that had run itself out of memory once sat at zero bytes free
// for half an hour, and every serial tool that touched it hung with it.
//
// Zero npm dependencies, on purpose: no install step and no supply chain.
//
// ---------------------------------------------------------------------------
// CONTRACT: ~/.cache/agentfleet/status.json on each machine
//
// This file is the plugin point. Anything that can write JSON on a timer can
// drive the "what is it doing / does it need me" half of the dashboard - the
// reference implementation is an agent summarizing its own transcript.
//
//   {
//     "summary": "Rewiring the probe to read the summary cache",  // one line
//     "state":   "working",       // working | waiting_for_human | blocked
//                                 // | error | idle | done | unknown
//     "needs":   "",              // what it needs from you, "" if nothing
//     "task":    "extend the dashboard server",   // the standing ask
//     "tool":    "Edit",          // last tool used
//     "idleSec": 12,              // seconds since the transcript last moved
//     "at": "2026-01-01T19:04:11Z",
//
//     // work in flight, scraped from the tmux screen (it exists nowhere else)
//     "shells":   1,                                  // background shells alive
//     "tasks":    { "done": 1, "inProgress": 1, "open": 2 },
//     "agents":   { "running": 0, "finished": 1, "names": ["research lens"] },
//     "activity": "1 shell running, 1 task in progress"   // print verbatim
//   }
//
// Every field is optional; missing ones read as "" / 0 / "unknown", and a
// machine with no summarizer at all still renders (summarySource says which of
// cache / unparsable / none you are looking at).
// ---------------------------------------------------------------------------
import { createServer } from 'node:http'
import { execFile } from 'node:child_process'
import { readFile, writeFile, mkdir, rename, unlink } from 'node:fs/promises'
import { randomBytes, createHmac, timingSafeEqual } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const DIR = dirname(fileURLToPath(import.meta.url))
const ROOT = process.env.AF_DIR || dirname(DIR)
const CLI = join(ROOT, 'agentfleet')
const HOME = process.env.HOME || ''

const US = '\x1f', RS = '\x1e'   // field / record separators inside the probe payload
const SESSION_RE = /^[A-Za-z0-9_.-]{1,32}$/
const ADDR_RE = /^[A-Za-z0-9._:-]{1,255}$/   // never let an address start with "-" and become an ssh flag
const SERVICE_KEY_RE = /^[A-Za-z0-9_]{1,24}$/
const UNIT_RE = /^[A-Za-z0-9@._-]{1,64}$/
const MAX_PROMPT = 2000

// Everything time- or threshold-shaped lives here and is served at /api/meta, so
// the client polls in step with the cache instead of guessing at it.
const TUNING = {
  fleetCacheMs: 7000,      // page is served from cache; client polls a little slower
  sessionCacheMs: 5000,
  probeTimeoutMs: 25000,   // hard ceiling per machine, the anti-wedge guarantee
  pollMs: 9000,
  sessionPollMs: 6000,
  staleMs: 26000,
  inventoryTtlMs: 60000,   // re-ask the provider which machines exist
  maxPrompt: MAX_PROMPT,
  transcriptEntries: 40,
  jobsKept: 200,
  stallSec: 900,           // overridden from config at boot
  memWarnPct: 88,
}

const sh = (cmd, args, ms = 20000, env = null) => new Promise((res) => {
  execFile(cmd, args, { timeout: ms, maxBuffer: 8 << 20, env: env || process.env },
    (err, stdout, stderr) => res({ ok: !err, out: (stdout || '').trim(), err: (stderr || '').trim() }))
})
const b64 = s => Buffer.from(String(s), 'utf8').toString('base64')
const unb64 = s => { try { return Buffer.from(String(s || ''), 'base64').toString('utf8') } catch { return '' } }
const die = m => { console.error(`agentfleet dashboard: ${m}`); process.exit(1) }
// Unknown is null, never 0 or NaN: a machine we could not measure must not read
// as a machine measuring zero.
const numOrNull = v => (Number.isFinite(Number(v)) && String(v).trim() !== '' ? Number(v) : null)
// Always two values, both null when absent: destructuring a short array leaves
// undefined behind, and an undefined field vanishes from the JSON entirely,
// which is the one thing the uniform shape exists to prevent.
const numPair = s => { const p = String(s || '').split('/'); return [numOrNull(p[0]), numOrNull(p[1])] }

// ---------------------------------------------------------------- config
// The server reads the SAME config the shell does, by asking the shell. Parsing
// agentfleet.conf here would fork the search order, the derived defaults and the
// provider interface into a second language and let them drift; one short bash
// that sources lib/common.sh cannot drift. Output is tab-separated rather than
// JSON because bash 3.2 has no safe JSON escaping and jq is not a dependency.
const BOOTSTRAP = `
set -euo pipefail
export AF_DIR=${JSON.stringify(ROOT)}
. "$AF_DIR/lib/common.sh"
af_load_config
af_provider_load
for v in AF_NAME AF_CONFIG AF_USER AF_KEY AF_HOME AF_WORKDIR AF_AGENT AF_SESSION \\
         AF_DASH_PORT AF_DASH_BIND AF_DASH_STALL_SEC AF_DASH_MEM_PCT \\
         AF_PROBE_TIMEOUT AF_TERM_PORT AF_NOVNC_PORT \\
         AF_BROWSER AF_CDP_PORT AF_MAC_CHROME AF_MAC_CHROME_PORT; do
  eval "printf 'v\\t%s\\t%s\\n' \\"\\$v\\" \\"\\\${$v:-}\\""
done
printf 'v\\tAF_TAILSCALE\\t%s\\n' "$(af_tailscale_bin || true)"
# Presence, not value: AF_TERM_PORT="" means "do not offer the link" while an
# absent AF_TERM_PORT means "use the documented default", and both arrive above
# as an empty string. Without these two lines a config written before the ports
# existed would silently lose both per-row links.
printf 'v\\tAF_TERM_PORT_SET\\t%s\\n' "\${AF_TERM_PORT+1}"
printf 'v\\tAF_NOVNC_PORT_SET\\t%s\\n' "\${AF_NOVNC_PORT+1}"
printf '%s\\n' "\${AF_DASH_SERVICES:-}" | while read -r line; do
  if [ -n "$line" ]; then printf 'svc\\t%s\\n' "$line"; fi
done
for h in $(provider_list); do
  printf 'host\\t%s\\t%s\\n' "$h" "$(af_host_addr "$h" 2>/dev/null || true)"
done
if declare -f provider_status >/dev/null 2>&1; then
  provider_status 2>/dev/null | while IFS= read -r line; do printf 'stat\\t%s\\n' "$line"; done
fi
`

let CFG = null          // scalars from the config
let SERVICES = []       // [{ key, kind: 'unit'|'port', arg }]
let INVENTORY = { at: 0, hosts: [], addr: new Map(), status: new Map() }
let INVENTORY_ERROR = ''   // last refresh failure, surfaced as configError

// Throws, never exits. This runs on every inventory refresh, not only at boot:
// a config file caught mid-edit, or a bootstrap that outruns its 60s timeout,
// used to kill a dashboard that was healthy a second ago - on a phone, with the
// laptop that could restart it out of reach. The boot path turns the throw into
// die(); inventory() turns it into a stale-but-served page.
async function loadConfig() {
  const r = await sh('bash', ['-c', BOOTSTRAP], 60000)
  if (!r.ok) throw new Error(`cannot read config via lib/common.sh\n${r.err || r.out}`)
  const cfg = {}, svc = [], hosts = [], addr = new Map(), status = new Map()
  for (const line of r.out.split('\n')) {
    const f = line.split('\t')
    if (f[0] === 'v') cfg[f[1]] = (f[2] || '').trim()
    else if (f[0] === 'svc') svc.push(f[1])
    else if (f[0] === 'host' && f[1]) { hosts.push(f[1]); if (f[2]) addr.set(f[1], f[2]) }
    // Optional provider extension: "host<TAB>power<TAB>region<TAB>size". Providers
    // that cannot answer simply do not define provider_status, and the columns
    // report unknown rather than a guess.
    else if (f[0] === 'stat' && f[1]) status.set(f[1], { power: f[2] || 'unknown', region: f[3] || '', size: f[4] || '' })
  }
  if (!cfg.AF_KEY) throw new Error('config did not yield AF_KEY - is lib/common.sh intact?')
  // Still a hard refusal, not a skip: an address starting with "-" becomes an
  // ssh flag. On a refresh the caller keeps the previous inventory instead.
  for (const [h, a] of addr) if (!ADDR_RE.test(a)) throw new Error(`refusing unusable address for ${h}: ${a}`)
  return { cfg, svc, inv: { at: Date.now(), hosts, addr, status } }
}

// These values are pasted into the shell command that runs on the machines. The
// config file is your own shell so this is not a privilege boundary, but a
// stray quote there would otherwise produce a probe that fails in a way nobody
// can read. Refuse it at boot instead.
function shellSafe(name, value) {
  if (/['"`$\\]/.test(value) || value.includes('\n')) die(`${name} cannot contain quotes, $, backslash or a newline`)
  return value
}
// Where each machine's collector writes, $HOME-relative. Fixed here and in
// lib/control.sh to match agent/af-status.py and agent/af-cost.py - a reader
// path that could drift from the writer's only ever produced blank rows.
const STATUS_REL = '.cache/agentfleet/status.json'
const COST_REL = '.cache/agentfleet/cost.json'
// How the per-session probe recognises "the agent is mid-turn" on the tmux
// screen. The same anchors agent/af-status.py's adapters use, and not a setting
// for the same reason they are not: the wording belongs to the agent CLI, so
// when it changes both this and the collector have to be updated together, and
// a knob that fixes only half of that is worse than no knob.
const BUSY_RE = 'esc to interrupt|tokens'

// With nothing configured, check exactly the optional modules this fleet has
// turned on. Better than a fixed list of dots: a module you never enabled
// cannot show up red, and a module you did enable is watched without you having
// to name it twice.
function defaultServices(cfg) {
  const out = []
  if (cfg.AF_TERM_PORT) out.push(`ttyd|port:${cfg.AF_TERM_PORT}`)
  if (cfg.AF_BROWSER === '1') out.push(`browser|port:${cfg.AF_CDP_PORT || 9222}`)
  if (cfg.AF_MAC_CHROME === '1') out.push(`macChrome|port:${cfg.AF_MAC_CHROME_PORT || 9223}`)
  return out
}

// The per-row "term" and "screen" links are the client's to render, but the
// ports are config, so the server has to hand them over - the client keeps only
// the documented defaults as a fallback for an old server. Resolved once at
// boot: unset means the documented default, an explicit empty string means "do
// not offer that link", and anything that is not a port number is ignored
// loudly rather than pasted into an href.
let LINK_PORTS = { term: '7681', screen: '6080' }
const PORT_RE = /^[0-9]{1,5}$/
function linkPort(cfg, name, dflt) {
  if (!cfg[`${name}_SET`]) return dflt
  const v = (cfg[name] || '').trim()
  if (v === '') return ''
  if (!PORT_RE.test(v)) { console.error(`warning: ignoring unusable ${name}=${v}, using ${dflt}`); return dflt }
  return v
}

// "key|unit:name" or "key|port:9222". Anything else is a config error, not a
// silently skipped check: a service check that could not run is not a pass.
function parseServices(lines) {
  const out = []
  for (const raw of lines) {
    const [key, spec] = String(raw).split('|')
    const k = (key || '').trim(), s = (spec || '').trim()
    if (!SERVICE_KEY_RE.test(k)) die(`AF_DASH_SERVICES: bad key ${JSON.stringify(key)}`)
    const m = /^(unit|port):(.+)$/.exec(s)
    if (!m) die(`AF_DASH_SERVICES: ${k} needs "unit:<name>" or "port:<n>", got ${JSON.stringify(s)}`)
    if (m[1] === 'unit' && !UNIT_RE.test(m[2])) die(`AF_DASH_SERVICES: ${k} has an unusable unit name`)
    if (m[1] === 'port' && !PORT_RE.test(m[2])) die(`AF_DASH_SERVICES: ${k} has an unusable port`)
    out.push({ key: k, kind: m[1], arg: m[2] })
  }
  return out
}

// Mirrors af_ssh_opts_init, but with the page's connect budget (AF_PROBE_TIMEOUT,
// the same one `agentfleet ls` uses) rather than the script default: a poll
// would rather call a box unreachable than stay open waiting for it. Addresses
// are resolved once per inventory refresh, because af_host_addr shells out to
// tailscale and the cloud CLI and doing that per host per poll is pure latency.
const sshArgs = host => ['-i', CFG.AF_KEY,
  '-o', 'StrictHostKeyChecking=accept-new', '-o', 'BatchMode=yes',
  '-o', `ConnectTimeout=${Number(CFG.AF_PROBE_TIMEOUT) || 8}`, '-o', 'ServerAliveInterval=5',
  `${CFG.AF_USER}@${INVENTORY.addr.get(host)}`]

// Child agentfleet commands must land on the same config file this process
// bootstrapped from, whatever directory the dashboard was started in, and must
// never stop on a confirm prompt there is no terminal to answer.
const cliEnv = () => ({ ...process.env, AGENTFLEET_CONFIG: CFG.AF_CONFIG, AF_YES: '1' })

// ---------------------------------------------------------------- auth
// The password is generated on first run, printed once, and stored 0600. The
// cookie is an HMAC of an expiry, so there is no session store to lose and a
// login survives restarts.
const STATE_DIR = join(process.env.XDG_STATE_HOME || join(HOME, '.local', 'state'), 'agentfleet')
const PWFILE = join(STATE_DIR, 'dashboard.pw')
const SECFILE = join(STATE_DIR, 'dashboard.secret')
const DAYS30 = 30 * 864e5
let PW = '', SECRET = ''

// 0600 tmp-then-rename, because writeFile creates and truncates before it
// writes: a Ctrl-C or a full disk during first run otherwise leaves a zero-byte
// secret file behind, and the next start reads it as a valid empty HMAC key.
async function writePrivateFile(path, text) {
  const tmp = `${path}.${process.pid}.tmp`
  try {
    await writeFile(tmp, text, { mode: 0o600 })
    await rename(tmp, path)
  } catch (e) {
    await unlink(tmp).catch(() => {})   // do not leave a half-written file in the state dir
    throw e
  }
}

async function initAuth() {
  await mkdir(STATE_DIR, { recursive: true, mode: 0o700 }).catch(() => {})
  try { PW = (await readFile(PWFILE, 'utf8')).trim() } catch {
    PW = randomBytes(9).toString('base64url')
    await writePrivateFile(PWFILE, PW + '\n')
    // Printed exactly once, here. Losing it means deleting the file to mint a new one.
    console.log(`\n  dashboard password: ${PW}\n  (stored in ${PWFILE})\n`)
  }
  if (!PW) die(`empty password file: ${PWFILE} - delete it to mint a new password`)
  try { SECRET = (await readFile(SECFILE, 'utf8')).trim() } catch {
    SECRET = randomBytes(32).toString('hex')
    await writePrivateFile(SECFILE, SECRET + '\n')
  }
  // Without this guard an empty or truncated secret file keys sign() on "",
  // and node happily HMACs with an empty key: anyone can then compute
  // `${exp}.${hmac_sha256('', exp)}` and get a valid session with no password,
  // which this port turns into shell on every machine in the fleet. Refuse to
  // start rather than run with authentication silently disabled.
  if (SECRET.length < 32) die(`unusable secret file: ${SECFILE} (${SECRET.length} chars) - delete it to mint a new one`)
}
const sign = exp => createHmac('sha256', SECRET).update(String(exp)).digest('hex')
const mintCookie = () => { const e = Date.now() + DAYS30; return `${e}.${sign(e)}` }
// timingSafeEqual throws on a length mismatch, which would 500 where a 401 is
// the answer, so the length check comes first in both comparisons.
const safeEq = (given, want) => {
  const a = Buffer.from(String(given || '')), b = Buffer.from(String(want || ''))
  return a.length > 0 && a.length === b.length && timingSafeEqual(a, b)
}
function cookieOk(raw = '') {
  const v = /(?:^|;\s*)agentfleet=([^;]+)/.exec(raw)?.[1]
  if (!v) return false
  // decodeURIComponent throws URIError on a malformed escape - `Cookie:
  // agentfleet=%` is enough. This runs before any auth check and (before the
  // fix) before the handler's try, so one unauthenticated curl took the whole
  // control plane down and nothing restarted it. A cookie we cannot decode is
  // a cookie that does not authenticate: refuse, never throw.
  let dec
  try { dec = decodeURIComponent(v) } catch { return false }
  const [exp, mac] = dec.split('.')
  if (!exp || !mac || !Number(exp) || Number(exp) < Date.now()) return false
  return safeEq(mac, sign(Number(exp)))
}

// ---------------------------------------------------------------- probing
async function bindAddress() {
  const want = process.env.AF_DASH_BIND || CFG.AF_DASH_BIND || 'tailnet'
  if (want === 'local') return '127.0.0.1'
  if (want !== 'tailnet') return want
  if (CFG.AF_TAILSCALE) {
    const r = await sh(CFG.AF_TAILSCALE, ['ip', '-4'], 8000)
    const ip = r.out.split('\n')[0].trim()
    if (r.ok && ip) return ip
  }
  console.error('warning: AF_DASH_BIND=tailnet but no tailscale address found, binding to 127.0.0.1')
  return '127.0.0.1'
}

async function inventory(force = false) {
  if (!force && Date.now() - INVENTORY.at < TUNING.inventoryTtlMs) return INVENTORY
  try {
    const { inv } = await loadConfig()
    INVENTORY = inv
    INVENTORY_ERROR = ''
  } catch (e) {
    // Serve what we last knew and say so, rather than exiting mid-request. The
    // refresh is on the hot path (?force=1 fires on every action and every tab
    // focus), so any transient bootstrap failure would otherwise be fatal.
    INVENTORY_ERROR = String(e?.message || e).split('\n')[0]
    console.error(`agentfleet dashboard: inventory refresh failed, serving last known inventory: ${INVENTORY_ERROR}`)
    INVENTORY.at = Date.now()   // do not re-run a broken bootstrap on every poll
  }
  return INVENTORY
}

// One ssh per machine. Per tmux session we also lift whether the agent is
// mid-turn, so the index answers "is anything happening on this box" without
// attaching to ten terminals. The narrative ("what is it doing, does it need
// me") comes from the summary cache, base64'd so JSON can ride the
// pipe-delimited payload.
function buildProbe() {
  const wd = shellSafe('AF_WORKDIR', CFG.AF_WORKDIR)
  const agent = shellSafe('AF_AGENT', CFG.AF_AGENT)
  // ${svc} must stay braced: "$svc<key>" would read as one variable name.
  const svc = SERVICES.map(s => s.kind === 'unit'
    ? `if [ "$(systemctl --user is-active ${s.arg} 2>/dev/null)" = active ]; then svc="\${svc}${s.key}:1,"; else svc="\${svc}${s.key}:0,"; fi`
    : `if curl -s -m 2 -o /dev/null http://127.0.0.1:${s.arg}/ 2>/dev/null; then svc="\${svc}${s.key}:1,"; else svc="\${svc}${s.key}:0,"; fi`)
  return [
    'export PATH=$HOME/.local/bin:$HOME/bin:/usr/local/bin:$PATH',
    "mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $7\"/\"$2}')",
    "swap=$(free -m 2>/dev/null | awk '/^Swap:/{print $3\"/\"$2}')",
    'load=$(cut -d" " -f1-2 /proc/loadavg 2>/dev/null)',
    'up=$(cut -d. -f1 /proc/uptime 2>/dev/null)',
    // A machine without the work tree still renders; its git columns just read
    // unknown. Hard-failing the whole probe on a missing directory once made a
    // perfectly healthy box look unreachable.
    'g=""; dirty=""',
    `if cd '${wd}' 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then`,
    '  base=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/HEAD)',
    '  g=$(git rev-list --left-right --count "$base"...HEAD 2>/dev/null | tr "\\t" "/")',
    '  dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d " ")',
    'fi',
    'svc=""',
    ...svc,
    // -x (exact process NAME), never -f (full command line). Two reasons, and
    // both were observed: -f matches this very probe, because the pattern
    // string is sitting in the argv of the ssh command and its shell, so every
    // machine reports a constant nonzero count whether an agent runs or not;
    // and the agent is usually exec'd as a bare name, so a path-ish pattern
    // like "bin/claude" misses the real process anyway. -x is immune to both.
    //
    // pgrep -c prints "0" AND exits 1 when nothing matches, so an "|| echo 0"
    // fallback would emit the count twice and the field would parse as unknown.
    `ap=$(pgrep -c -x '${agent}' 2>/dev/null | head -1)`,
    '[ -n "$ap" ] || ap=0',
    `SUMF="$HOME/${STATUS_REL}"`,
    // base64 without -w0 and stat with a BSD fallback: the fleet is usually
    // Linux, but the same probe has to survive a machine that is not. The
    // redirect sits inside the subshell so a missing file stays quiet - its
    // absence is an answer, not an error worth printing on every poll.
    'sum=$( (base64 < "$SUMF" | tr -d "\\n") 2>/dev/null || true )',
    'st=$(stat -c %Y "$SUMF" 2>/dev/null || stat -f %m "$SUMF" 2>/dev/null || echo 0)',
    'if [ "${st:-0}" -gt 0 ]; then sumage=$(( $(date +%s) - st )); else sumage=-1; fi',
    'sess=""',
    'for s in $(tmux ls -F "#S" 2>/dev/null); do',
    '  att=$(tmux display -p -t "$s" "#{session_attached}" 2>/dev/null)',
    '  pane=$(tmux capture-pane -p -t "$s" 2>/dev/null | tail -40)',
    `  work=$(printf "%s" "$pane" | grep -cE '${BUSY_RE}' 2>/dev/null || echo 0)`,
    // Octal escapes, not \\x: only octal is portable across printf %b.
    '  sess="$sess$s\\0037$att\\0037$work\\0036"',
    'done',
    // today's model spend for this machine, written by whatever accounting job
    // you run (a file read, never a scan - the dashboard polls every nine seconds)
    `cost=$( (tr -d "\\n" < "$HOME/${COST_REL}") 2>/dev/null || echo "{}" )`,
    // One RS-terminated record each: the scalars (pipe-delimited, none of them
    // can contain a pipe), then the cost blob (raw JSON, which can), then one
    // record per tmux session. Giving cost a record of its own is what keeps a
    // "|" inside it from corrupting every field after it.
    'printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\\036" "$mem" "$swap" "$load" "$up" "$g" "$dirty" "$svc" "$ap" "$sum" "$sumage"',
    'printf "%s\\036" "$cost"',
    'printf "%b" "$sess"',
    // Newlines, not "; ": joining these with a semicolon puts one after `then`
    // and `do`, which is a shell syntax error, and a syntax error here means the
    // whole probe returns nothing and every machine reads as unreachable.
  ].join('\n')
}
let PROBE = ''

// The summarizer is another program's file - very often another agent's - so
// read it defensively: accept the obvious aliases, clamp the lengths, and never
// guess a state we were not told. Without this a hallucinated field name
// silently blanks a row, or a 50KB "summary" lands in the page.
const STATES = ['working', 'waiting_for_human', 'blocked', 'error', 'idle', 'done', 'unknown']
const STATE_ALIAS = {
  running: 'working', busy: 'working', active: 'working', thinking: 'working',
  waiting: 'waiting_for_human', waiting_for_input: 'waiting_for_human', needs_input: 'waiting_for_human',
  needs_human: 'waiting_for_human', input_needed: 'waiting_for_human', prompt: 'waiting_for_human',
  stuck: 'blocked', wedged: 'blocked', failed: 'error', crashed: 'error',
  complete: 'done', completed: 'done', finished: 'done', ready: 'idle',
}
const flat = (s, n) => String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, n)
const count = v => Number.isFinite(Number(v)) ? Math.max(0, Math.min(999, Math.round(Number(v)))) : 0
const obj = v => (v && typeof v === 'object' && !Array.isArray(v) ? v : {})
function normSummary(raw) {
  const o = obj(raw), t = obj(o.tasks), a = obj(o.agents)
  const pick = (...keys) => {
    for (const k of keys) if (typeof o[k] === 'string' && o[k].trim()) return o[k]
    return ''
  }
  let state = flat(pick('state', 'status'), 40).toLowerCase().replace(/[\s-]+/g, '_')
  // hasOwnProperty, not a bare lookup: a state of "constructor" or "toString"
  // would otherwise resolve to something off Object.prototype and land a
  // function where the UI expects one of seven words.
  state = STATES.includes(state) ? state
    : (Object.prototype.hasOwnProperty.call(STATE_ALIAS, state) ? STATE_ALIAS[state] : 'unknown')
  let needs = pick('needs', 'need', 'needsHuman', 'needs_human', 'ask', 'question')
  if (!needs && (o.needs === true || o.needsHuman === true)) needs = 'unspecified'
  const num = v => Number.isFinite(Number(v)) ? Math.max(0, Math.round(Number(v))) : 0
  return {
    summary: flat(pick('summary', 'headline', 'doing'), 220),
    state,
    needs: flat(needs, 220),
    task: flat(pick('task', 'prompt', 'goal'), 220),
    tool: flat(pick('tool', 'lastTool'), 60),
    idleSec: num(o.idleSec ?? o.idle_sec ?? o.idle),
    // work in flight - passed through untouched apart from clamping
    activity: flat(pick('activity'), 120),
    shells: count(o.shells),
    tasks: { done: count(t.done), inProgress: count(t.inProgress ?? t.in_progress), open: count(t.open) },
    agents: {
      running: count(a.running), finished: count(a.finished),
      names: (Array.isArray(a.names) ? a.names : []).map(n => flat(n, 60)).filter(Boolean).slice(0, 8),
    },
  }
}
const EMPTY_SUMMARY = {
  summary: '', state: 'unknown', needs: '', task: '', tool: '', idleSec: 0,
  activity: '', shells: 0, tasks: { done: 0, inProgress: 0, open: 0 },
  agents: { running: 0, finished: 0, names: [] },
}

// A background shell or a subagent is HEALTHY work, not a problem - flagging it
// would put every busy machine in the attention list and make the count
// useless. It earns attention only once it has stopped moving the transcript:
// work in flight with nothing written for the stall window is wedged, not busy.
function attentionOf(p) {
  const why = []
  if (!p.reachable) why.push('unreachable')
  else {
    if (['waiting_for_human', 'blocked', 'error'].includes(p.state)) why.push(p.state)
    if ((p.idleSec || 0) >= TUNING.stallSec) {
      if ((p.shells || 0) > 0) why.push('shellStalled')
      if ((p.agents?.running || 0) > 0) why.push('agentStalled')
      if ((p.tasks?.inProgress || 0) > 0) why.push('taskStalled')
    }
    if (p.memPct !== null && p.memPct >= TUNING.memWarnPct) why.push('memory')
    // Only services you actually configured can raise an alarm. An unconfigured
    // check reports null, and null is not a failure.
    for (const s of p.services || []) if (s.ok === false) why.push(s.key)
  }
  return { attention: why.length > 0, attentionWhy: why }
}

function unreachableRow(host, err) {
  const services = SERVICES.map(s => ({ key: s.key, ok: null }))
  const base = {
    vm: host, addr: INVENTORY.addr.get(host) || '',
    reachable: false, ...EMPTY_SUMMARY, summarySource: 'none', summaryAgeSec: -1,
    freeGb: null, totalGb: null, memPct: null, swapUsedMb: null,
    load: '', uptimeH: null, sessions: [], agentProcs: null, cost: null,
    ahead: null, behind: null, uncommitted: null,
    services, ...legacyServiceFlags(services),
    error: flat(err, 200),
  }
  return { ...base, ...attentionOf(base) }
}

// The first client shipped four fixed service dots. Keep those keys populated
// when a service of that name is configured so a client written against either
// shape renders; null means "not configured", not "down".
function legacyServiceFlags(services) {
  const out = { browser: null, macChrome: null, clip: null, ttyd: null }
  for (const s of services) if (s.key in out) out[s.key] = s.ok
  return out
}

async function probe(host) {
  if (!INVENTORY.addr.get(host)) return unreachableRow(host, 'no address: provider and tailnet both came up empty')
  const r = await sh('ssh', [...sshArgs(host), PROBE], TUNING.probeTimeoutMs)
  if (!r.ok || !r.out) return unreachableRow(host, r.err || 'ssh timeout')

  // RS-separated records, as emitted by buildProbe: scalars, cost JSON, then one
  // record per tmux session.
  const [head = '', costRaw = '', ...sessRecs] = r.out.split(RS)
  const [mem, swap, load, up, git, dirty, svcRaw, ap, sum, sumage] = head.split('|')
  let cost = null
  try { const c = JSON.parse(costRaw || '{}'); if (c && typeof c.totalUsd === 'number') cost = c } catch { /* no spend file */ }

  const [freeM, totalM] = numPair(mem)
  const [swUsed] = numPair(swap)
  const [behind, ahead] = numPair(git)
  const sessions = sessRecs.filter(Boolean).map(rec => {
    const [name, att, work] = rec.split(US)
    return { name, attached: att === '1', working: Number(work || 0) > 0 }
  })
  const seen = new Map()
  for (const pair of (svcRaw || '').split(',')) {
    const [k, v] = pair.split(':')
    if (k) seen.set(k, v === '1')
  }
  const services = SERVICES.map(s => ({ key: s.key, ok: seen.has(s.key) ? seen.get(s.key) : null }))

  let s = EMPTY_SUMMARY, source = 'none'
  if (sum) {
    try { s = normSummary(JSON.parse(unb64(sum))); source = 'cache' } catch { source = 'unparsable' }
  }

  const base = {
    // addr travels with the row so the client can link to a machine's own
    // ports without re-deriving how this fleet is addressed.
    vm: host, addr: INVENTORY.addr.get(host) || '', reachable: true,
    freeGb: freeM === null ? null : +(freeM / 1024).toFixed(1),
    totalGb: totalM === null ? null : Math.round(totalM / 1024),
    memPct: freeM !== null && totalM ? Math.round((1 - freeM / totalM) * 100) : null,
    swapUsedMb: swUsed,
    load: load || '', uptimeH: up ? Math.round(Number(up) / 360) / 10 : null,
    sessions, cost, agentProcs: numOrNull(ap),
    ...s, summarySource: source, summaryAgeSec: numOrNull(sumage) ?? -1,
    ahead, behind, uncommitted: numOrNull(dirty),
    services, ...legacyServiceFlags(services),
    error: '',
  }
  return { ...base, ...attentionOf(base) }
}

let cache = { at: 0, data: null, inflight: null }
async function fleet(force = false) {
  if (!force && cache.data && Date.now() - cache.at < TUNING.fleetCacheMs) return cache.data
  if (cache.inflight) return cache.inflight
  cache.inflight = (async () => {
    try {
      const inv = await inventory(force)
      // Hosts keep the order the provider gave them; the client sorts by what
      // needs you first, and a stable base order stops rows jumping mid-click.
      const probes = await Promise.all(inv.hosts.map(probe))
      const vms = probes.map(p => ({ ...p, ...(inv.status.get(p.vm) || { power: 'unknown', region: '', size: '' }) }))
      // ports rides the fleet payload because the client already merges it over
      // its defaults (`if (d.ports)`), and it is the only response every client
      // fetches; /api/meta serves the same values for anything that asks there.
      // configError is always present, empty when fine, so the field cannot
      // vanish from the JSON the one time it matters.
      const data = {
        at: new Date().toISOString(), attention: vms.filter(v => v.attention).length, vms,
        ports: { ...LINK_PORTS }, configError: INVENTORY_ERROR,
      }
      cache = { at: Date.now(), data, inflight: null }
      return data
    } catch (e) {
      cache.inflight = null
      throw e
    }
  })()
  return cache.inflight
}

// ---------------------------------------------------------------- session tail
// The drawer wants the actual conversation, not the one-line summary. Reading
// the transcript needs code on the machine, and installing code on ten machines
// to render one page is how a tool rots, so ship the reader inline: base64 in,
// JSON out, nothing to install (python3 is the one thing it assumes is there).
function buildSessionPy() {
  return `
import glob, json, os, re, time

AGENT = ${JSON.stringify(CFG.AF_AGENT)}
WORKDIR = ${JSON.stringify(CFG.AF_WORKDIR)}
LIMIT, CHARS = ${TUNING.transcriptEntries}, 400

def roots():
    home = os.path.expanduser("~")
    if AGENT == "codex":
        return [os.path.join(home, ".codex", "sessions")]
    # Claude Code names a project directory after the working directory with
    # every non-alphanumeric character replaced. Prefer that one, but fall back
    # to every project so a differently-configured agent still shows something.
    base = os.path.join(home, ".claude", "projects")
    pref = os.path.join(base, re.sub(r"[^A-Za-z0-9]", "-", WORKDIR))
    return [pref, base] if os.path.isdir(pref) else [base]

def newest():
    for r in roots():
        files = [f for f in glob.glob(os.path.join(r, "**", "*.jsonl"), recursive=True)
                 if os.path.getsize(f) > 0]
        if files:
            return max(files, key=os.path.getmtime)
    return ""

def text_of(content):
    if isinstance(content, str):
        return content
    out = []
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") in ("text", "input_text", "output_text"):
                out.append(b.get("text", ""))
    return " ".join(out)

def target(inp):
    if isinstance(inp, str):
        try:
            inp = json.loads(inp)
        except ValueError:
            return inp
    if not isinstance(inp, dict):
        return ""
    for k in ("command", "file_path", "path", "pattern", "url", "query", "description", "prompt"):
        v = inp.get(k)
        if isinstance(v, str) and v.strip():
            return v
    return ""

def tail(path, nbytes=1500000):
    # Transcripts reach hundreds of megabytes, so read only the end of one. A
    # byte offset always lands mid-line, and that partial first line is dropped
    # rather than fed to the parser.
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - nbytes))
        data = f.read()
    if size > nbytes:
        data = data.split(b"\\n", 1)[-1]
    return data.decode("utf-8", "replace").splitlines()

def flat(s):
    return " ".join(str(s).split())[:CHARS]

# Harness scaffolding masquerading as user turns. Without this filter the
# window fills with wrappers and the actual conversation scrolls out of view.
def noise(t):
    return (not t or t.startswith("<") or "tool_result" in t[:40]
            or t.startswith("Base directory for this skill:")
            or t.startswith("Caveat:") or t.startswith("[Request interrupted")
            or t.startswith("[Image") or t.startswith("/"))

res = {"sessionId": "", "at": "", "entries": [], "error": ""}
newest_file = newest()
if not newest_file:
    res["error"] = "no transcript"
else:
    res["sessionId"] = os.path.basename(newest_file)[:-6]
    res["at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(os.path.getmtime(newest_file)))
    entries = []
    try:
        lines = tail(newest_file)
    except OSError as e:
        lines = []
        res["error"] = str(e)
    for line in lines:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if not isinstance(e, dict):
            continue
        if isinstance(e.get("payload"), dict):
            e = dict(e, **e["payload"])
        msg = e.get("message") if isinstance(e.get("message"), dict) else e
        role = msg.get("role") or e.get("type")
        at = e.get("timestamp") or ""
        content = msg.get("content")
        if role in ("user", "human"):
            t = text_of(content).strip()
            if not noise(t):
                entries.append({"role": "user", "text": flat(t), "tool": "", "at": at})
        elif role == "assistant":
            t = text_of(content).strip()
            if t:
                entries.append({"role": "assistant", "text": flat(t), "tool": "", "at": at})
            for b in (content or []):
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    entries.append({"role": "tool", "text": flat(target(b.get("input"))),
                                    "tool": b.get("name", ""), "at": at})
        elif e.get("type") == "function_call":
            entries.append({"role": "tool", "text": flat(target(e.get("arguments"))),
                            "tool": e.get("name", ""), "at": at})
    if lines and not entries and not res["error"]:
        res["error"] = "no readable turns in transcript"
    res["entries"] = entries[-LIMIT:]
print(json.dumps(res))
`
}
let SESSION_CMD = ''
const sessCache = new Map()   // host -> { at, data, inflight }
// Same shape as the fleet cache, and for the same reason: the time cache alone
// records nothing until the ssh returns, so an open drawer polling every 6s
// stacks a fresh `ssh | base64 -d | python3` every tick on any machine whose
// transcript read takes longer than that - which is precisely the wedged,
// memory-starved box this design exists not to pile onto. Concurrent callers
// share the one read in flight.
async function sessionTail(host) {
  const hit = sessCache.get(host)
  if (hit?.data && Date.now() - hit.at < TUNING.sessionCacheMs) return hit.data
  if (hit?.inflight) return hit.inflight
  const entry = { at: hit?.at || 0, data: hit?.data || null, inflight: null }
  entry.inflight = (async () => {
    try {
      const r = await sh('ssh', [...sshArgs(host), SESSION_CMD], TUNING.probeTimeoutMs)
      const failed = error => ({ vm: host, ok: false, sessionId: '', at: '', entries: [], error })
      let data
      if (!r.ok || !r.out) data = failed(flat(r.err || 'unreachable', 300))
      else {
        try {
          const p = JSON.parse(r.out)
          data = { vm: host, ok: true, sessionId: p.sessionId || '', at: p.at || '', entries: p.entries || [], error: p.error || '' }
        } catch { data = failed('unparsable transcript reply') }
      }
      sessCache.set(host, { at: Date.now(), data, inflight: null })
      return data
    } catch (e) {
      // Clear the shared promise or every later poll would replay this failure.
      entry.inflight = null
      throw e
    }
  })()
  sessCache.set(host, entry)
  return entry.inflight
}

// ---------------------------------------------------------------- actions
// tmux actions steer the LIVE session - you, on your phone, mid-run - instead
// of firing a detached job beside it. Text rides in base64 so quoting cannot
// bite: send-keys -l -- and the base64 are what stop a quote or a leading dash
// in a prompt from being read as tmux flags or shell syntax, and the sleep is
// what stops the Enter racing the paste.
const noSession = s => `tmux has-session -t ${s} 2>/dev/null || { echo "no tmux session: ${s}"; exit 3; }`
const tmuxType = (s, text) =>
  `${noSession(s)}; p=$(printf %s '${b64(text)}' | base64 -d); ` +
  `tmux send-keys -t ${s} -l -- "$p"; sleep 0.3; tmux send-keys -t ${s} Enter; echo sent`

// Machine lifecycle goes through the provider interface rather than the CLI
// because the dashboard deliberately has no delete: stopping keeps the disk,
// and destroying a machine stays a decision you make at a terminal.
const providerCall = (fn, host) => ['bash', ['-c',
  `set -euo pipefail; export AF_DIR=${JSON.stringify(ROOT)}; . "$AF_DIR/lib/common.sh"; ` +
  `af_load_config; af_provider_load; ${fn} "$1"`, 'af', host], 420000]

const ACTIONS = {
  sync:      host => [CLI, ['sync', host], 600000],
  provision: host => [CLI, ['provision', host], 1500000],
  browser:   host => [CLI, ['browser', host], 90000],
  run:       (host, p) => [CLI, ['run', host, p], 120000],
  start:     host => providerCall('provider_start', host),
  stop:      host => providerCall('provider_stop', host),
  interrupt: (host, _p, s) => ['ssh', [...sshArgs(host), `${noSession(s)}; tmux send-keys -t ${s} Escape; echo interrupted`], 30000],
  clear:     (host, _p, s) => ['ssh', [...sshArgs(host), tmuxType(s, '/clear')], 30000],
  say:       (host, p, s) => ['ssh', [...sshArgs(host), tmuxType(s, p)], 45000],
}
const PROMPT_ACTIONS = new Set(['run', 'say'])
const CLI_ACTIONS = new Set(['sync', 'provision', 'browser', 'run', 'start', 'stop'])

const jobs = new Map(); let jobSeq = 0
function runAction(host, action, prompt, session) {
  const job = { id: `j${++jobSeq}`, vm: host, action, session, state: 'running', out: '', started: Date.now() }
  jobs.set(job.id, job)
  // The map outlives every job in it; a control plane meant to run for weeks
  // must not accumulate 4KB of captured output per button press forever.
  while (jobs.size > TUNING.jobsKept) jobs.delete(jobs.keys().next().value)
  const [cmd, args, ms] = ACTIONS[action](host, prompt, session)
  sh(cmd, args, ms, CLI_ACTIONS.has(action) ? cliEnv() : null).then(r => {
    job.state = r.ok ? 'done' : 'failed'
    job.out = (r.out || r.err || '').slice(-4000)
    job.ms = Date.now() - job.started
  })
  return job
}
const jobView = j => ({ ...j, ms: j.ms ?? (Date.now() - j.started) })

// ---------------------------------------------------------------- http
const json = (res, code, body) => {
  const b = Buffer.from(JSON.stringify(body))
  res.writeHead(code, { 'content-type': 'application/json', 'content-length': b.length, 'cache-control': 'no-store' })
  res.end(b)
}
const LOGIN = wrong => `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>agentfleet</title><style>
:root{color-scheme:dark}body{margin:0;min-height:100dvh;display:grid;place-items:center;background:#0b1017;color:#e8eef8;
font:400 16px/1.5 ui-sans-serif,system-ui,sans-serif}form{display:grid;gap:.9rem;width:min(20rem,88vw)}
h1{font-size:1.2rem;font-weight:600;margin:0 0 .2rem}p{margin:0;color:#5d6b82;font-size:.8rem}
input{font:inherit;padding:.7rem .8rem;background:#101725;border:1px solid #1e2a40;color:#e8eef8;border-radius:0}
input:focus{outline:none;border-color:#4a6da8}button{font:inherit;padding:.7rem;background:#14203a;border:1px solid #1e2a40;
color:#dbe6f4;cursor:pointer}button:hover{border-color:#4a6da8}
.err{color:#cf6a5a;font-size:.8rem}</style>
<form method=post action=/login><h1>agentfleet</h1><p>Stays signed in for 30 days on this device.</p>
${wrong ? '<p class=err>Wrong password.</p>' : ''}
<input type=password name=pw placeholder=Password autofocus autocomplete=current-password>
<button>Enter</button></form>`

// Secure is set only when the request actually arrived over TLS, because a
// Secure cookie on a plain-http tailnet address would never be sent back. Front
// this with `tailscale funnel` and the flag turns itself on.
const isTls = req => req.socket.encrypted === true || req.headers['x-forwarded-proto'] === 'https'

// Request bodies are held in memory, and /login is reachable without a
// password: an endless POST there must not be able to grow the process until
// the OOM killer answers it. Over the cap we keep draining (so the 413 can
// still be written) but stop accumulating. The largest legitimate body is a
// MAX_PROMPT-sized JSON action, three orders of magnitude under this.
const MAX_BODY = 1 << 20
async function readBody(req) {
  const chunks = []; let n = 0, over = false
  for await (const c of req) {
    n += c.length
    if (n > MAX_BODY) { over = true; continue }
    chunks.push(c)
  }
  // Concat then decode once: decoding per chunk splits multi-byte characters
  // across the boundary and corrupts them.
  return over ? null : Buffer.concat(chunks).toString('utf8')
}

// Percent-decoding attacker-shaped text throws URIError, and every one of these
// call sites is reachable before or without authentication. Undecodable input
// is input that matches nothing: return null and let the caller 400 it.
const safeDecode = s => { try { return decodeURIComponent(s) } catch { return null } }

const knownHost = h => typeof h === 'string' && INVENTORY.hosts.indexOf(h) !== -1
const reachable = h => Boolean(INVENTORY.addr.get(h))

const server = createServer(async (req, res) => {
  // Everything the request can influence stays INSIDE the try, parsing the URL
  // and the cookie included. Both run before any authentication, so a throw
  // there escapes an async handler as an unhandled rejection and takes the
  // process with it - an unauthenticated one-request kill.
  try {
    // `GET //[` is a valid request line that new URL() rejects. Answer it,
    // do not let it become a 500 - and never let it out of this try at all.
    let url
    try { url = new URL(req.url, 'http://x') } catch { return json(res, 400, { error: 'bad request target' }) }
    const authed = cookieOk(req.headers.cookie || '')
    if (url.pathname === '/login') {
      if (req.method === 'POST') {
        const body = await readBody(req)
        if (body === null) return json(res, 413, { error: 'body too large' })
        if (!safeEq(new URLSearchParams(body).get('pw'), PW)) {
          res.writeHead(401, { 'content-type': 'text/html; charset=utf-8' }); return res.end(LOGIN(true))
        }
        res.writeHead(302, { location: '/', 'set-cookie':
          `agentfleet=${encodeURIComponent(mintCookie())}; Path=/; Max-Age=${DAYS30 / 1000}; HttpOnly; SameSite=Lax${isTls(req) ? '; Secure' : ''}` })
        return res.end()
      }
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); return res.end(LOGIN(false))
    }
    if (!authed) {
      if (url.pathname.startsWith('/api/')) return json(res, 401, { error: 'auth' })
      res.writeHead(302, { location: '/login' }); return res.end()
    }
    if (url.pathname === '/' || url.pathname === '/index.html') {
      const html = await readFile(join(DIR, 'index.html'))
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' })
      return res.end(html)
    }
    // One source of truth for the state vocabulary and the timings, so a client
    // does not keep a second copy that drifts. The shipped page does not fetch
    // it yet - the link ports it does need ride /api/fleet, which it already
    // polls - so keep the two in step until it does.
    if (url.pathname === '/api/meta') {
      return json(res, 200, {
        name: CFG.AF_NAME, agent: CFG.AF_AGENT, session: CFG.AF_SESSION,
        states: STATES, stateAlias: STATE_ALIAS, tuning: TUNING,
        services: SERVICES.map(s => ({ key: s.key, kind: s.kind, arg: s.arg })),
        actions: Object.keys(ACTIONS), hosts: INVENTORY.hosts,
        // Same values /api/fleet ships as `ports`, resolved once at boot.
        // Empty means no link. Keep the two in step: a client reading either
        // one must get the same answer.
        termPort: LINK_PORTS.term, screenPort: LINK_PORTS.screen, ports: { ...LINK_PORTS },
      })
    }
    if (url.pathname === '/api/fleet') return json(res, 200, await fleet(url.searchParams.get('force') === '1'))
    if (url.pathname === '/api/jobs') return json(res, 200, { jobs: [...jobs.values()].slice(-25).reverse().map(jobView) })
    if (url.pathname.startsWith('/api/session/')) {
      const host = safeDecode(url.pathname.slice('/api/session/'.length))
      if (!knownHost(host)) return json(res, 400, { error: 'unknown host' })
      return json(res, 200, await sessionTail(host))
    }
    if (url.pathname === '/api/action' && req.method === 'POST') {
      const body = await readBody(req)
      if (body === null) return json(res, 413, { error: 'body too large' })
      let parsed = {}; try { parsed = JSON.parse(body || '{}') } catch { return json(res, 400, { error: 'bad json' }) }
      const { vm: host, action } = parsed
      const session = parsed.session || CFG.AF_SESSION
      // The allow-list is the configured inventory, and the session pattern is
      // deliberately narrow: both values are concatenated into a remote shell
      // command below, and these two checks are the only thing standing between
      // a POST body and command execution on the machine. Widening either one
      // to accept "any plausible name" gives that away.
      if (!knownHost(host)) return json(res, 400, { error: 'unknown host' })
      if (!SESSION_RE.test(session)) return json(res, 400, { error: 'bad session' })
      if (!Object.prototype.hasOwnProperty.call(ACTIONS, action)) return json(res, 400, { error: 'unknown action' })
      // Everything except `start` needs an address to talk to. Say so, rather
      // than shipping "user@undefined" to ssh and reporting its error.
      if (action !== 'start' && !reachable(host)) return json(res, 503, { error: `no address for ${host}` })
      let prompt = typeof parsed.prompt === 'string' ? parsed.prompt : ''
      if (PROMPT_ACTIONS.has(action)) {
        // Trim BEFORE the emptiness check, for both actions. With the trim
        // inside the `say` branch, `run` accepted "   ": it passed here, passed
        // cmd_run's own `[ -n "$prompt" ]`, and provisioned a job file plus a
        // detached tmux agent with a blank instruction. The browser trims, so
        // only another client or a retry ever hit it.
        prompt = prompt.trim()
        if (action === 'say') prompt = prompt.replace(/[\r\n]+/g, ' ').trim()   // one Enter, one turn
        if (!prompt) return json(res, 400, { error: 'empty prompt' })
        if (prompt.length > MAX_PROMPT) return json(res, 400, { error: `prompt over ${MAX_PROMPT} chars` })
      }
      const job = runAction(host, action, prompt, session)
      cache.at = 0   // whatever it did, the next poll should see it
      return json(res, 202, { job: jobView(job) })
    }
    res.writeHead(404); res.end('not found')
  } catch (e) { json(res, 500, { error: String(e?.message || e) }) }
})

// At boot a broken config IS fatal - there is nothing to fall back to. Only the
// refresh path (inventory()) survives it.
let boot = null
try { boot = await loadConfig() } catch (e) { die(String(e?.message || e)) }
CFG = boot.cfg
SERVICES = parseServices(boot.svc.length ? boot.svc : defaultServices(CFG))
INVENTORY = boot.inv
TUNING.stallSec = Number(CFG.AF_DASH_STALL_SEC) || TUNING.stallSec
TUNING.memWarnPct = Number(CFG.AF_DASH_MEM_PCT) || TUNING.memWarnPct
// The screen link points at the machine's noVNC listener, so it reads the port
// that listener actually binds rather than a second setting that had to be kept
// equal to it by hand.
LINK_PORTS = { term: linkPort(CFG, 'AF_TERM_PORT', '7681'), screen: linkPort(CFG, 'AF_NOVNC_PORT', '6080') }
PROBE = buildProbe()
SESSION_CMD = `printf %s '${b64(buildSessionPy())}' | base64 -d | python3 - 2>/dev/null`
if (!INVENTORY.hosts.length) console.error('warning: the provider returned no machines - the page will be empty')

await initAuth()
// Installed only after boot, so a bad config still fails loudly at startup
// while a live server survives. Nothing supervises this process - `agentfleet
// dash` is a foreground `exec node`, with no systemd Restart= and no launchd
// KeepAlive - so a throw from a path nobody wrapped is a fleet with no control
// plane until someone walks back to the laptop. Log it and keep serving.
process.on('uncaughtException', e => console.error(`agentfleet dashboard: uncaught ${e?.stack || e}`))
process.on('unhandledRejection', e => console.error(`agentfleet dashboard: unhandled rejection ${e?.stack || e}`))

const port = Number(process.env.AF_DASH_PORT || CFG.AF_DASH_PORT || 8788)
const host = await bindAddress()
// Explicit, because the uncaughtException handler above would otherwise turn a
// failed bind into a logged line and a process that exits 0 having served
// nothing. A port already in use is fatal and must say so.
server.on('error', e => die(`cannot listen on ${host}:${port} - ${e?.message || e}`))
server.listen(port, host, () => console.log(`agentfleet dashboard on http://${host}:${port}`))
