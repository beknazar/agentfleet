#!/usr/bin/env bash
# `sync` and `secrets`: your agent's configuration out to the machines, and the
# machines' work back to you.
#
# Three channels, deliberately different, because they carry different things.
#
#   config   AF_SYNC_PATHS   rsync, laptop -> machine, ONE WAY. The laptop is the
#            source of truth; an edit made on a machine is a scratch edit.
#            Two-way rsync of a config tree is how you lose a token or a dotfile.
#   repo     AF_REPO         plain git through your own remote, TWO WAY. This is
#            how work done by an agent reaches you. Conflicts BLOCK and are
#            named. Nothing is merged, stashed, checked out over, or reset.
#   secrets  AF_SECRETS      explicit, confirmed, one-way pushes you ask for.
#            Never on a command line, never carried by the other two channels.
#
# Keeping them separate is the point: a credential must not ride the config
# channel (it would be overwritten on every machine on every run) and machine
# state must not ride the repo channel (ten machines would fight over one file).

# Defaults for the variables this file adds. Set with ${x:-} because the config
# a user wrote before these existed must keep working under `set -u`.
AF_AUTOCOMMIT="${AF_AUTOCOMMIT:-0}"
AF_REPO_BRANCH="${AF_REPO_BRANCH:-main}"
AF_REPO_LOCAL_PATHS="${AF_REPO_LOCAL_PATHS:-}"
AF_MAX_BLOB_MB="${AF_MAX_BLOB_MB:-90}"
AF_SYNC_HEALTHCHECK="${AF_SYNC_HEALTHCHECK:-}"
AF_REQUIRED_ENV="${AF_REQUIRED_ENV:-}"

AF_SYNC_FORCE=0
AF_SYNC_SURFACE=""
AF_SECRETS_ENTRIES=""

_sync_blank() { [ -z "$(printf '%s' "${1:-}" | tr -d '[:space:]')" ]; }
_sync_sum()   { if command -v shasum >/dev/null 2>&1; then shasum; else sha1sum; fi | cut -d' ' -f1; }
_sync_q()     { printf '%q' "$1"; }

# Run one function per host at once, then print each machine's output as a
# block. Serial iteration is the wrong default here: one wedged box must never
# decide how long the other nine take.
_sync_fanout() {
  local fn="$1"; shift
  local tmp host pids="" rc=0 hrc
  tmp="$(mktemp -d)"
  for host in "$@"; do
    ( "$fn" "$host" >"$tmp/$host.out" 2>&1; printf '%s' "$?" >"$tmp/$host.rc" ) &
    pids="$pids $!"
  done
  # shellcheck disable=SC2086
  wait $pids 2>/dev/null || true
  for host in "$@"; do
    [ -s "$tmp/$host.out" ] && cat "$tmp/$host.out" >&2
    hrc="$(cat "$tmp/$host.rc" 2>/dev/null || printf 1)"
    [ "$hrc" = 0 ] || rc=1
  done
  rm -rf "$tmp"
  return $rc
}

# ---------------------------------------------------------------- config leg

# Strip trailing slashes off every AF_SYNC_PATHS entry, once, before anything
# reads the list.
#
# rsync treats a trailing slash on the SOURCE as "copy the contents of this
# directory", so `.claude/` - the way you get it from tab completion - sends the
# contents of ~/.claude into the destination's parent instead of recreating the
# directory. The intended target stays stale on every machine, the machine's
# $HOME (or the parent directory) collects the tree's top-level entries, and the
# run still prints "config pushed". lib/provision.sh uses trailing slashes
# deliberately for exactly that behaviour, so the semantics are load bearing
# elsewhere; they must simply never be reachable from user input.
#
# Normalising here rather than at each use keeps the credential guard, the
# change-detection hash and rsync all looking at the same string: a basename
# check against `.env/` sees an empty basename and lets it through.
_sync_normalize_paths() {
  local rel orig out=""
  for rel in $AF_SYNC_PATHS; do
    orig="$rel"
    while [ "${rel%/}" != "$rel" ]; do rel="${rel%/}"; done
    case "$rel" in
      ''|.) af_die "AF_SYNC_PATHS entry is not a path under \$HOME: '$orig' (use a name like .claude/skills)" ;;
    esac
    out="$out $rel"
  done
  AF_SYNC_PATHS="${out# }"
}

