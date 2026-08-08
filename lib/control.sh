#!/usr/bin/env bash
# The everyday commands: what is each agent doing, and how do I steer it.
#
# Sourced by the `agentfleet` dispatcher after af_load_config and
# af_provider_load, so every AF_* variable and af_* helper already exists.
#
# Defines: cmd_ls cmd_dash cmd_say cmd_run cmd_attach cmd_ssh cmd_start cmd_down

# Past this age the status cache describes a machine we have lost sight of, so
# `ls` labels it stale instead of reprinting a dead reading as if it were now.
AF_LS_STALE_SEC=600

# Available memory below this is the number that predicts a machine wedging. An
# over-fanned-out agent can eat the last of it and freeze the box hard enough
# that sshd cannot fork, which means no rescue login and no way to see why.
AF_LS_MEM_LOW_MB=2000

af_tab=$'\t'

# ---------------------------------------------------------------- ls

# One line per host: name, state, what it is doing, memory, today's spend.
#
# The narrative is NOT computed here. Each machine writes it to a status cache
# on a timer, so this is one cheap read per host instead of ten transcript
# parses, and the table lands in about a second. Memory rides along in the same
# round trip because it is one `awk` and because it is the early warning for the
# failure that costs you the machine.
#
# The two cache paths the machines' collectors write, $HOME-relative. Fixed on
# both sides on purpose: `ls` and the dashboard have to read exactly what
# agent/af-status.py and agent/af-cost.py write, and a pair of settings that had
# to be changed in lockstep with a third only ever produced a fleet that
# rendered on the web page while `ls` reported "no status cache yet".
AF_STATUS_REL=".cache/agentfleet/status.json"
AF_COST_REL=".cache/agentfleet/cost.json"

af_ls_probe_script() {
  cat <<PROBE
S="\$HOME/$AF_STATUS_REL"
C="\$HOME/$AF_COST_REL"
M=\$(free -m 2>/dev/null | awk '/^Mem:/{print \$7"|"\$2}')
T=\$(stat -c %Y "\$S" 2>/dev/null || stat -f %m "\$S" 2>/dev/null || echo 0)
if [ "\${T:-0}" -gt 0 ]; then AGE=\$(( \$(date +%s) - T )); else AGE=-1; fi
printf '%s|%s\n' "\${M:-|}" "\$AGE"
cat "\$C" 2>/dev/null | tr -d '\n'; printf '\n'
cat "\$S" 2>/dev/null
PROBE
}

# One host, in the background, with a hard ceiling on how long it may take.
# ssh has no total-runtime timeout: ConnectTimeout only covers the handshake, so
# a box that accepts the connection and then stops answering would hold the
# whole table open. Run a watchdog and kill the transport instead.
af_ls_probe_one() {
  local host="$1" dir="$2" probe="$3" addr sshpid dogpid
  addr="$(af_host_addr "$host" 2>/dev/null)" || return 0
  # shellcheck disable=SC2029  # $probe is the script we are deliberately sending
  ssh "${AF_SSH_OPTS[@]}" "$AF_USER@$addr" "$probe" >"$dir/$host.out" 2>/dev/null &
  sshpid=$!
  ( sleep "${AF_PROBE_TIMEOUT:-8}"; kill -9 "$sshpid" ) >/dev/null 2>&1 &
  dogpid=$!
  wait "$sshpid" 2>/dev/null || true
  kill "$dogpid" >/dev/null 2>&1 || true
  return 0
}

af_is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Pull a @tsv field list out of one of the machine-written JSON caches, RS
# separated, or empty if that file is not JSON we can read. Defensive on purpose:
# it is another program's file, and a machine mid-upgrade may be writing an older
# or newer shape than we expect.
#
# The first tr is a terminal-safety guard, not tidying. These fields are written
# by an LLM on the machine summarising a transcript, so they carry whatever
# prompt injection the agent read off a web page or an issue body, and @tsv
# escapes tab/newline/CR but NOT ESC: unfiltered, a status line could repaint the
# operator's screen (a needy machine rendering as a healthy idle one) or write
# their clipboard with OSC 52. Tab (\011) and newline (\012) survive because they
# are this pipeline's own separators; real ones inside a field are already
# backslash-escaped by @tsv.
#
# The second tr is why callers split on RS (\036) and not on @tsv's tab: tab is
# IFS whitespace, so `read` collapses a run of them, and a machine with no .needs
# shifted every later field left - its summary landed in the needs slot, its cost
# number printed in the DOING column, and a cost file with a day but no total
# slid the date into the amount. RS cannot appear in the data (the tr above
# deleted it before this tr made any), and unlike \001 it is not a byte bash uses
# internally for quoting - an IFS of \001 swallows the separators instead.
af_ls_fields() {
  printf '%s' "$1" | jq -r "$2" 2>/dev/null | tr -d '\000-\010\013-\037\177' | tr '\t' '\036' || true
}