# The config channel overwrites whatever the machine has, on every run. Two
# kinds of file must therefore never be listed in it: credentials (they belong
# in AF_SECRETS, which is explicit and confirmed), and files that mix shared
# config with per-machine state - copying one of those whole clobbers the
# machine's own trust decisions, approvals and ids. Refuse loudly instead of
# discovering it after ten machines have been flattened.
_sync_reject_credential_paths() {
  local rel
  for rel in $AF_SYNC_PATHS; do
    case "$rel" in
      /*|*..*) af_die "AF_SYNC_PATHS entries are relative to \$HOME and may not contain '..': $rel" ;;
      .ssh|.ssh/*|.gnupg|.gnupg/*|.aws|.aws/*|.config/gcloud|.config/gcloud/*)
        af_die "refusing to rsync $rel - that is a credential store, not config. Use AF_SECRETS (see docs/security.md)." ;;
    esac
    case "${rel##*/}" in
      .env|.env.*|*.pem|*.key|*.p12|*.pfx|id_rsa*|id_ed25519*|.netrc|.npmrc|auth.json|credentials.json|.credentials.json)
        af_die "refusing to rsync $rel - credential-shaped, and this channel is a blind one-way overwrite. Use AF_SECRETS (see docs/security.md)." ;;
      .claude.json|*.local.json)
        af_die "refusing to rsync $rel - that file mixes shared config with per-machine state, so copying it whole destroys each machine's own state. Sync the directories around it instead." ;;
    esac
  done
}

# Cheap change detection over the whole config surface: name, size and mtime of
# every file under AF_SYNC_PATHS. When it matches what a machine last accepted,
# that machine's rsync leg is skipped entirely, so the common no-op run costs
# one local find instead of a network walk per machine. That is the difference
# between a sync you can put on a timer and one you cannot.
_sync_surface() {
  local rel sf fmt out=""
  # BSD and GNU stat disagree on format flags; probe once rather than per file.
  if stat -f '%m' . >/dev/null 2>&1; then sf=-f; fmt='%m %z %N'; else sf=-c; fmt='%Y %s %n'; fi
  for rel in $AF_SYNC_PATHS; do
    [ -e "$HOME/$rel" ] || continue
    out="$out$(find "$HOME/$rel" -type f -print0 2>/dev/null | sort -z | xargs -0 stat "$sf" "$fmt" 2>/dev/null)"
  done
  printf '%s' "$out" | _sync_sum
}