# rank<TAB>host<TAB>state<TAB>doing<TAB>mem<TAB>cost, ready to sort.
#
# A host we could not reach has UNKNOWN memory and UNKNOWN spend, never zero.
# Printing "0.0/0G free" for a box nobody could talk to reads as a healthy idle
# machine, which is the opposite of the truth.
af_ls_row() {
  local host="$1" dir="$2"
  local f="$dir/$host.out"
  local line1 costjson statusjson fields free total age costfields costday=""
  local state="unreachable" doing="no answer over ssh" mem="?" cost="?" low=0 rank=1
  local needs="" headline="" costv=""

  if [ -s "$f" ]; then
    state="unknown"; doing="no status cache yet"; cost="-"
    line1="$(sed -n 1p "$f")"
    costjson="$(sed -n 2p "$f")"
    statusjson="$(tail -n +3 "$f")"
    IFS='|' read -r free total age <<<"$line1"

    if af_is_num "$free" && af_is_num "$total" && [ "$total" -gt 0 ]; then
      mem="$(awk -v f="$free" -v t="$total" 'BEGIN{printf "%.1f/%.0fG", f/1024, t/1024}')"
      if [ "$free" -lt "$AF_LS_MEM_LOW_MB" ]; then mem="$mem LOW"; low=1; fi
    fi

    if [ -n "$statusjson" ]; then
      fields="$(af_ls_fields "$statusjson" '[
          (.state // "unknown"),
          ((.needs // "") | tostring),
          ((.summary // .activity // .task // "") | tostring),
          ((.cost.todayUsd // .cost.totalUsd // .todayUsd // "") | tostring)
        ] | @tsv')"
      if [ -n "$fields" ]; then
        IFS=$'\036' read -r state needs headline costv <<<"$fields"
        [ -n "$state" ] || state="unknown"
        # What it needs beats what it is doing: that is the line you act on.
        doing="$needs"
        [ -n "$doing" ] || doing="$headline"
        [ -n "$doing" ] || doing="-"
      else
        state="unknown"; doing="status cache is not readable JSON"
      fi
    fi

    if [ -z "$costv" ] && [ -n "$costjson" ]; then
      costfields="$(af_ls_fields "$costjson" '[
          ((.totalUsd // .todayUsd // "") | tostring),
          ((.day // "") | tostring)
        ] | @tsv')"
      IFS=$'\036' read -r costv costday <<<"$costfields"
      # The collector buckets by LOCAL DAY and stamps the file with it; nothing
      # prunes or refreshes that file. Without this check the column headed
      # TODAY reprints a dead reading: one hand-run of af-cost shows that day's
      # total forever, and even with a timer every midnight rollover shows
      # yesterday's spend as now. Unknown beats confidently wrong.
      if [ -n "$costday" ] && [ "$costday" != "$(date +%Y-%m-%d)" ]; then costv=""; fi
    fi
    case "$costv" in
      ''|null) ;;
      *) cost="$(awk -v v="$costv" 'BEGIN{printf "$%.2f", v}' 2>/dev/null || printf -- '-')" ;;
    esac

    if af_is_num "$age" && [ "$age" -gt "$AF_LS_STALE_SEC" ]; then
      doing="stale $((age / 60))m: $doing"
    fi
  fi

  case "$state" in
    waiting_for_human|waiting|blocked|error) rank=0 ;;
    unreachable) rank=1 ;;
    *) if [ "$low" = 1 ]; then rank=2
       elif [ "$state" = working ]; then rank=3
       else rank=4; fi ;;
  esac
  case "$state" in waiting_for_human) state=waiting ;; esac

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rank" "$host" "$state" "$doing" "$mem" "$cost"
}

# Colour is for a human at a terminal. Piped into anything else it is noise that
# breaks grep, so emit none unless stdout is a tty.
af_ls_colors() {
  AF_C_OFF=""; AF_C_RED=""; AF_C_YEL=""; AF_C_DIM=""
  [ -t 1 ] || return 0
  AF_C_OFF=$'\033[0m'; AF_C_RED=$'\033[31m'; AF_C_YEL=$'\033[33m'; AF_C_DIM=$'\033[2m'
}

cmd_ls() {
  case "${1:-}" in
    -h|--help) af_log "usage: agentfleet ls [host...]"; return 0 ;;
  esac
  af_need jq
  local hosts host tmp probe pids="" waiting=""

  hosts="$(af_expand_hosts "$@")"
  [ -n "$hosts" ] || af_die "no hosts - set AF_HOSTS in $AF_CONFIG, or create one: agentfleet up <host>"

  probe="$(af_ls_probe_script)"
  tmp="$(mktemp -d)" || af_die "cannot create a temp dir"
  for host in $hosts; do
    af_ls_probe_one "$host" "$tmp" "$probe" &
    pids="$pids $!"
  done
  # shellcheck disable=SC2086
  wait $pids 2>/dev/null || true

  for host in $hosts; do af_ls_row "$host" "$tmp" >>"$tmp/rows"; done
  af_ls_colors
  printf '%-10s %-11s %-40s %-12s %7s\n' HOST STATE DOING MEM TODAY

  local rank state doing mem cost c
  # Needs-you first, then unreachable, then low memory, then busy, then quiet.
  while IFS="$af_tab" read -r rank host state doing mem cost; do
    case "$rank" in
      0) c="$AF_C_RED"; waiting="$waiting $host" ;;
      1|2) c="$AF_C_YEL"; waiting="$waiting $host" ;;
      4) c="$AF_C_DIM" ;;
      *) c="" ;;
    esac
    printf '%s%-10s %-11.11s %-40.40s %-12s %7s%s\n' \
      "$c" "$host" "$state" "$doing" "$mem" "$cost" "$AF_C_OFF"
  done < <(sort -t "$af_tab" -k1,1n -k2,2 "$tmp/rows")

  rm -rf "$tmp"
  [ -n "$waiting" ] && af_log "need you:$waiting"
  return 0
}