_sync_config_host() {
  local host="$1" rel parent dirs="" rc=0 stamp prev out v present=""
  stamp="$AF_CACHE/confhash-$host"
  # Per machine, not one global stamp: a machine added later has no stamp and
  # gets a full push instead of being skipped because nothing changed on disk.
  prev="$(cat "$stamp" 2>/dev/null || true)"
  if [ "$AF_SYNC_FORCE" != 1 ] && [ "$AF_SYNC_SURFACE" = "$prev" ]; then
    af_log "$host: config unchanged"
    return 0
  fi

  # Which paths exist is decided once here, so the rsync pass below cannot
  # disagree with this one. One round trip for every destination directory, not
  # one per path: with ten machines and a dozen paths the naive form is a
  # hundred ssh handshakes.
  for rel in $AF_SYNC_PATHS; do
    if [ ! -e "$HOME/$rel" ]; then af_warn "$host: no such local path, skipped: ~/$rel"; continue; fi
    present="$present $rel"
    parent="$(dirname "$rel")"
    [ "$parent" = . ] || dirs="$dirs$parent
"
  done
  if [ -n "$dirs" ]; then
    dirs="$(printf '%s' "$dirs" | sort -u | while IFS= read -r parent; do printf ' %s' "$(_sync_q "$parent")"; done)"
    af_ssh "$host" "mkdir -p$dirs" || { af_warn "$host: could not create destination directories"; return 1; }
  fi

  for rel in $present; do
    parent="$(dirname "$rel")"
    if [ "$parent" = . ]; then parent=""; else parent="$parent/"; fi
    # No --delete. A stale file on a machine is a nuisance; deleting one the
    # machine legitimately owns is data loss, and this side cannot tell which
    # is which.
    af_rsync "$host" "$HOME/$rel" "$parent" --exclude .git --exclude node_modules \
      || { af_warn "$host: rsync failed for ~/$rel"; rc=1; }
  done

  # Pushing config is exactly the operation that breaks the thing it maintains,
  # so the machine is asked to prove it still works afterwards.
  if [ -n "$AF_SYNC_HEALTHCHECK" ]; then
    if out="$(af_ssh "$host" "$AF_SYNC_HEALTHCHECK" 2>&1)"; then
      af_log "$host: healthcheck ok"
    else
      af_warn "$host: HEALTHCHECK FAILED: $(printf '%s' "${out:-no output}" | tail -2 | tr '\n' ' ')"
      rc=1
    fi
  fi

  # Overwriting a machine's shell startup files can silently strip the API key
  # the agent authenticates with, and the only symptom is every agent quietly
  # asking you to log in again. Note the quotes: `[ -n $VAR ]` with an empty
  # VAR is a one-argument test that is always TRUE, so the unquoted form can
  # never catch the thing it exists to catch. Login shell on purpose - that is
  # the environment the agent actually starts in.
  for v in $AF_REQUIRED_ENV; do
    af_ssh "$host" "\$SHELL -lc '[ -n \"\${$v:-}\" ]'" >/dev/null 2>&1 \
      || { af_warn "$host: required env var $v is empty in the agent's login shell"; rc=1; }
  done

  # Only stamp a clean run. Recording the hash after a partial failure leaves
  # that machine permanently stale with no further attempts.
  if [ "$rc" = 0 ]; then
    # Nothing existed locally, so no rsync ran and this machine may never have
    # been contacted at all. "config pushed" there reports a fleet that is
    # wired up when nothing was sent, and stamping it records a machine as up
    # to date on the strength of an empty surface.
    if [ -z "$present" ]; then
      af_log "$host: nothing to push (none of AF_SYNC_PATHS exist locally)"
      return 0
    fi
    mkdir -p "$AF_CACHE" && printf '%s' "$AF_SYNC_SURFACE" >"$stamp"
    af_log "$host: config pushed"
  fi
  return $rc
}

# ---------------------------------------------------------------- repo leg
#
# Runs on the machine, fed over ssh with a prologue that sets MODE, HOST,
# AUTOCOMMIT, BRANCH, REPO_DIR, REPO_URL, LOCAL_PATHS and MAX_BLOB.
# rc: 0 ok/no-op/skip, 1 blocked, 3 no repo and no AF_REPO to clone.
#
# Read with `read -d ''` rather than `$(cat <<EOF)`: bash 3.2 mis-parses a
# here-document nested inside a command substitution when the body contains
# case patterns, which this one does.
IFS='' read -r -d '' AF_REPO_ENGINE <<'AF_ENGINE_EOF' || true
set -euo pipefail
say()  { echo "[$HOST] $*"; }
fail() { say "$*"; exit 1; }

if [ ! -e "$REPO_DIR/.git" ]; then
  [ -n "$REPO_URL" ] || { say "MISSING: no repo at $REPO_DIR"; exit 3; }
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone -q "$REPO_URL" "$REPO_DIR" || fail "BLOCKED: clone failed (network/auth)"
  say "cloned into $REPO_DIR"
fi
cd "$REPO_DIR"

# Auto-committing or rebasing someone's in-flight work is unrecoverable, so
# anything that is not a clean primary checkout of $BRANCH is left exactly as
# found. A machine parked on a job branch is not a machine to "fix".
gd="$(git rev-parse --absolute-git-dir)"
case "$gd" in */worktrees/*) fail "REFUSE: linked worktree, not the primary clone" ;; esac
[ -e "$gd/MERGE_HEAD" ] && fail "REFUSE: merge in progress"
{ [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; } && fail "REFUSE: rebase in progress"
cur="$(git rev-parse --abbrev-ref HEAD)"
if [ "$cur" != "$BRANCH" ]; then say "SKIP: on branch $cur (sync only touches $BRANCH)"; exit 0; fi

# mkdir is the atomic primitive. The reap stops one crashed run from disabling
# sync on this machine forever.
LOCK="$gd/agentfleet-sync.lock"
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then rmdir "$LOCK" 2>/dev/null || true; fi
mkdir "$LOCK" 2>/dev/null || fail "LOCKED: another sync is running (rmdir $LOCK if stale)"
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

git fetch -q origin "$BRANCH" || fail "BLOCKED: git fetch failed (network/auth)"

dirty()   { git status --porcelain | wc -l | tr -d ' '; }
aheadN()  { git rev-list --count "origin/$BRANCH..HEAD"; }
behindN() { git rev-list --count "HEAD..origin/$BRANCH"; }
# One definition of "a dirty path", shared by the auto-commit note and the
# overlap check below: renames report as "old -> new", odd names come quoted.
# Two copies of this would eventually disagree about what dirty means.
dirtypaths() { git status --porcelain | cut -c4- | awk -F' -> ' '{print $NF}' | sed 's/^"//;s/"$//'; }

# --- 1. optional snapshot of whatever the agent left behind ------------------
if [ "$AUTOCOMMIT" = 1 ] && [ "$(dirty)" -gt 0 ]; then
  git add -A
  # .gitignore is the only thing standing between an agent's scratch files and
  # your git remote, so anything credential-shaped that got past it is unstaged
  # and named rather than published. This is a name check, not a scanner.
  git diff --cached --name-only -z | while IFS= read -r -d '' f; do
    case "${f##*/}" in
      .env.example|.env.sample|*.pub) continue ;;
      .env|.env.*|*.pem|*.key|*.p12|*.pfx|*.keystore|id_rsa*|id_ed25519*|.netrc|.npmrc|.htpasswd|credentials|credentials.json|.credentials.json|auth.json)
        git reset -q -- "$f"
        say "WARN: refused to auto-commit credential-shaped file: $f" ;;
    esac
  done
  # Tracked files that agentfleet itself rewrites per machine must never travel
  # home, or every machine spends every run undoing the last one.
  notes=""
  for p in $LOCAL_PATHS; do
    if ! git diff --cached --quiet -- "$p" 2>/dev/null; then git reset -q -- "$p"; notes="$notes$p "; fi
  done
  # One oversized artifact dropped by an agent otherwise blocks this machine's
  # push forever, and once committed it has to be scrubbed out of history.
  git diff --cached --name-only -z | while IFS= read -r -d '' f; do
    if [ -f "$f" ] && [ "$(wc -c < "$f")" -gt "$MAX_BLOB" ]; then
      git reset -q -- "$f"
      say "WARN: left oversized file uncommitted: $f"
    fi
  done
  if ! git diff --cached --quiet; then
    [ -n "$notes" ] && say "note: left machine-local path(s) uncommitted: $notes"
    # Deliberately NOT --no-verify. Your hooks are yours, and the one most
    # likely to fire here is the one scanning for secrets. A hook that rejects
    # this snapshot blocks the machine and says so, which you can fix; a hook
    # that was silently bypassed publishes whatever it was there to catch.
    git commit -q -m "agentfleet($HOST): working state $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      || fail "BLOCKED: commit rejected (pre-commit hook?) - resolve on this machine"
    say "committed working state"
  fi
fi