# ---------------------------------------------------------------- dash

cmd_dash() {
  case "${1:-}" in
    -h|--help) af_log "usage: agentfleet dash    (serves the fleet page on AF_DASH_PORT)"; return 0 ;;
  esac
  af_need node
  local server="$AF_DIR/dashboard/server.mjs"
  [ -f "$server" ] || af_die "dashboard not installed: $server"

  # Print the address the SERVER will bind, not a guess. dashboard/server.mjs
  # honours AF_DASH_BIND, so deriving this from the tailnet alone printed
  # http://100.x.y.z:8788 to someone who had set AF_DASH_BIND=local - a URL
  # their phone gets connection-refused on, with the real one two lines below.
  local bind="${AF_DASH_BIND:-tailnet}" addr="127.0.0.1" ts tsip
  case "$bind" in
    tailnet)
      if [ "$AF_TAILNET" != off ] && ts="$(af_tailscale_bin)"; then
        # `|| true` is load-bearing: common.sh sets pipefail, so a tailscale
        # that exits nonzero (daemon stopped, logged out, a broken CLI shim)
        # would make this assignment fail and errexit would kill dash with zero
        # output on either stream - no URL, no warning, no hint.
        tsip="$("$ts" ip -4 2>/dev/null | head -1 || true)"
        [ -n "$tsip" ] && addr="$tsip"
      fi
      [ "$addr" = "127.0.0.1" ] \
        && af_warn "AF_DASH_BIND=tailnet but no tailnet address - binding to localhost, so this URL only opens on this machine" ;;
    local|'') addr="127.0.0.1" ;;
    *) addr="$bind" ;;
  esac
  af_log "http://$addr:$AF_DASH_PORT"

  export AF_DASH_PORT AF_NAME AF_USER AF_KEY AF_AGENT AF_SESSION AF_PROVIDER
  export AF_HOSTS AF_HOME AF_WORKDIR AF_CONFIG AF_SSH_CONF AF_CACHE
  exec node "$server" "$@"
}

# ---------------------------------------------------------------- say

# tmux session names end up inside quoted remote commands; keep them boring.
af_session_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-'; }

# Type text into a LIVE agent session instead of starting a new one, so you can
# steer a run that is already in flight (answer its question, redirect it) from
# a phone or a script.
#
# The text rides as base64 so no quote, backtick or newline in it can be
# reinterpreted by the two shells and one tmux parser it passes through.
af_tmux_type() {
  local host="$1" session="$2" payload
  payload="$(printf '%s' "$3" | base64 | tr -d '\n')"
  # send-keys -l types the text literally: without it a message containing a
  # word like "Enter" or "C-c" would be executed as a key name. -- keeps text
  # starting with a dash from being read as options.
  #
  # The pause before Enter is load-bearing: agent TUIs ingest a pasted line
  # asynchronously, and an Enter that lands first submits an empty turn and
  # leaves your text sitting in the box.
  af_ssh "$host" "tmux has-session -t '$session' 2>/dev/null || { echo 'no tmux session: $session'; exit 3; }
p=\$(printf %s '$payload' | base64 -d)
tmux send-keys -t '$session' -l -- \"\$p\"
sleep 0.3
tmux send-keys -t '$session' Enter"
}

cmd_say() {
  local host="" session="$AF_SESSION" text
  while [ $# -gt 0 ]; do
    case "$1" in
      -s|--session) session="${2:-}"; [ -n "$session" ] || af_die "--session needs a name"; shift 2 ;;
      -h|--help) af_log "usage: agentfleet say [-s session] <host> <text...>"; return 0 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  host="${1:-}"; [ -n "$host" ] || af_die "usage: agentfleet say [-s session] <host> <text...>"
  shift
  [ $# -gt 0 ] || af_die "nothing to say - usage: agentfleet say <host> <text...>"
  session="$(af_session_name "$session")"

  # Collapse newlines to spaces: in an agent's input box a literal newline
  # submits, so a three-line message becomes three half-formed turns. One
  # message, one Enter, one turn.
  text="$(printf '%s' "$*" | tr '\n\r\t' '   ')"

  local out
  out="$(af_tmux_type "$host" "$session" "$text" 2>&1)" \
    || af_die "could not type into $host:$session - $out"
  af_log "sent to $host:$session"
}

# ---------------------------------------------------------------- run

# The command that starts a non-interactive agent run. Both defaults hand the
# agent full autonomy on the machine, which is the point of a detached job: the
# machine is the sandbox. Override with AF_RUN_CMD if that is not what you want.
af_run_cmd() {
  if [ -n "${AF_RUN_CMD:-}" ]; then printf '%s' "$AF_RUN_CMD"; return 0; fi
  case "$AF_AGENT" in
    claude) printf '%s' 'claude -p --permission-mode bypassPermissions' ;;
    codex)  printf '%s' 'codex exec --dangerously-bypass-approvals-and-sandbox' ;;
    *) af_die "no run command known for AF_AGENT=$AF_AGENT - set AF_RUN_CMD" ;;
  esac
}