# --- 2. integrate origin/$BRANCH ---------------------------------------------
ahead="$(aheadN)"; behind="$(behindN)"
if [ "$behind" -gt 0 ]; then
  if [ "$ahead" -gt 0 ]; then
    [ "$(dirty)" -gt 0 ] && fail "BLOCKED: diverged (ahead $ahead / behind $behind) with $(dirty) dirty path(s); commit or clean first"
    # Rebase, never merge, and abort on the first conflict so the repo is left
    # exactly as found. A real concurrent edit has to surface as a named file:
    # conflict markers written into a data file nobody re-reads are silent
    # corruption.
    if ! git rebase -q "origin/$BRANCH" >/dev/null 2>&1; then
      conf="$(git diff --name-only --diff-filter=U | head -20)"
      git rebase --abort || true
      fail "BLOCKED: rebase conflict on: $(echo "$conf" | tr '\n' ' ')- resolve here manually"
    fi
    say "rebased $ahead local commit(s) onto origin/$BRANCH"
  else
    # Catch the collision before git does, and name it. Nothing is stashed,
    # checked out over, or reset.
    ov="$( { git diff --name-only HEAD "origin/$BRANCH" | sort -u; dirtypaths | sort -u; } | sort | uniq -d )"
    [ -n "$ov" ] && fail "BLOCKED: incoming commits touch dirty path(s): $(echo "$ov" | head -10 | tr '\n' ' ')($(echo "$ov" | wc -l | tr -d ' ') total)"
    git merge --ff-only -q "origin/$BRANCH" || fail "BLOCKED: fast-forward refused by git (untracked/dirty collision)"
    say "fast-forwarded $behind commit(s)"
  fi
fi

# --- 3. push ------------------------------------------------------------------
if [ "$MODE" = push ]; then
  ahead="$(aheadN)"
  if [ "$ahead" -gt 0 ]; then
    # With every machine syncing on the same tick, a non-fast-forward rejection
    # is the normal case, not the exception. Back off between attempts so the
    # three tries do not all land inside the same one-second push window, and
    # keep the last error: "push failed" with no cause is unactionable.
    ok=0; err=""
    for i in 1 2 3; do
      if err="$(git push -q origin "$BRANCH" 2>&1)"; then ok=1; break; fi
      sleep "$i"
      git fetch -q origin "$BRANCH" || true
      if [ "$(behindN)" -gt 0 ]; then
        git rebase -q "origin/$BRANCH" >/dev/null 2>&1 \
          || { git rebase --abort || true; fail "BLOCKED: push race + rebase conflict"; }
      fi
    done
    [ "$ok" = 1 ] || fail "BLOCKED: push failed after 3 attempts: $(echo "$err" | grep -v '^hint:' | tail -4 | tr '\n' ' ')"
    say "pushed $ahead commit(s)"
  fi
fi
exit 0
AF_ENGINE_EOF

_sync_repo_host() {
  local host="$1" mode="$2" rc=0 prologue
  prologue="MODE=$(_sync_q "$mode") HOST=$(_sync_q "$host") AUTOCOMMIT=$(_sync_q "$AF_AUTOCOMMIT")"
  prologue="$prologue BRANCH=$(_sync_q "$AF_REPO_BRANCH") REPO_DIR=$(_sync_q "$AF_WORKDIR")"
  prologue="$prologue REPO_URL=$(_sync_q "$AF_REPO") LOCAL_PATHS=$(_sync_q "$AF_REPO_LOCAL_PATHS")"
  prologue="$prologue MAX_BLOB=$(( AF_MAX_BLOB_MB * 1024 * 1024 ))"
  printf '%s\n%s\n' "$prologue" "$AF_REPO_ENGINE" | af_ssh "$host" 'bash -s' || rc=$?
  # ssh's own failure code. Untranslated, "could not reach it" reads exactly
  # like "reached it and it was fine" in an unattended log.
  if [ "$rc" = 255 ]; then af_log "[$host] UNREACHABLE (ssh exit 255)"; rc=1; fi
  [ "$rc" = 3 ] && rc=1
  return $rc
}

_sync_repo_push_host() { _sync_repo_host "$1" push; }
_sync_repo_pull_host() { _sync_repo_host "$1" pull; }

# ---------------------------------------------------------------- sync

_sync_usage() {
  cat >&2 <<'EOF'
usage: agentfleet sync <host|all> [--fast] [--force]

Pushes your agent configuration to the machines, and moves repo state both ways
through your git remote.

  --fast    config only, skip the repo
  --force   push config even if nothing changed since the last successful run

Config comes from AF_SYNC_PATHS (rsync, one way, $HOME-relative on both ends).
Repo comes from AF_REPO into AF_WORKDIR on AF_REPO_BRANCH. Work only travels
home if it is committed: set AF_AUTOCOMMIT=1 to snapshot dirty trees as well,
after reading what that means in docs/security.md.
EOF
}

cmd_sync() {
  local fast=0 targets="" rc=0 hosts

  while [ $# -gt 0 ]; do
    case "$1" in
      --fast)    fast=1 ;;
      --force)   AF_SYNC_FORCE=1 ;;
      -h|--help) _sync_usage; return 0 ;;
      -*)        af_die "sync: unknown flag: $1" ;;
      *)         targets="$targets $1" ;;
    esac
    shift
  done

  af_need rsync
  # shellcheck disable=SC2086
  hosts="$(af_expand_hosts $targets)"
  [ -n "$hosts" ] || af_die "no machines to sync (set AF_HOSTS, or create one with: agentfleet up <host>)"

  if _sync_blank "$AF_SYNC_PATHS"; then
    af_warn "AF_SYNC_PATHS is empty - no configuration to push"
  else
    # Before the credential guard, so it matches on the normalised name.
    _sync_normalize_paths
    _sync_reject_credential_paths
    AF_SYNC_SURFACE="$(_sync_surface)"
    # shellcheck disable=SC2086
    _sync_fanout _sync_config_host $hosts || rc=1
  fi

  if [ "$fast" = 1 ]; then
    af_log "--fast: skipped the repo"
  elif [ -z "$AF_REPO" ]; then
    af_log "AF_REPO is not set: skipped the repo"
  else
    case "$AF_MAX_BLOB_MB" in ''|*[!0-9]*) af_die "AF_MAX_BLOB_MB must be a whole number of MB: $AF_MAX_BLOB_MB" ;; esac
    # Phase order matters: every machine pushes before any machine pulls, so
    # work done on one machine reaches the others within a single run. Pulling
    # first leaves every machine a full cycle behind and doubles the push races.
    # shellcheck disable=SC2086
    _sync_fanout _sync_repo_push_host $hosts || rc=1
    # shellcheck disable=SC2086
    _sync_fanout _sync_repo_pull_host $hosts || rc=1
  fi

  return $rc
}

# ---------------------------------------------------------------- secrets
#
# AF_SECRETS is a plain list of local files copied to the machines over ssh.
# There is no vault and no two-way reconciliation: it does exactly what it says
# and nothing else, which is the only version of this that is safe to hand a
# stranger. Read docs/security.md before you put anything in it.
#
# Three kinds of file do not belong here, each for a reason someone has already
# paid for:
#
#   * single-session credentials. Some protocols bind a session to one client;
#     using the same session from two machines gets it killed on both, and the
#     machine that was working stops working. Log each machine in separately.
#   * rotating OAuth token files. Refresh tokens rotate on use, so overwriting
#     a machine that just refreshed can invalidate the token family for the
#     whole fleet at once.
#   * authorization grants. An approval granted on one machine must not widen
#     authority on the other nine just because a sync ran.
#
# Note also that the same filename can mean different things on different
# operating systems: a tool that keeps its token in a config file on Linux may
# keep it in the system keychain on your laptop, and pushing one over the other
# hands a machine a credential path that is stale by construction.

_secrets_usage() {
  cat >&2 <<'EOF'
usage: agentfleet secrets push [host|all]

Copies each file listed in AF_SECRETS to the machines over ssh, mode 600.
One "name|path" per line, path relative to $HOME on both ends; a bare path
works too. Prints the plan and asks first, unless AF_YES=1.
EOF
}