cmd_run() {
  local host="" prompt="" session="" cwd="$AF_WORKDIR" endopts=0
  local usage="usage: agentfleet run [-s session] [--cwd dir] <host> <prompt...>"
  while [ $# -gt 0 ]; do
    case "$1" in
      -s|--session) session="${2:-}"; [ -n "$session" ] || af_die "--session needs a name"; shift 2 ;;
      --cwd) cwd="${2:-}"; [ -n "$cwd" ] || af_die "--cwd needs a directory"; shift 2 ;;
      -h|--help) af_log "$usage   (prompt \"-\" reads stdin)"; return 0 ;;
      --) endopts=1; shift; break ;;
      *) break ;;
    esac
  done
  host="${1:-}"; [ -n "$host" ] || af_die "$usage"
  shift
  # `--` is also accepted after the host, where a prompt starting with a dash
  # actually needs it; consume it rather than prepending it to the prompt.
  if [ "${1:-}" = -- ]; then endopts=1; shift; fi
  [ $# -gt 0 ] || af_die "$usage"

  # THE PROMPT IS EVERY REMAINING WORD, like `say`. Reading only "$1" here meant
  # `agentfleet run w1 fix the flaky test` launched an autonomous,
  # permission-bypassing agent whose entire task was the word "fix", printed
  # "started", and dropped the other six words with no warning.
  #
  # A leading dash is a misplaced flag, not a task: `run w1 --cwd /tmp "do X"`
  # used to become the literal prompt "--cwd" while the flag was ignored. Refuse
  # it; `--` before the prompt is the escape hatch for text that really starts
  # with a dash.
  if [ "$endopts" = 0 ]; then
    case "$1" in
      -) ;;
      -*) af_die "flags go before <host>: $1 (to start a prompt with a dash, put -- before it)" ;;
    esac
  fi
  if [ $# -eq 1 ] && [ "$1" = - ]; then prompt="$(cat)"; else prompt="$*"; fi
  [ -n "$prompt" ] || af_die "empty prompt"
  [ -n "$session" ] || session="job-$(date +%H%M%S)"
  session="$(af_session_name "$session")"

  # A second job in the same session would type its prompt into the first one's
  # agent. Refuse rather than silently cross the streams.
  if af_ssh "$host" "tmux has-session -t '$session' 2>/dev/null"; then
    af_die "$host already has a tmux session named $session - pass --session <other>"
  fi

  # Resolved here, not inside the writer below: the writer runs in a pipeline
  # subshell, where a die would only kill the subshell and still leave a runner
  # script on the machine with no agent command in it.
  local agent; agent="$(af_run_cmd)"
  [ -n "$agent" ] || af_die "no run command for AF_AGENT=$AF_AGENT - set AF_RUN_CMD"

  local base="$AF_HOME/.cache/agentfleet"
  local pfile="$base/run-$session.prompt" rfile="$base/run-$session.sh"
  local log="$base/run-$session.log" events="$base/events.jsonl"
  af_ssh "$host" "mkdir -p '$base'"

  # HARD CONSTRAINTS is not boilerplate. A non-interactive agent process exits
  # at its final message and takes every child it spawned with it, so a job that
  # backgrounds its real work reports success having produced nothing, and an
  # artifact described but not yet written is lost with the process.
  printf '%s\n\n%s\n' "$prompt" \
'HARD CONSTRAINTS: run every command in the FOREGROUND and wait for it to finish. Never background anything. This is a non-interactive run: the process exits at your final message and kills any background children. Write every report or artifact to disk BEFORE your final message.' \
    | af_put_text "$host" "$pfile" 600

  af_run_script "$host" "$session" "$cwd" "$pfile" "$events" "$agent" \
    | af_put_text "$host" "$rfile" 700

  af_ssh "$host" "tmux new-session -d -s '$session' \"bash '$rfile' 2>&1 | tee '$log'\""
  af_log "$host:$session started"
  af_log "  watch:  agentfleet attach $host $session"
  af_log "  log:    $log"
}

af_run_script() {
  local host="$1" session="$2" cwd="$3" pfile="$4" events="$5" agent="$6"
  local notify=""
  # Baked in at write time, and omitted entirely when unconfigured, so the
  # machine never carries a half-written curl to nowhere.
  [ -n "${AF_NOTIFY_URL:-}" ] && notify="curl -s -m 5 -X POST '$AF_NOTIFY_URL' -d \"agentfleet: $host/$session finished rc=\$rc\" >/dev/null 2>&1 || true"
  cat <<EOF
#!/usr/bin/env bash
# written by: agentfleet run $host
export PATH="\$HOME/.local/bin:\$HOME/.bun/bin:/usr/local/bin:\$PATH"
# API keys and agent env live wherever your sync put them; a login shell is not
# guaranteed here because tmux starts this non-interactively.
for f in "\$HOME/.config/agentfleet/env" "\$HOME/.profile"; do
  [ -r "\$f" ] && . "\$f"
done
# The fan-out cap harden.sh sized for THIS machine's RAM. It lives in
# /etc/profile.d and is sourced from ~/.bashrc and ~/.zshenv, none of which a
# non-interactive, non-login bash reads - so without this line a detached job
# ran with the agent's laptop-sized default concurrency and could thrash the box
# into swap, while an interactive \`attach\` on the same machine was capped. Last
# so the machine's own value wins over anything synced down from a laptop.
[ -r '/etc/profile.d/$AF_NAME-agent.sh' ] && . '/etc/profile.d/$AF_NAME-agent.sh'
set -uo pipefail
cd '$cwd' || { echo "[agentfleet] no such workdir: $cwd"; exit 1; }
$agent "\$(cat '$pfile')"
rc=\$?
printf '{"host":"%s","session":"%s","rc":%s,"at":"%s"}\n' \\
  '$host' '$session' "\$rc" "\$(date -Is)" >> '$events'
$notify
echo "[agentfleet] DONE rc=\$rc \$(date)"
exit \$rc
EOF
}

# ---------------------------------------------------------------- attach, ssh, down