# Parse AF_SECRETS into "name<TAB>path" lines, failing on the whole list before
# anything is sent. A half-distributed set of credentials is worse than none.
_secrets_parse() {
  local line name rel out=""
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$line" ] || continue
    case "$line" in
      *'|'*) name="${line%%|*}"; rel="${line#*|}" ;;
      *)     rel="$line"; name="${rel##*/}" ;;
    esac
    case "$rel" in
      /*|'~'*|*..*) af_die "AF_SECRETS paths are relative to \$HOME and may not contain '..': $rel" ;;
    esac
    # The path is interpolated into a remote shell command, so keep it to
    # characters that cannot change what that command means.
    case "$rel" in
      *[!A-Za-z0-9._/-]*) af_die "AF_SECRETS path has unsupported characters: $rel" ;;
    esac
    [ -f "$HOME/$rel" ] || af_die "AF_SECRETS lists a file that does not exist: ~/$rel"
    [ -s "$HOME/$rel" ] || af_die "AF_SECRETS lists an empty file: ~/$rel (refusing to overwrite good copies with nothing)"
    out="$out$name	$rel
"
  done <<EOF
$AF_SECRETS
EOF
  printf '%s' "$out"
}

_secrets_push_host() {
  local host="$1" name rel rc=0 n=0
  while IFS="$(printf '\t')" read -r name rel; do
    [ -n "$rel" ] || continue
    # Two things this line is careful about, both of them real holes in the
    # tool this was extracted from:
    #
    #  1. the content goes over stdin, never in argv. Anything on a command
    #     line is readable by every other process on the box through `ps`, and
    #     may be logged by the shell or the CLI it was passed to.
    #  2. umask 077 is set BEFORE the file is created, not chmod'ed after.
    #     Creating it first and fixing the mode afterwards leaves a window
    #     where the cleartext secret is world readable.
    #
    # Written to a temp name and moved into place so an interrupted transfer
    # cannot leave a truncated credential behind.
    if af_ssh "$host" "umask 077; d=\"\$HOME/$rel\"; mkdir -p \"\$(dirname \"\$d\")\" && cat > \"\$d.af-new\" && mv \"\$d.af-new\" \"\$d\" && chmod 600 \"\$d\"" <"$HOME/$rel"; then
      n=$((n + 1))
    else
      af_warn "$host: FAILED to write ~/$rel"
      rc=1
    fi
  done <<EOF
$AF_SECRETS_ENTRIES
EOF
  af_log "$host: $n secret(s) written"
  return $rc
}

cmd_secrets() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift

  case "$sub" in
    push) ;;
    ''|-h|--help) _secrets_usage; return 0 ;;
    *) af_die "secrets: unknown subcommand: $sub (have: push)" ;;
  esac

  _sync_blank "$AF_SECRETS" && af_die "AF_SECRETS is empty - nothing to push (see docs/security.md)"

  local hosts count
  hosts="$(af_expand_hosts "$@")"
  [ -n "$hosts" ] || af_die "no machines to push to (set AF_HOSTS, or create one with: agentfleet up <host>)"

  # Check the status explicitly: _secrets_parse runs in a command substitution,
  # so its af_die only kills that subshell. Without this the command would
  # cheerfully report "0 secrets written" and exit 0 on a broken AF_SECRETS.
  AF_SECRETS_ENTRIES="$(_secrets_parse)" || af_die "AF_SECRETS is not usable, nothing sent"
  count="$(printf '%s' "$AF_SECRETS_ENTRIES" | grep -c . || true)"
  [ "$count" -gt 0 ] || af_die "AF_SECRETS parsed to nothing, nothing sent"

  # Say exactly what goes where before it goes anywhere.
  af_log "secrets push: $count file(s), over ssh, mode 600, overwriting whatever is there:"
  # Fed by a here-document, not a pipe: the parsed list has no trailing newline,
  # and `read` returning false on the last line would silently print nothing.
  while IFS="$(printf '\t')" read -r _ rel; do
    [ -n "$rel" ] && af_log "  ~/$rel"
  done <<EOF
$AF_SECRETS_ENTRIES
EOF
  af_log "to: $(printf '%s' "$hosts" | tr '\n' ' ')"
  af_log "not for single-session logins or rotating OAuth tokens (docs/security.md)"

  af_confirm "send these now?" || af_die "aborted, nothing sent"

  local rc=0
  # shellcheck disable=SC2086
  _sync_fanout _secrets_push_host $hosts || rc=1
  return $rc
}