cmd_attach() {
  local host="${1:-}"; [ -n "$host" ] || af_die "usage: agentfleet attach <host> [session]"
  shift
  local session; session="$(af_session_name "${1:-$AF_SESSION}")"
  # new -A attaches if it is there and creates it if it is not, so this is also
  # how the first session on a fresh machine gets born. -c only applies to a
  # newly created one.
  af_ssh_tty "$host" "tmux new -A -s '$session' -c '$AF_WORKDIR'"
}

cmd_ssh() {
  local host="${1:-}"; [ -n "$host" ] || af_die "usage: agentfleet ssh <host> [cmd...]"
  shift
  if [ $# -eq 0 ]; then af_ssh_tty "$host"; else af_ssh "$host" "$@"; fi
}

# The recovery path for the failure that strands a whole fleet at once: your
# provider's firewall is pinned to the public IP you had when you created the
# machines, you changed networks, and now every healthy box refuses ssh. With
# AF_TAILNET=auto you may never need this, because the tailnet does not care
# what your egress IP is - which is exactly why it is the default.
cmd_unlock() {
  case "${1:-}" in
    -h|--help) af_log "usage: agentfleet unlock [host...]   (default: every host)"; return 0 ;;
  esac
  declare -f provider_unlock >/dev/null 2>&1 \
    || af_die "provider $AF_PROVIDER has no firewall for agentfleet to re-point"
  provider_unlock "$@"
}

# The other half of `down`. `up` cannot do this: it calls provider_create, which
# on a machine that already exists either fails outright or waits out the
# provision timeout on a box that is still deallocated. Resuming is its own verb.
#
# Deliberately does NOT provision afterwards. The disk survived the stop, so the
# machine comes back built; `provision` is there when you want it and is safe to
# re-run, but it should not be the price of turning a machine back on.
cmd_start() {
  # Named targets are required, exactly like `down`. Bare `start` defaulting to
  # the whole fleet is the one shape of this command that costs money by
  # accident; "all" is still there for when you mean it.
  case "${1:-}" in
    ''|-h|--help) af_log "usage: agentfleet start <host...|all>   (resume machines stopped with 'agentfleet down')"
                  [ -n "${1:-}" ]; return $? ;;
  esac
  declare -f provider_start >/dev/null 2>&1 \
    || af_die "provider $AF_PROVIDER does not manage machine lifecycle - start it yourself"

  local hosts host rc=0
  hosts="$(af_expand_hosts "$@")"
  [ -n "$hosts" ] || af_die "no machines to start"
  for host in $hosts; do
    if provider_start "$host"; then
      # Its address can change across a stop/start on a provider without a
      # static IP, and everything cached about it was resolved before the stop.
      AF_ADDR_CACHE=""
    else
      af_warn "$host: could not be started"
      rc=1
    fi
  done
  [ "$rc" = 0 ] && af_log "booting - it answers ssh in a minute or so: agentfleet ls"
  return $rc
}

cmd_down() {
  local usage="usage: agentfleet down <host> [--delete]"
  # Help is checked BEFORE the host is taken. The other way round, `down --help`
  # reads "--help" as a machine name and hands it to the provider, which then
  # reports a machine that does not exist as stopped, exit 0.
  case "${1:-}" in
    -h|--help) af_log "$usage"; return 0 ;;
  esac
  local host="${1:-}"; [ -n "$host" ] || af_die "$usage"
  shift
  local del=0
  case "${1:-}" in
    "") ;;
    --delete) del=1 ;;
    -h|--help) af_log "$usage"; return 0 ;;
    *) af_die "unknown flag: $1 (only --delete)" ;;
  esac
  command -v provider_stop >/dev/null 2>&1 \
    || af_die "provider $AF_PROVIDER does not manage machine lifecycle - stop $host yourself"

  if [ "$del" = 1 ]; then
    af_confirm "DELETE $host? the machine and its disk go away, along with anything on them" \
      || af_die "aborted"
    provider_stop "$host" --delete
    af_log "$host deleted. Check your provider for leftover disks or addresses it kept."
  else
    # Stopping is the cost lever: compute billing pauses, the disk stays and
    # keeps paying storage, and everything you synced survives the restart.
    provider_stop "$host"
    af_log "$host stopped: compute billing paused, disk kept."
    # NOT "agentfleet up $host": cmd_up only calls provider_create, so on a
    # machine that already exists that instruction re-runs creation and either
    # fails outright or waits out the provision timeout.
    af_log "To resume it: agentfleet start $host   (or the start button in 'agentfleet dash')"
    af_log "To destroy it instead: agentfleet down $host --delete"
  fi
}
