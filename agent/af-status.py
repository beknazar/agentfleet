#!/usr/bin/env python3
"""One useful line per machine: what is this agent doing, and does it need you?

Runs ON the machine, behind a timer, and writes ~/.cache/agentfleet/status.json.
The dashboard reads that file. Printing the raw last prompt and the raw last
assistant line was not enough - the column filled with debris like
"[Image: original 2400x1838, displayed at 2000x1532...]" - so this reads the
same transcript, throws the machinery away (base64, tool_result blobs, system
reminders, skill loads), and optionally asks a small model for one sentence:

    {"summary": "refactoring the auth middleware in api/session.ts",
     "state": "waiting_for_human", "needs": "asked whether to run the migration"}

Three rules make it safe to poll:

  * STATE IS DETERMINISTIC. The model never decides whether a machine is
    blocked. That comes from the transcript tail (dangling tool call, turn
    timestamps) and the live tmux pane (permission box, login prompt, auth
    banner, the spinner, background shells, subagents, the task widget).
  * DONE MEANS NOTHING IS OUTSTANDING. A machine once read "done" while its
    screen said "1 shell still running / 4 tasks (1 in progress, 2 open)".
    A finished TURN is not a finished JOB. Background shells, running subagents
    and in-progress tasks all keep a session in `working`.
  * THE MODEL IS NEVER IN THE REQUEST PATH. It is called only when the
    transcript changed AND at least AF_SUMMARY_MIN_INTERVAL seconds since the
    last call, and never by the dashboard path. A refresh costs roughly a tenth
    of a cent on a small model; an idle machine costs nothing because nothing
    changed. With no summarizer configured the deterministic path still fills
    every field.

Failure never blanks a row: every path (no transcript, no key, HTTP error,
model returns junk) still emits schema-valid JSON with a deterministic summary,
because a blank row and a healthy idle machine look identical to a human
scanning ten of them.

    af-status.py            # full run, refresh the cache, summarize if warranted
    af-status.py --cached   # dashboard path: print the cache with a fresh idleSec
    af-status.py --no-llm   # deterministic only, never spend a token
    af-status.py --work     # just the screen-scraped work signals, for debugging
    af-status.py --selftest # run the transcript-noise regression fixtures
"""
import copy
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.request
from datetime import datetime

HOME = os.path.expanduser("~")


# ---------------------------------------------------------------- config
# These programs run on the machine, where the shell config does not exist, so
# settings arrive either in the environment (systemd Environment=) or in a
# plain KEY=value file that `agentfleet provision` puts next to the agent's
# config. Provision writes it, not sync, so a changed setting reaches a machine
# on the next provision (which is idempotent and safe to re-run).
# The environment wins so a single run can be overridden by hand.
ENV_FILE = os.environ.get("AF_ENV_FILE", HOME + "/.config/agentfleet/agent.env")


def _load_env_file(path):
    vals = {}
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                vals[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return vals


_FILE_CFG = _load_env_file(ENV_FILE)


def cfg(name, default=""):
    v = os.environ.get(name)
    if v is None:
        v = _FILE_CFG.get(name)
    v = (v or "").strip()
    return v if v else default


def cfg_int(name, default):
    try:
        return int(cfg(name, "") or default)
    except ValueError:
        return default


AGENT = cfg("AF_AGENT", "claude").lower()
CACHE_DIR = cfg("AF_CACHE_DIR", HOME + "/.cache/agentfleet")
# AF_STATUS_OUT is the full path the service unit hands us, and it wins: the
# dashboard reads whatever that unit was told to write, so guessing a different
# location here would leave every row blank with nothing obviously broken.
CACHE = os.path.expanduser(cfg("AF_STATUS_OUT", os.path.join(CACHE_DIR, "status.json")))

MIN_LLM_INTERVAL = cfg_int("AF_SUMMARY_MIN_INTERVAL", 60)
SUMMARY_PROVIDER = cfg("AF_SUMMARY_PROVIDER", "none").lower()
SUMMARY_MODEL = cfg("AF_SUMMARY_MODEL", "")
SUMMARY_URL = cfg("AF_SUMMARY_URL", "")
SUMMARY_KEY_FILE = cfg("AF_SUMMARY_KEY_FILE", "")

TAIL_BYTES = 2 << 20                # only the last 2MB of a transcript is read
MAX_TURNS = 15                      # meaningful turns fed to the model
MAX_DIGEST = 3500                   # chars - caps input cost around 900 tokens
# tmux sessions read per tick, and rows captured from each. Four covers the
# interactive session plus three detached jobs; pick_sessions() puts the
# interactive one first so it is never the screen that gets cut. Sixty rows is
# more than any agent CLI's visible frame, which is all these are read for.
MAX_PANES = 4
PANE_LINES = 60
# Seconds since the transcript last moved before a session stops counting as
# working, and before a finished one stops reading as recently done rather than
# plain idle. Half a minute of think time is normal; half an hour is history.
WORKING_WINDOW = 90
DONE_WINDOW = 1800
# How long a dispatched tool may go unanswered before it reads as a stall. This
# was 300, which is shorter than an ordinary test suite or container build: with
# the transcript frozen for the whole of a foreground command, every long build
# in a detached job paged a human. The threshold alone is not the fix (see the
# pane fingerprint in detect_state), it just stops the clock running out during
# normal work.
PENDING_TOOL_STALL = 900


# ---------------------------------------------------------------- text hygiene
# Transcripts are full of smart quotes, dashes, emoji and box-drawing glyphs,
# and none of that belongs in a one-line table. Fold what has an ASCII
# equivalent, drop the decoration - but KEEP the letters of scripts that have no
# ASCII equivalent at all.
#
# The blunt version of this (NFKD, then encode("ascii", "ignore")) deleted CJK,
# Cyrillic, Arabic, Greek and Devanagari outright, because NFKD does not
# decompose them. A machine working on a Chinese prompt reported task "" and
# summary ","; with no foldable punctuation in the prompt it reported "idle at
# the prompt, nothing started" on a machine that had just been given work.
# Destroying the row is worse than a wide column - the JSON is escaped by
# json.dumps and the dashboard is UTF-8, so only terminal alignment ever wanted
# pure ASCII.
FOLD = {"‘": "'", "’": "'", "“": '"', "”": '"',
        "–": "-", "—": "-", "…": "...", " ": " ",
        "→": "->", "•": "-", "·": "-"}


NON_ASCII = re.compile(r"[^\x00-\x7F]+")


def _fold_run(m):
    """Fold one run of non-ASCII characters. Only runs reach here, so ASCII text
    - which is nearly all of a 2MB transcript tail - costs one regex scan and no
    per-character work."""
    out = []
    kept_script = False
    for ch in m.group(0):
        a = unicodedata.normalize("NFKD", ch).encode("ascii", "ignore").decode("ascii")
        if a:
            # Accented Latin, ligatures, fullwidth ASCII, ideographic space.
            out.append(a)
            kept_script = False
            continue
        cat = unicodedata.category(ch)
        if cat[0] in ("L", "N", "P"):
            out.append(ch)          # a real letter, digit or punctuation mark
            kept_script = True
        elif cat[0] == "M" and kept_script:
            # A combining mark belongs to the character before it. One that
            # follows an ASCII base is the leftover of a decomposed Latin letter
            # whose base was just folded, and keeping it would turn "cafe" back
            # into an accented string the table never asked for.
            out.append(ch)
        # everything else - emoji, box glyphs, arrows, control and format
        # characters - is decoration, and is dropped
    return "".join(out)


def fold_ascii(s, collapse_ws=True):
    """One folder for both paths. Splitting it once let accented text fold
    differently on the pane path than on the transcript path."""
    if not s:
        return ""
    for bad, good in FOLD.items():
        s = s.replace(bad, good)
    s = NON_ASCII.sub(_fold_run, s)
    return " ".join(s.split()) if collapse_ws else s


IMAGE_ARTIFACT = re.compile(r"\[Image:[^\]]*\]")
CMD_BLOCK = re.compile(r"<command-[a-z-]+>.*?</command-[a-z-]+>", re.S)
REMINDER = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)
B64 = re.compile(r"[A-Za-z0-9+/]{200,}={0,2}")

# Every harness wrapper tag is hyphenated - task-notification, tool-use-id,
# output-file, system-reminder, local-command-stdout - while real markup a
# person types in a prompt is not. So strip the hyphenated family WHOLESALE
# rather than chase each new tag the harness invents; the named blocks above
# were exactly that chase, and a `<task-notification>` walked straight past
# them into the task column. This is the same rule the dashboard's sanitizer
# already applies, and it has to exist in both places: the dashboard cleans
# what it DISPLAYS, this cleans what the field MEANS.
HARNESS_TAG = re.compile(r"</?[a-z][a-z0-9]*(?:-[a-z0-9]+)+[^>]*>", re.I)
# The same family with its contents: <tag ...> anything </tag>. Non-greedy and
# backreferenced, so a nested notification is consumed by its outer wrapper.
HARNESS_BLOCK = re.compile(r"<([a-z][a-z0-9]*(?:-[a-z0-9]+)+)\b[^>]*>.*?</\1\s*>", re.S | re.I)
HARNESS_OPEN = re.compile(r"^\s*<[a-z][a-z0-9]*(?:-[a-z0-9]+)+\b", re.I)
HAS_WORD = re.compile(r"[A-Za-z0-9]")


def scrub(s):
    """Strip the machinery before anything else sees the text. Also caps input
    cost: one pasted image would otherwise blow the digest budget on its own."""
    s = REMINDER.sub("", s)
    s = CMD_BLOCK.sub("", s)
    s = HARNESS_TAG.sub(" ", s)
    s = IMAGE_ARTIFACT.sub("", s)
    s = B64.sub("<blob>", s)
    return fold_ascii(s)


def harness_only(raw):
    """True when a turn sitting on the HUMAN's role was written by the harness.

    Stripping the tags is not enough on its own, and that is the whole trap. A
    completed background task arrives as a user message that is nothing but
    `<task-notification>...<summary>Background command "X" completed</summary>
    </task-notification>`; delete the tags and what is left is a fluent English
    sentence that reads exactly like something a person typed. It then becomes
    `task`, and the operator asking "what was the last message I gave that
    machine" is read back a notification he never wrote.

    So this decides the question the tag filter cannot: was the WHOLE turn
    machine-generated? Two ways to be sure. Nothing but hyphenated wrapper
    blocks and their ids, or a turn that OPENS with a hyphenated wrapper - a
    person does not begin a prompt with `<some-tag>`, and if one ever does, the
    cost is that his previous instruction stands rather than his newest, which
    is the survivable direction. Guessing wrong the other way puts machine
    noise in his ear as his own words.
    """
    if not raw:
        return False
    if HARNESS_OPEN.search(raw):
        return True
    body = HARNESS_TAG.sub(" ", HARNESS_BLOCK.sub(" ", raw))
    return not HAS_WORD.search(body)


# ---------------------------------------------------------------- pasted-call reject
# A human-role turn shaped like pasted conversation - a call transcript, a chat
# log, a greeting-heavy back-and-forth - is not an instruction, even though it
# carries no harness tag for harness_only() to catch. Read back to the operator
# as "your latest request" it is noise ("what was my request there?" answered
# with "Hey, good good, nice to meet you"); fed to the summarizer it describes
# the wrong work. So it falls through to the previous genuine human turn, exactly
# as a harness notification does - shared through not_an_instruction() below.
#
# The discriminator is SHAPE, never length, and never question count. A real
# multi-sentence instruction - even a long debugging ask that is full of
# questions and opens with an ordinary word ("why is staging still broken? did
# that migration apply...") - must pass. The old code failed exactly there: it
# rejected on question count plus a non-imperative head, so genuine
# question-dense instructions vanished; and it leaned on a broad imperative
# head-whitelist (then/now/we/the...), so a paste opening with one of those
# words slipped through. The bias is toward PASS: a shown piece of garbage is
# annoying, a hidden real instruction is worse. Two precise signals decide it:
#   * transcript structure - conversational speaker labels or clock timestamps,
#   * SOCIAL-PLEASANTRY density - greetings, farewells, backchannels and address
#     terms, counted across families. A pasted call is dense with these across
#     several families; a real instruction carries technical nouns and at most a
#     stray "yeah" or "thanks" in one family.

# Four families of social-pleasantry markers. A real work instruction hits none
# of these, or one stray marker in one family; a pasted call hits many across
# several families. Each family is counted separately so the reject can require
# breadth (two families) rather than a single word repeated.
_GREETING_MARK = re.compile(
    r"\b(?:hey+|hello|howdy)\b"
    r"|how(?:'?s| is| are| have|'?re| you)?\s+"
    r"(?:you|it going|things|been|are things|you been|you doing|you holding up|have you been)"
    r"|how'?s\s+(?:the|things)\b"
    r"|nice to (?:meet|see)(?: you)?"
    r"|(?:good|great|nice) to (?:see|meet) you"
    r"|(?:great|good) to connect"
    r"|long time no see"
    r"|(?:been|its been)\s+(?:ages|way too long|too long)"
    r"|good (?:morning|afternoon|evening|night)",
    re.I)
_FAREWELL_MARK = re.compile(
    r"talk (?:to you )?(?:soon|later)"
    r"|take care"
    r"|\bcheers\b"
    r"|see you(?: soon| later| around)?"
    r"|catch up"
    r"|(?:great|good) seeing you",
    re.I)
_BACKCHANNEL_MARK = re.compile(
    r"\bhaha+\b|\blol\b"
    r"|\b(?:yeah|yep|yup|nah|nope)\b"
    r"|oh (?:nice|cool|man|thats|you know)"
    r"|good[,.\s]+good"
    r"|no worries|no problem"
    r"|for sure|cool cool|busy busy"
    r"|sounds good|glad to hear|my pleasure"
    r"|\btotally\b|\bi bet\b|you know how it is",
    re.I)
_ADDRESS_MARK = re.compile(r"\b(?:man|buddy|friend|dude|bro|pal|mate)\b", re.I)
_SOCIAL_FAMILIES = (_GREETING_MARK, _FAREWELL_MARK, _BACKCHANNEL_MARK, _ADDRESS_MARK)


def _social_markers(raw):
    """(families_hit, distinct_markers) across the four social-pleasantry
    families. Distinct so a word repeated ten times ("yeah ... yeah ... yeah")
    counts once, and breadth across families is what marks conversation."""
    families = 0
    distinct = set()
    for rx in _SOCIAL_FAMILIES:
        hits = {m.group(0).lower() for m in rx.finditer(raw)}
        if hits:
            families += 1
            distinct |= hits
    return families, len(distinct)


# Speaker labels only for a whitelist of conversational roles - a customer call
# reads "Agent:" / "Caller:". Instruction labels a person types (Task:, Context:,
# Notes:, Acceptance:) are deliberately NOT here, so a structured instruction is
# never mistaken for a transcript.
_SPEAKER = re.compile(
    r"(?:^|\n)\s*(?:speaker\s*\d*|caller|callee|agent|customer|client"
    r"|rep(?:resentative)?|host|guest|interviewer|interviewee|operator)\s*:",
    re.I)

_TIMESTAMP = re.compile(r"(?<!\d)\d{1,2}:\d{2}(?::\d{2})?(?!\d)")

_WORD_RE = re.compile(r"[A-Za-z][A-Za-z'-]*")

# Past the length of a typed instruction. Below it the density test does not run
# - a short paste and a short instruction are indistinguishable, and the
# confirmed incident is a long paste - so a terse imperative ("run the tests")
# is permanently safe. The one exception is a short turn SATURATED with social
# markers across families (a clipped call greeting), which still rejects.
PASTE_MIN_WORDS = 40


def looks_like_pasted_conversation(raw):
    """True when a human-role turn reads as pasted conversation, not a command.

    Discriminates on SOCIAL-PLEASANTRY density, never on question count and never
    on an imperative-head whitelist. A long, question-dense debugging ask with
    technical nouns and no social cluster PASSES, whatever word it opens with; a
    pasted call is dense with greetings, farewells, backchannels and address
    terms across several families and REJECTS. Called on the RAW turn (before
    scrub) at the same points harness_only() is, and again defensively on the
    digest turns, so a paste can reach neither the recorded instruction nor the
    summarizer input.
    """
    if not raw:
        return False
    n = len(_WORD_RE.findall(raw))
    if n == 0:
        return False
    families, distinct = _social_markers(raw)

    # Short turns pass, EXCEPT a clipped call greeting saturated with social
    # markers across at least two families.
    if n < PASTE_MIN_WORDS:
        return families >= 2 and distinct >= 4

    # Transcript structure is decisive on its own at this length.
    if len(_SPEAKER.findall(raw)) >= 2:
        return True
    if len(_TIMESTAMP.findall(raw)) >= 3:
        return True

    # Social-marker density: breadth across families, or several markers total
    # scaled to length. A lone stray "yeah" or "thanks" (one family, one marker)
    # never crosses either gate.
    if families >= 2 and distinct >= 3:
        return True
    if distinct >= max(5, n // 20):
        return True
    return False


def not_an_instruction(raw):
    """A human-role turn that must NOT become task, lastInstruction, or a digest
    turn: either written by the harness (harness_only) or pasted conversation
    (looks_like_pasted_conversation). Both fall through to the previous genuine
    human turn the same way - one gate, one behaviour, no parallel system."""
    return harness_only(raw) or looks_like_pasted_conversation(raw)


def text_of(content):
    """Concatenate the text blocks of a message, ignoring everything else.
    Codex labels its blocks input_text/output_text, Claude Code uses text."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for b in content:
            if isinstance(b, dict) and b.get("type") in ("text", "input_text", "output_text"):
                out.append(b.get("text") or "")
        return " ".join(out)
    return ""


def brief(inp):
    """One short, recognizable argument per tool call - what a human scans for."""
    if isinstance(inp, str):
        try:
            inp = json.loads(inp)
        except ValueError:
            return fold_ascii(inp)[:70]
    if not isinstance(inp, dict):
        return ""
    for k in ("command", "cmd", "file_path", "pattern", "query", "path", "url",
              "prompt", "skill", "description", "input", "task_name"):
        v = inp.get(k)
        if isinstance(v, str) and v.strip():
            return fold_ascii(v)[:70]
    return ""


def iso_epoch(ts):
    """Transcript timestamps are ISO-8601, usually UTC with a Z. Hand-rolling
    this with time.timezone silently drifts an hour under DST, which reads as
    "just active" on a machine that stalled an hour ago."""
    try:
        dt = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return 0.0
    if dt.tzinfo is None:
        dt = dt.astimezone()
    return dt.timestamp()


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


# ---------------------------------------------------------------- adapters
# Everything that knows what a specific agent's transcript and TUI look like
# lives here. The state machine below is agent-neutral. When an agent changes
# its on-screen copy, the liveness regex stops matching and the machine reads
# `done` - the dangerous direction - so these are the first thing to check when
# a busy machine starts reporting itself free.

CLAUDE_NOISE = (
    "Base directory for this skill:",   # skill loads arrive as user messages
    "Caveat:",
    "[Request interrupted",
    "<system-reminder>",
    "<command-name>",
    "<command-message>",
    "<local-command",
)
CODEX_NOISE = (
    "<environment_context>",
    "<app-context>",
    "<user_instructions>",
    "# AGENTS.md instructions",
)
# The desktop client prefixes a prompt with the files that were dragged in, so
# the actual ask sits below a marker. Without this the task column reads
# "Files mentioned by the user: ## Screenshot ...".
CODEX_REQUEST = re.compile(r"^#+\s*(?:My )?request[^\n]*\n", re.I | re.M)

# Todo-widget glyphs, used when the "N tasks (...)" header has scrolled off but
# the list has not. The only non-ASCII literals in the adapters, matched against
# the raw screen before any folding. Both TUIs draw the same set; one that draws
# its own overrides task_glyphs in ADAPTERS below.
TASK_GLYPHS = {"inProgress": "◼■☒", "open": "◻□☐", "done": "✔✓✅"}


def _noisy(body, noise):
    """Not every entry on the human's role came from the human. Skill loads,
    slash commands, tool results, injected instructions and local-command
    caveats all arrive there, and without this filter the dashboard's task
    column reads "Base directory for this skill: ..." instead of the ask."""
    return (not body
            or body.startswith(noise)
            or body.startswith("/")
            or "tool_result" in body[:40])


# The three events every adapter reports, and the facts each one updates. An
# adapter below only has to say WHICH of its entries is a human turn, an agent
# turn or a tool call.
def set_task(f, body):
    """The standing instruction, and when it arrived.

    parse() sets entry_ts before every entry. A ts of 0 means the entry carried
    no clock of its own - `last-prompt` records do not - and an unknown age is
    then reported as unknown rather than as "just now".
    """
    f["task"] = body
    f["task_ts"] = f.get("entry_ts", 0.0)


def add_human(f, body):
    set_task(f, body)
    f["turns"].append(("human", body))
    f["last_role"] = "user"


def add_agent(f, said):
    f["last_text"] = said
    f["turns"].append(("agent", said))
    f["last_role"] = "assistant"


def add_tool(f, ctx, name, call_id, args):
    f["tool"] = name
    ctx["pending"][call_id] = name
    f["turns"].append(("tool", "%s(%s)" % (name, brief(args))))
    f["last_role"] = "assistant"


def claude_entry(e, f, ctx):
    etype = e.get("type")

    # The agent maintains these itself - free, already-clean signal. Tolerate
    # their absence: a version bump that drops them must not break the row.
    if etype == "ai-title":
        f["title"] = fold_ascii(e.get("aiTitle") or "")
        return
    if etype == "last-prompt":
        # Same filter as the human role below: a dragged screenshot path, a
        # slash command or a harness notification is not the task, and reads as
        # garbage on a dashboard.
        #
        # A FALLBACK, not an override, and that is measured rather than
        # assumed. The agent rewrites this record periodically with whatever it
        # last saw, so a stale copy keeps landing AFTER newer turns: on one machine it
        # pinned `task` to "go all" while the operator's live instruction, dated
        # minutes earlier in the same tail, was "Continue task #13 (voices V2
        # closing)". It also carries no timestamp, so letting it win throws away
        # the age of an instruction we do know the age of. It never holds
        # anything a dated turn does not - the harness writes both when the
        # human hits enter - so it is only consulted when the tail window
        # contains no dated human turn at all.
        if f["task_ts"]:
            return
        raw = e.get("lastPrompt") or ""
        if not_an_instruction(raw):
            return
        p = scrub(raw)
        if p and not _noisy(p, CLAUDE_NOISE):
            set_task(f, p)
        return
    if etype == "queue-operation":
        # A consumed queue entry that is never cleared keeps showing up in the
        # digest as work that has not started, long after it has.
        if e.get("operation") == "add":
            f["queued"] = scrub(e.get("content") or "")[:120]
        else:
            f["queued"] = ""
        return
    if etype not in ("user", "assistant"):
        return

    msg = e.get("message") or {}
    role = msg.get("role") or etype
    content = msg.get("content")
    blocks = content if isinstance(content, list) else []

    if role == "user":
        for b in blocks:
            if isinstance(b, dict) and b.get("type") == "tool_result":
                ctx["pending"].pop(b.get("tool_use_id"), None)
                if b.get("is_error"):
                    raw = b.get("content")
                    f["last_error"] = scrub(
                        raw if isinstance(raw, str) else text_of(raw))[:200]
        raw = text_of(content)
        # Tested on the RAW text, before scrub() takes the tags off: once they
        # are gone a notification is indistinguishable from a sentence. The same
        # gate also drops a pasted call transcript, which carries no tag at all.
        if not_an_instruction(raw):
            # Not a human turn at all, so nothing is recorded and `task` keeps
            # the previous genuine instruction. Emitting "" here would blank the
            # field every time a background command reported back.
            return
        body = scrub(raw).strip()
        if not _noisy(body, CLAUDE_NOISE):
            add_human(f, body)

    elif role == "assistant":
        said = scrub(text_of(content)).strip()
        if said:
            add_agent(f, said)
        for b in blocks:
            if isinstance(b, dict) and b.get("type") == "tool_use":
                add_tool(f, ctx, b.get("name", ""), b.get("id"), b.get("input"))


def codex_entry(e, f, ctx):
    etype = e.get("type")
    p = e.get("payload") if isinstance(e.get("payload"), dict) else {}
    ptype = p.get("type")

    if etype == "event_msg":
        if ptype == "user_message":
            ctx["saw_events"] = True
            raw = p.get("message") or ""
            m = CODEX_REQUEST.search(raw)
            if m:
                raw = raw[m.end():]
            if not_an_instruction(raw):
                return
            body = scrub(raw).strip()
            if not _noisy(body, CODEX_NOISE):
                add_human(f, body)
        elif ptype == "agent_message":
            ctx["saw_events"] = True
            said = scrub(p.get("message") or "").strip()
            if said:
                add_agent(f, said)
        return

    if etype != "response_item":
        return

    if ptype in ("function_call", "custom_tool_call", "local_shell_call"):
        arg = p.get("input") if p.get("input") is not None else p.get("arguments")
        add_tool(f, ctx, p.get("name") or ptype,
                 p.get("call_id") or p.get("id"), arg)
        return
    if ptype in ("function_call_output", "custom_tool_call_output"):
        ctx["pending"].pop(p.get("call_id") or p.get("id"), None)
        return

    # Message items duplicate the event stream and carry the injected
    # instruction dumps, so they are only used when no event stream was
    # written at all (headless runs, older builds).
    if ptype == "message":
        role = p.get("role")
        if role not in ("user", "assistant"):
            return
        raw = text_of(p.get("content"))
        if role == "user" and not_an_instruction(raw):
            return
        body = scrub(raw).strip()
        if role == "user" and _noisy(body, CODEX_NOISE):
            return
        if body:
            ctx["alt"].append((role, body))


ADAPTERS = {
    "claude": {
        "transcripts": "~/.claude/projects/**/*.jsonl",
        "entry": claude_entry,
        # The live spinner. "esc to interrupt" is the only anchor that cannot
        # survive a completed turn; the parenthesised token counter is the same
        # line's other half.
        "live": re.compile(r"esc to interrupt|\((?:\d+[hms]\s*)+[^)\n]{0,60}tokens", re.I),
        "signals": [
            ("login", re.compile(r"Please run /login|Invalid API key|OAuth token has expired"
                                 r"|credit balance is too low|/login to", re.I)),
            ("permission", re.compile(r"Do you want to (proceed|make this edit|create)"
                                      r"|Yes, and don't ask again|Allow .* to run"
                                      r"|permission to use|\bWaiting for approval", re.I)),
            ("mcp", re.compile(r"MCP servers? needs? authentication|run /mcp", re.I)),
        ],
        # The bottom line the TUI redraws every frame. "bypass permissions"
        # only appears when the agent runs with prompts disabled, which is the
        # usual fleet setup, so the other alternatives carry unattended runs.
        "footer": re.compile(r"--\s*(?:INSERT|NORMAL|VISUAL)\s*--"
                             r"|bypass permissions|accept edits|plan mode"
                             r"|\? for shortcuts|shift\+tab to cycle", re.I),
        "task_glyphs": TASK_GLYPHS,
    },
    # Best effort: the on-screen copy below is not as heavily field-tested as
    # the Claude Code set. If a busy machine reports itself free, start here.
    "codex": {
        "transcripts": "~/.codex/sessions/**/*.jsonl",
        "entry": codex_entry,
        "live": re.compile(r"esc to interrupt|\(\s*\d+[hms][^)\n]{0,60}tokens", re.I),
        "signals": [
            ("login", re.compile(r"Please run codex login|Not logged in"
                                 r"|Invalid API key|token has expired"
                                 r"|insufficient_quota|credit balance is too low", re.I)),
            ("permission", re.compile(r"Allow command\?|Approve (?:this )?command"
                                      r"|Do you want to (?:run|allow|proceed)"
                                      r"|requires approval|\bWaiting for approval", re.I)),
            ("mcp", re.compile(r"MCP servers? needs? authentication", re.I)),
        ],
        "footer": re.compile(r"send\s+\S*\s*newline|\bEsc\b.*\binterrupt\b"
                             r"|\? for shortcuts|ctrl\+c to quit", re.I),
        "task_glyphs": TASK_GLYPHS,
    },
}
AD = ADAPTERS.get(AGENT) or ADAPTERS["claude"]

# Errors are recognized the same way for every agent: it is the terminal, not
# the agent, that prints them.
#
# `fatal:` used to be in this list and had to come out. It is how git reports
# every ordinary condition an agent walks into - "fatal: not a git repository",
# "fatal: couldn't find remote ref", "fatal: pathspec did not match any files" -
# and one such line anywhere in the 60-line scrollback pinned a finished, quiet
# machine in `error` with needs "traceback in terminal" until something scrolled
# it away, which on a finished pane is never. A subprocess failing is not the
# session failing: a tool error the agent actually got back arrives in the
# transcript as is_error and is handled above by f["last_error"].
ERROR_SIGNAL = re.compile(r"^\s*(Traceback \(most recent call last\)"
                          r"|API Error|Error: connection)", re.M)


# ---------------------------------------------------------------- transcript
# The transcript glob has to be recursive (Codex files sit under
# sessions/YYYY/MM/DD/), and that sweeps in far more than sessions. Claude Code
# also writes, under the same tree:
#
#   <session>/subagents/agent-<hex>.jsonl              one per dispatched agent
#   <session>/subagents/workflows/<wf>/journal.jsonl   {"type":"started"} lines
#   .../skill-injections.jsonl
#
# On a machine that dispatches subagents those outnumber real transcripts ten to
# one and are written constantly, so max(mtime) lands on one of them. A journal
# parses to nothing and the row reads `idle` while the machine is working; a
# subagent file describes the subagent instead of the session and makes the
# cached `_path` flip on nearly every tick, which defeats AF_SUMMARY_MIN_INTERVAL
# because the cache-reuse branch only fires for the same session. Idle on a busy
# machine is the single worst thing this program can say, so only real session
# transcripts are eligible.
NOT_A_TRANSCRIPT = ("journal.jsonl", "skill-injections.jsonl")


def _is_transcript(path):
    if "subagents" in path.split(os.sep):
        return False
    if os.path.basename(path) in NOT_A_TRANSCRIPT:
        return False
    try:
        # An empty file is a session that has not written a turn yet; picking it
        # would hide the session that has. The dashboard's own probe skips these
        # too, and the two must agree on which file is "the" transcript.
        return os.path.getsize(path) > 0
    except OSError:
        return False


def newest_transcript():
    pattern = cfg("AF_STATUS_TRANSCRIPTS", AD["transcripts"])
    newest, newest_mtime = None, -1.0
    for path in glob.glob(os.path.expanduser(pattern), recursive=True):
        if not _is_transcript(path):
            continue
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue        # one file rotated away mid-scan must not lose them all
        if mtime > newest_mtime:
            newest, newest_mtime = path, mtime
    return newest


def tail_lines(path):
    """Last TAIL_BYTES of the file, minus the partial first line.

    Transcripts grow into tens of megabytes and this runs on a timer, so a full
    parse would dominate the box. The readline() after the seek is the
    non-obvious half: without it json.loads sees a truncated line every run."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > TAIL_BYTES:
                fh.seek(size - TAIL_BYTES)
                fh.readline()
            return fh.read().decode("utf-8", "ignore").splitlines()
    except OSError:
        return []


def parse(path):
    """Walk the transcript tail into the facts the state machine and the model
    prompt both need. One pass, no model."""
    f = {
        "title": "", "task": "", "task_ts": 0.0, "turns": [], "tool": "",
        "last_text": "", "last_role": "", "last_ts": 0.0, "entry_ts": 0.0,
        "pending_tools": [], "last_error": "", "queued": "",
    }
    ctx = {"pending": {}, "alt": [], "saw_events": False}

    for line in tail_lines(path):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        # A line that decodes to null, a bare list or a scalar is valid JSON and
        # not an entry. Reading .timestamp off it raises out of parse(), out of
        # run(), and lands in main()'s blanket handler - so that one line stops
        # the machine's status advancing for as long as it stays in the tail
        # window, not just for one tick. The dashboard's own parser has the same
        # guard.
        if not isinstance(e, dict):
            continue
        try:
            ts = e.get("timestamp")
            # Handed to the adapter through f so add_human can date the
            # instruction without every adapter having to pass it along.
            f["entry_ts"] = iso_epoch(ts) if ts else 0.0
            if f["entry_ts"]:
                f["last_ts"] = max(f["last_ts"], f["entry_ts"])
            AD["entry"](e, f, ctx)
        except (AttributeError, KeyError, TypeError, ValueError):
            continue        # one malformed entry must not lose the whole tail

    if ctx["alt"] and not ctx["saw_events"]:
        # Replayed out of order relative to their own entries, so the clock from
        # the last entry read does not belong to them. Unknown, not wrong.
        f["entry_ts"] = 0.0
        for role, body in ctx["alt"]:
            if role == "user":
                add_human(f, body)
            else:
                add_agent(f, body)

    f["pending_tools"] = sorted(set(ctx["pending"].values()))
    return f


# ---------------------------------------------------------------- tmux pane
# The transcript cannot see a permission box or a login prompt - those are
# drawn but never written to disk. The pane is the only place they exist, so
# reading only the JSONL would lose every signal that actually needs a human.

# ---- work-in-flight signals, which exist ONLY on screen ---------------------
# A finished turn leaves its final frame behind: a screen can still read
# "Brewed for 46s - 1 shell still running" from a background command that has
# since reported "completed". So the SCROLLBACK is not evidence of live work -
# the mode footer is, because the TUI redraws that bottom line every frame:
#
#   -- INSERT -- >> bypass permissions on - 1 shell            <- one shell live
#   -- INSERT -- >> bypass permissions on (shift+tab to cycle) - <- for agents
#
# A footer with no shell token is an authoritative zero, which is what keeps a
# session from inheriting its own stale turn line forever.
#
# The lookbehind on the counts stops "#3 shells" (a session index) and the tail
# of a longer number from being read as the count: one wildly wrong shell
# number pins a machine in `working` and it never recovers.
FOOTER_SHELLS = re.compile(r"(?<![#\d])\b(\d{1,3})\s+shells?\b", re.I)
FOOTER_AGENTS = re.compile(r"(?<![#\d])\b(\d{1,3})\s+agents?\b", re.I)

SHELLS_STILL = re.compile(r"\b(\d{1,3})\s+shells?\s+still\s+running\b", re.I)
BG_SETTLED = re.compile(r"Background (?:command|Bash|shell)\b[^\n]*"
                        r"(?:completed|finished|failed|exit code)", re.I)

TASKS_LINE = re.compile(r"\b(\d{1,3})\s+tasks?\s*\(([^)\n]*)\)")
TASK_DONE = re.compile(r"(\d{1,3})\s+done\b", re.I)
TASK_PROG = re.compile(r"(\d{1,3})\s+in\s+progress\b", re.I)
TASK_OPEN = re.compile(r"(\d{1,3})\s+(?:open|pending|todo)\b", re.I)

AGENT_FINISHED = re.compile(r'Agent\s+"([^"\n]{1,80})"\s+(?:finished|completed|done)\b', re.I)
AGENT_STARTED = re.compile(r'Agent\s+"([^"\n]{1,80})"\s+(?:running|started|launched)\b', re.I)
AGENTS_FRACTION = re.compile(r"\b(\d{1,3})\s*/\s*(\d{1,3})\s+agents?\s+done\b", re.I)
AGENTS_RUNNING = re.compile(r"\b(\d{1,3})\s+agents?\s+(?:running|in flight|still running)\b", re.I)


def pick_sessions(listing):
    """Order tmux sessions so the ones that matter survive the MAX_PANES cut.

    tmux lists sessions in NAME order, and `agentfleet run` names its detached
    jobs `job-HHMMSS`, which sorts before the default interactive session
    `main`. Taking the first MAX_PANES names therefore drops `main` as soon as
    four jobs are up - and `main` is the only session that can ever draw a
    permission box or a login prompt, because run jobs launch the agent with
    prompting disabled. Four busy jobs would silently hide the one screen with a
    human waiting on it. So: the configured interactive session first, then the
    rest most-recently-active first.

    `listing` is one "<session_activity> <name>" per line. Older tmux expands
    an unknown format variable to nothing, so a line that is just a name still
    parses - it simply has no activity to sort by.
    """
    rows = []
    for line in listing.splitlines():
        line = line.strip()
        if not line:
            continue
        head, _, rest = line.partition(" ")
        if rest.strip() and head.isdigit():
            rows.append((int(head), rest.strip()))
        else:
            rows.append((0, line))
    rows.sort(key=lambda r: -r[0])
    main = cfg("AF_SESSION", "main")
    names = [n for _, n in rows if n]
    return [n for n in names if n == main] + [n for n in names if n != main]


def pane_tail():
    """Return (combined_ascii_text, [per-session raw text], panes).

    The flags want one flat ASCII blob; the work-in-flight parser wants each
    session's screen intact, because "which line is the footer" is positional
    and separator glyphs do not survive the ASCII fold.

    `panes` is the number of screens captured, or -1 when the probe itself
    failed. That distinction matters: a failed probe leaves every flag False
    and every count zero, which is indistinguishable from a quiet machine and
    lets a busy one be reported `done`. Callers must not treat -1 as quiet.
    """
    try:
        out = subprocess.run(["tmux", "ls", "-F", "#{session_activity} #{session_name}"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             universal_newlines=True, timeout=5)
    except Exception:
        return "", [], -1        # no tmux installed, or it hung past the timeout
    if out.returncode != 0:
        # tmux exits nonzero when no server is running. That is an authoritative
        # zero sessions, not a broken probe.
        #
        # Two spellings, and the second one is the common case: tmux says "no
        # server running on <socket>" only once its socket directory exists, and
        # on a machine where tmux has never been started there is no directory
        # to look in - it says "error connecting to /tmp/tmux-1000/default (No
        # such file or directory)" instead. Reading that as a failed probe made
        # every freshly provisioned machine report `unknown` rather than `idle`.
        err = (out.stderr or "").lower()
        if "no server running" in err or "no such file or directory" in err:
            return "", [], 0
        return "", [], -1

    sessions = pick_sessions(out.stdout)[:MAX_PANES]
    screens = []
    for s in sessions:
        try:
            p = subprocess.run(["tmux", "capture-pane", "-p", "-t", s],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               universal_newlines=True, timeout=5)
            if p.returncode == 0:
                screens.append("\n".join(p.stdout.splitlines()[-PANE_LINES:]))
        except Exception:
            continue
    if sessions and not screens:
        return "", [], -1
    return fold_ascii("\n".join(screens), collapse_ws=False), screens, len(screens)


def pane_flags(pane):
    flags = {name: bool(rx.search(pane)) for name, rx in AD["signals"]}
    flags["busy"] = bool(AD["live"].search(pane))
    flags["error"] = bool(ERROR_SIGNAL.search(pane))
    return flags


NO_FLAGS = {"login": False, "permission": False, "mcp": False,
            "busy": False, "error": False}


# ---------------------------------------------------------------- live agent
def live_agent_count():
    """How many agent processes are running on this box right now.

    This is the fact `state` is not. `done` is inferred from a transcript that
    stopped moving; the process behind it is usually still sitting at its
    prompt, and typing into it continues that same session. A caller told only
    "done" concludes the session is closed and starts a new one - which is what
    happened on a live call - so the process count ships alongside the word.

    -x matches the exact process NAME. Never -f: the pattern would appear in the
    argv of the probe's own shell, so every machine reports a constant nonzero
    count whether an agent runs or not, and an agent exec'd as a bare name is
    missed by a path-ish pattern anyway. The dashboard's probe uses -x for the
    same two reasons and the two must not disagree about the same machine.

    pgrep -c prints "0" AND exits 1 when nothing matches, so the count comes off
    stdout and the exit status is ignored. -1 means the probe itself could not
    run, which is not zero: a machine whose agent cannot be counted must not be
    reported as having none.
    """
    def _pgrep(flags):
        try:
            p = subprocess.run(["pgrep"] + flags + [AGENT],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               universal_newlines=True, timeout=5)
        except Exception:
            return None
        return (p.stdout or "").strip()

    out = _pgrep(["-c", "-x"])
    if out is None:
        return -1                       # no pgrep on this box, or it hung
    try:
        return max(0, int(out.splitlines()[0].strip()))
    except (IndexError, ValueError):
        pass
    # -c is a procps flag and BSD pgrep does not have it - it prints a usage
    # line to stderr and nothing to stdout. The fleet is Linux, but a collector
    # on a Mac must not report "cannot tell" for a running agent, so count the
    # pids instead. Same -x, same meaning, portable.
    out = _pgrep(["-x"])
    if out is None:
        return -1
    return len([ln for ln in out.splitlines() if ln.strip().isdigit()])


# ---------------------------------------------------------------- schema
# One declaration of the output shape. Three separate copies of this list used
# to exist, and adding a field to two of them silently dropped it from the
# dashboard payload.
DEFAULTS = {
    "summary": "",
    "state": "idle",
    "needs": "",
    "task": "",
    # snake_case against the camelCase of its neighbours on purpose: this is the
    # name the fleet snapshot and the voice tools already agreed on, and one
    # renamed key is a field that silently reads undefined at the far end.
    "has_live_agent": False,
    # -1 = the process probe could not run. Distinct from 0, which is a machine
    # with no agent on it, and from the False above, which is only the two of
    # them collapsed for a caller that wants one boolean.
    "agentProcs": -1,
    "lastInstruction": "",
    "lastInstructionAgeSec": -1,        # -1 = no instruction, or no clock on it
    "tool": "",
    "idleSec": 0,
    "sessionId": "",
    "activity": "",
    "shells": 0,
    "tasks": {"done": 0, "inProgress": 0, "open": 0},
    "agents": {"running": 0, "finished": 0, "names": []},
    "panes": 0,
    "at": "",
}


def empty_work():
    return {"shells": 0,
            "tasks": copy.deepcopy(DEFAULTS["tasks"]),
            "agents": copy.deepcopy(DEFAULTS["agents"]),
            "live": False}


def _last(rx, lines):
    """Index and match of the LAST line matching rx, or (-1, None). The widget
    is redrawn in place and capture-pane hands back superseded frames too, so
    the first match is an old frame."""
    idx, hit = -1, None
    for i, ln in enumerate(lines):
        m = rx.search(ln)
        if m:
            idx, hit = i, m
    return idx, hit


def parse_screen(raw):
    """Shells, tasks and subagents on one tmux screen."""
    w = empty_work()
    lines = raw.splitlines()
    w["live"] = bool(AD["live"].search(raw))

    # ---- shells and running agents: footer first, it is the only live frame
    footer = ""
    for ln in reversed(lines[-10:]):
        if AD["footer"].search(ln):
            footer = ln
            break
    if footer:
        m = FOOTER_SHELLS.search(footer)
        w["shells"] = int(m.group(1)) if m else 0      # no token = real zero
        m = FOOTER_AGENTS.search(footer)
        if m:
            w["agents"]["running"] = int(m.group(1))
    else:
        # No footer on screen (scrolled, or not an agent pane). Fall back to the
        # newest "N shells still running", unless a background command has
        # reported back since - that report supersedes it. The comparison is
        # positional; comparing counts or sets brings the stale-shell bug back.
        i_shell, m_shell = _last(SHELLS_STILL, lines)
        i_done, _ = _last(BG_SETTLED, lines)
        if m_shell and i_shell > i_done:
            w["shells"] = int(m_shell.group(1))

    # ---- tasks
    _, m = _last(TASKS_LINE, lines)
    if m:
        inner = m.group(2)
        for key, rx in (("done", TASK_DONE), ("inProgress", TASK_PROG), ("open", TASK_OPEN)):
            hit = rx.search(inner)
            w["tasks"][key] = int(hit.group(1)) if hit else 0
    else:
        glyphs = AD["task_glyphs"]
        counts = {k: 0 for k in glyphs}
        for ln in lines:
            head = ln.strip()[:1]
            for key, chars in glyphs.items():
                if head and head in chars:
                    counts[key] += 1
        if sum(counts.values()) >= 2:
            w["tasks"] = counts

    # ---- subagents
    finished = [m.group(1).strip() for m in AGENT_FINISHED.finditer(raw)]
    started = [m.group(1).strip() for m in AGENT_STARTED.finditer(raw)]
    w["agents"]["finished"] = len(finished)
    names = []
    for n in started + finished:
        if n and n not in names:
            names.append(n)
    w["agents"]["names"] = names[:6]

    if not w["agents"]["running"]:
        # Only the live spinner (or the last few rows) may assert a RUNNING
        # agent. An "N agents done" line from a turn that ended is not evidence,
        # and a completed fan-out would otherwise pin the machine in `working`.
        live_zone = [ln for i, ln in enumerate(lines)
                     if AD["live"].search(ln) or i >= len(lines) - 6]
        _, m = _last(AGENTS_RUNNING, live_zone)
        if m:
            w["agents"]["running"] = int(m.group(1))
        else:
            _, m = _last(AGENTS_FRACTION, live_zone)
            if m:
                w["agents"]["running"] = max(0, int(m.group(2)) - int(m.group(1)))
            else:
                w["agents"]["running"] = len([n for n in started if n not in finished])
    return w


def parse_work(screens):
    """Merge every tmux session on the box into one work-in-flight picture."""
    total = empty_work()
    for raw in screens:
        w = parse_screen(raw)
        total["shells"] += w["shells"]
        total["live"] = total["live"] or w["live"]
        for k in total["tasks"]:
            total["tasks"][k] += w["tasks"][k]
        total["agents"]["running"] += w["agents"]["running"]
        total["agents"]["finished"] += w["agents"]["finished"]
        for n in w["agents"]["names"]:
            if n not in total["agents"]["names"]:
                total["agents"]["names"].append(n)
    total["agents"]["names"] = [fold_ascii(n)[:60] for n in total["agents"]["names"]][:6]
    return total


def screen_work():
    """Scrape, parse and flag in one call, so the full run and the cached path
    cannot drift apart on how they read the screen.

    The fourth value is a fingerprint of what was on the screens. Comparing it
    with the previous poll's is the only cheap way to tell a machine that is
    producing output from one that is frozen - see detect_state.
    """
    pane, screens, panes = pane_tail()
    sig = hashlib.md5(pane.encode("utf-8", "ignore")).hexdigest()[:16] if screens else ""
    return (parse_work(screens),
            pane_flags(pane) if screens else dict(NO_FLAGS),
            panes,
            sig)


def outstanding(work, flags):
    """Anything that forbids the word `done`."""
    return bool(flags.get("busy") or work["live"] or work["shells"]
                or work["agents"]["running"] or work["tasks"]["inProgress"])


def plural(n, word):
    return "%d %s" % (n, word) if n == 1 else "%d %ss" % (n, word)


def activity_phrase(work):
    """One lowercase clause the dashboard prints verbatim. Empty when quiet."""
    bits = []
    if work["shells"]:
        bits.append(plural(work["shells"], "shell") + " running")
    if work["agents"]["running"]:
        bits.append(plural(work["agents"]["running"], "agent") + " running")
    if work["tasks"]["inProgress"]:
        bits.append(plural(work["tasks"]["inProgress"], "task") + " in progress")
    return fold_ascii(", ".join(bits)).lower()[:80]


# ---------------------------------------------------------------- state
# What a drawn prompt means, in the words the dashboard shows, in precedence
# order - run()'s no-transcript path takes the first flag that is set. Shared
# with detect_state so that a machine at a login prompt reads the same whether
# or not it has ever written a transcript.
PROMPT_NEEDS = {
    "login": "auth expired: log the agent back in",
    "permission": "tool permission prompt open",
    "mcp": "a tool server needs authentication",
}

QUESTION_TAIL = re.compile(
    r"(want me to|should i|shall i|do you want|which (one|of)|confirm|"
    r"let me know|ok to |proceed\?|go ahead\?)[^.?!]*\?\s*$", re.I)


def detect_state(f, flags, idle, work, pane_moving=False):
    """Deterministic. The model is never asked what state a machine is in - a
    hallucinated `waiting_for_human` pages the human for nothing, and a
    hallucinated `done` strands a machine that is actually blocked.

    Precedence, strictly:  error > waiting_for_human > working > done > idle.

    Two branches carry an in-flight guard, and that guard is part of the
    CONDITION, not a reordering: a traceback scrolling past a live agent is that
    agent's problem to fix, and a question in the scrollback of a session that
    is still churning is last turn's question, not a block.
    """
    busy = outstanding(work, flags)

    # 1. error - only assertable when nothing is in flight. An errored tool
    #    result the agent then talked past is not an error state; only a
    #    dangling one with no recovery message counts.
    if not busy:
        if f["last_error"] and f["last_role"] == "assistant" and not f["last_text"]:
            return "error", f["last_error"][:80]
        if flags.get("error") and idle > WORKING_WINDOW:
            return "error", "traceback in terminal"

    # 2. waiting_for_human - a drawn prompt outranks anything still running
    if flags.get("login"):
        return "waiting_for_human", PROMPT_NEEDS["login"]
    if flags.get("permission"):
        return "waiting_for_human", PROMPT_NEEDS["permission"]
    if not busy:
        # A tool dispatched and never returned, long after the fact, is either a
        # hung command or a prompt nobody answered.
        #
        # `pane_moving` is load-bearing and not obvious. A detached `agentfleet
        # run` job is a non-interactive agent: its pane is plain streamed stdout
        # with no spinner, no footer and no shell token, so `busy` is always
        # False for it - while the prompt this tool writes tells the agent to
        # run everything in the FOREGROUND and wait. Every build or test suite
        # over the threshold therefore used to page a human about a job that was
        # running perfectly, and af_ls_row puts that at the top of the needs-you
        # list. A screen whose bytes changed since the last poll is producing
        # output; nobody is blocked on you. A truly hung command or an
        # unanswered prompt leaves the screen identical poll after poll.
        if f["pending_tools"] and idle > PENDING_TOOL_STALL and not pane_moving:
            return "waiting_for_human", "waiting on " + ", ".join(f["pending_tools"][:2])
        tail = f["last_text"][-220:]
        if tail and QUESTION_TAIL.search(tail):
            q = tail.split(". ")[-1].strip()
            return "waiting_for_human", q[:110]
        if flags.get("mcp"):
            return "waiting_for_human", PROMPT_NEEDS["mcp"]

    # 3. working - the spinner, a background shell, a subagent, an open task, or
    #    a transcript that moved in the last WORKING_WINDOW seconds.
    if busy:
        return "working", ""
    if f["pending_tools"] and pane_moving:
        # A tool that has not returned, on a screen that is still printing. A
        # non-interactive run job has no spinner to prove it is alive and its
        # transcript does not move until the tool returns, so without this the
        # row falls all the way through to `idle` on a machine mid-build.
        return "working", ""
    if idle < WORKING_WINDOW and f["pending_tools"]:
        return "working", ""
    if idle < WORKING_WINDOW and f["last_role"] == "assistant" and pane_moving:
        # last_role == assistant covers BOTH "mid-thought" and "said its final
        # sentence and parked at the prompt", and those want opposite answers.
        # Without the pane_moving guard a finished agent reads `working` for the
        # full 90s window while the operator is looking at an idle prompt - the
        # spinner (busy, above) already catches genuinely active work, and a
        # non-interactive job with no spinner is caught by the pending_tools
        # branch, so a still screen here means it really has stopped.
        return "working", ""

    # 4. done - reachable only with nothing outstanding at all
    if f["last_text"] and idle < DONE_WINDOW:
        return "done", ""

    # 5. idle
    return "idle", ""


# ---------------------------------------------------------------- summarizer
# Optional and pluggable. With AF_SUMMARY_PROVIDER=none the deterministic
# fallback fills `summary` and nothing here ever runs.
SYSTEM = (
    "You label a live coding-agent session for a one-line fleet dashboard. "
    "Reply with strict JSON only - no prose, no markdown, no code fence."
)

INSTRUCTION = """Write a glanceable status line for this session.

Rules for "summary":
- 14 words maximum, present tense, plain ASCII, no emoji, no trailing period.
- Name the concrete subject: the file, service, feature or command. Say
  "rewriting the retry loop in queue/worker.ts", never "processing code".
- Describe what the session is doing now, or last did if it has stopped.
- Never mention the transcript, the model, or that you are summarizing.

Rules for "needs": if state is waiting_for_human, one short clause (10 words max)
saying what the human must decide or unblock. Otherwise the empty string.

Return exactly: {"summary": "...", "needs": "..."}"""

PROVIDER_DEFAULTS = {
    "anthropic": {"url": "https://api.anthropic.com/v1/messages",
                  "model": "claude-haiku-4-5", "env": "ANTHROPIC_API_KEY"},
    "openai": {"url": "https://api.openai.com/v1/chat/completions",
               "model": "gpt-4o-mini", "env": "OPENAI_API_KEY"},
}


def read_key(provider):
    if SUMMARY_KEY_FILE:
        try:
            k = open(os.path.expanduser(SUMMARY_KEY_FILE)).read().strip()
            if k:
                return k
        except OSError:
            pass
    env = PROVIDER_DEFAULTS.get(provider, {}).get("env", "")
    return os.environ.get(env, "") or cfg("AF_SUMMARY_API_KEY", "")


def build_digest(f, state, activity=""):
    parts = []
    if f["title"]:
        parts.append("Session title: " + f["title"])
    parts.append("Detected state: " + state)
    if activity:
        # Without this the model reads a finished-looking turn and writes
        # "finished the refactor" while a shell and a task are still in flight,
        # so the prose contradicts the state on the same row.
        parts.append("Still in flight right now: " + activity)
    if f["queued"]:
        parts.append("Queued by the human: " + f["queued"])
    parts.append("--- last turns (oldest first) ---")
    for who, body in f["turns"][-MAX_TURNS:]:
        # Same cleaned view Fix 1 records into `task`, applied again here so the
        # summarizer input can never be a pasted call transcript even if a future
        # code path lets one into f["turns"]. Fix 1 already gates this at the
        # adapter; this keeps the guarantee local to the summarizer, so turning
        # AF_SUMMARY_PROVIDER on later cannot make the model summarize the paste.
        if who == "human" and looks_like_pasted_conversation(body):
            continue
        tag = {"human": "HUMAN", "agent": "AGENT", "tool": "TOOL "}.get(who, "OTHER")
        parts.append("%s: %s" % (tag, body[:600]))
    if f["last_error"]:
        parts.append("LAST TOOL ERROR: " + f["last_error"])
    digest = "\n".join(parts)
    if len(digest) > MAX_DIGEST:          # keep the tail - it is the current work
        digest = "...\n" + digest[-MAX_DIGEST:]
    # Repeat the newest agent message outside the truncation window. Without
    # this the model latches onto whatever filled the middle of the transcript
    # and describes work that finished an hour ago.
    if f["last_text"]:
        digest += "\n--- most recent agent message (weight this heaviest) ---\n"
        digest += f["last_text"][-700:]
    return digest


def call_model(digest, provider, key):
    d = PROVIDER_DEFAULTS[provider]
    url = SUMMARY_URL or d["url"]
    model = SUMMARY_MODEL or d["model"]
    prompt = digest + "\n\n" + INSTRUCTION
    if provider == "anthropic":
        body = {"model": model, "max_tokens": 200, "system": SYSTEM,
                "messages": [{"role": "user", "content": prompt}]}
        headers = {"content-type": "application/json", "x-api-key": key,
                   "anthropic-version": "2023-06-01"}
    else:
        body = {"model": model, "max_completion_tokens": 300,
                "messages": [{"role": "system", "content": SYSTEM},
                             {"role": "user", "content": prompt}]}
        headers = {"content-type": "application/json",
                   "authorization": "Bearer " + key}
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers)
    with urllib.request.urlopen(req, timeout=25) as r:
        payload = json.load(r)
    if provider == "anthropic":
        return "".join(b.get("text", "") for b in payload.get("content", [])
                       if b.get("type") == "text")
    choices = payload.get("choices") or [{}]
    return (choices[0].get("message") or {}).get("content") or ""


def parse_model_json(raw):
    """The model is told to return bare JSON. Assume it sometimes will not."""
    if not raw:
        return None
    raw = raw.strip()
    if raw.startswith("```"):
        raw = re.sub(r"^```[a-z]*\s*|\s*```$", "", raw)
    i, j = raw.find("{"), raw.rfind("}")
    if i < 0 or j <= i:
        return None
    try:
        obj = json.loads(raw[i:j + 1])
    except ValueError:
        return None
    return obj if isinstance(obj, dict) else None


def clamp_summary(s):
    s = fold_ascii(str(s or "")).strip().strip('"').rstrip(".")
    words = s.split()
    if len(words) > 14:
        s = " ".join(words[:14])
    return s[:110]


def fallback_summary(f, state):
    """Never let a missing or broken summarizer produce an empty row."""
    base = (f["title"] or f["task"] or f["last_text"]
            or ("running " + f["tool"] if f["tool"] else "")
            or "idle at the prompt, nothing started")
    if state == "working" and f["tool"]:
        base = "%s (%s)" % (base, f["tool"])
    return clamp_summary(base)


# ---------------------------------------------------------------- cache
def read_cache():
    try:
        with open(CACHE) as fh:
            c = json.load(fh)
        return c if isinstance(c, dict) else {}
    except Exception:
        return {}


def write_cache(obj):
    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        tmp = CACHE + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(obj, fh)
        # Atomic: the timer and the dashboard poll are unsynchronized processes
        # on the same file, and a half-written read blanks a row.
        os.replace(tmp, CACHE)
    except OSError as exc:
        sys.stderr.write("af-status: cannot write %s: %s\n" % (CACHE, exc))


def public(obj):
    """The cache also carries bookkeeping keys, and a cache written by an older
    version is missing fields entirely. Emit the full shape either way - the
    dashboard should never see an undefined field."""
    out = {}
    for k, v in DEFAULTS.items():
        got = obj.get(k)
        out[k] = copy.deepcopy(v) if got is None else got
    out["at"] = out["at"] or now_iso()
    return out


def emit(obj):
    print(json.dumps(public(obj)))


def instruction_age(ts):
    """Seconds since the instruction, or -1 when the entry carried no clock.
    Never a negative age from a machine whose clock is a little ahead."""
    return int(max(0, time.time() - ts)) if ts else -1


def empty(reason, state=""):
    out = copy.deepcopy(DEFAULTS)
    out["summary"] = reason
    if state:
        out["state"] = state
    out["at"] = now_iso()
    return out


# ---------------------------------------------------------------- selftest
# The transcript-noise rules, against real text. Every polluted sample below is
# copied verbatim out of a fleet transcript, because the bug this guards was a
# wrapper nobody had thought to add to a list of literals: made-up samples pass
# a filter written from the same imagination.
NOISE_FIXTURES = [
    # Captured from a real polluted transcript. This exact entry became the
    # `task` field, and the operator asking what he last told the machine was
    # read this back - twice, in one call.
    ('<task-notification>\n<task-id>bit6lhnld</task-id>\n'
     '<tool-use-id>toolu_01NcGMvafyQH8EGTxDkJbk8c</tool-use-id>\n'
     '<output-file>/tmp/agent-run/project/'
     'bae46a73-0093-460d-92ae-abd8a2de6088/tasks/bit6lhnld.output</output-file>\n'
     '<status>completed</status>\n'
     '<summary>Background command "Install dependencies in server worktree" '
     'completed (exit code 0)</summary>\n</task-notification>', True),
    # Same family, agent fan-out rather than a shell. The trailing <note> is the
    # part that makes tag-stripping alone unsafe: it leaves fluent prose.
    ('<task-notification>\n<task-id>a603b40eec398ae06</task-id>\n'
     '<tool-use-id>toolu_01QigFATZ9fHUtGa4KAQXG7V</tool-use-id>\n'
     '<status>completed</status>\n'
     '<summary>Agent "Implement benchmarks voice catalog page" finished</summary>\n'
     '<note>A task-notification fires each time one completes.</note>\n'
     '</task-notification>', True),
    ('<system-reminder>Your todo list has changed.</system-reminder>', True),
    ('<local-command-stdout>ok</local-command-stdout>', True),
    # A wrapper the harness has not invented yet. This is the whole point of the
    # hyphenated-family rule: no literal list would have this one in it.
    ('<some-future-wrapper><inner-id>x1</inner-id></some-future-wrapper>', True),
    # Genuine instructions, including ones that talk ABOUT the tags and one that
    # contains real markup. None of these may be dropped.
    ('Continue task #13 (voices V2 closing). v0.0.357 tagged ~14 min ago.', False),
    ('the collector keeps putting <task-notification> blocks in the task field '
     '- strip the hyphenated family like the dashboard does', False),
    ('fix the <div> nesting in apps/marketing/index.html', False),
    ('run the tests and report back', False),
]

# The hard fixtures the verifier bakes in, labeled so each result prints. False
# = a genuine instruction that MUST PASS (the old code wrongly hid these -
# question-dense debugging asks with no imperative head); True = pasted chat/call
# that MUST REJECT, including ones opening with a word the old whitelist trusted
# (then/now/we). The discriminator is social-pleasantry density, never question
# count and never the opening word.
HARD_FIXTURES = [
    ("P1", False,
     "why is staging still broken? did that migration apply or not? does anyone "
     "know if our revision serves traffic? I keep seeing errors and cannot figure "
     "out from here whether it deployed at all last night during that whole messy "
     "incident window."),
    ("P2", False,
     "this whole auth flow feels wrong to me after yesterday. did you ever land "
     "the timeout fix on that flaky worker test? does the suite pass green now? "
     "and honestly why is the retry wrapper still not covering the path we "
     "identified during the review last week?"),
    ("P3", False,
     "honestly that benchmarks page still looks off. is the voice catalog pulling "
     "the new rows? did biome pass on that branch? does the latency column read "
     "from the cached table or the live one? something regressed since yesterday "
     "and I want to know what."),
    ("R1", True,
     "hey man so good to finally catch up, how have you been? yeah its been way "
     "too long honestly. oh nice, yeah I heard you moved to the city. hows the "
     "new place treating you? haha yeah I bet. anyway did you want to grab coffee "
     "sometime next week? sounds good, talk soon, take care."),
    ("R2", True,
     "so then I was thinking, how are you doing these days man? yeah its been ages "
     "honestly, nice to see you around again. oh you know how it is, busy busy. "
     "haha yeah for sure. anyway hows the family? good good, glad to hear it, talk "
     "soon okay take care buddy."),
    ("R3", True,
     "now listen, how have you been holding up lately? oh man yeah I totally get "
     "that, no worries at all. nice to meet you finally after all these emails "
     "haha. yeah so great to connect. hows things on your side? cool cool, sounds "
     "good, cheers, talk to you soon."),
    ("R4", True,
     "we should totally catch up soon, how are things going with you? yeah nice, "
     "oh thats awesome to hear honestly. haha yeah no problem at all my friend. "
     "hows the weather over there? oh nice, okay well take care, talk soon, great "
     "seeing you around again buddy."),
    ("R5", True,
     "Hey Good, good, good. Nice to meet you back. Are you in SF right now or? "
     "Birth? Hey, how are you? Nice to meet you, man."),
]

# The shape-based reject (Fix 1). True = pasted conversation, must NOT become an
# instruction; False = a genuine instruction, must pass. The discriminator is
# "conversation-shaped", never "long", so the PASS side deliberately includes a
# long imperative and a long declarative technical instruction - length alone
# must not reject either.
PASTE_FIXTURES = [
    # The primary reject fixture: a customer-call transcript pasted into a coding
    # session and read back to the operator as "your latest request". Greeting
    # and question dense, no imperative head - no speaker labels or timestamps,
    # so it is caught purely by the chatter/question path.
    ("Hey Good, good, good. Nice to meet you back. Are you in SF right now or? "
     "Birth? Hey, how are you? Nice to meet you, man. I am, yeah, I am in the "
     "sub, I am actually in the airport. I am in the airport right now. Yeah. "
     "Oh. Okay. That is nice. Nice. Going to the conference tomorrow on voice. "
     "Awesome. Yeah, yeah. Yeah, I was just testing out some other companies' "
     "voice AI, and I'm like, hmm, ours defi", True),
    # A two-speaker call transcript with conversational speaker labels.
    ("Agent: Thanks for calling, how can I help you today?\n"
     "Caller: Hi there, yeah, I was hoping to ask about your pricing.\n"
     "Agent: Of course, happy to help. Are you looking at the monthly plan?\n"
     "Caller: Yeah, I think so, but I had a couple of questions first.\n"
     "Agent: Sure, go ahead, take your time.\n"
     "Caller: Great, thanks so much, really appreciate it.", True),
    # A greetings-heavy small-talk blob, no structure and no imperative head.
    ("Hey hey! Good morning, how are you doing today? Nice to meet you, so great "
     "to see you again after all this time. Yeah, thanks so much, awesome, "
     "really appreciate it. How's it going on your end, how have you been "
     "lately? Oh cool, okay, yeah sounds good to me. Haha, no worries at all, "
     "talk to you soon, take care, cheers for now.", True),
    # PASS: a short imperative and a comma-chained short instruction.
    ("continue task 13, voices V2, then check Cloud Run", False),
    ("fix the flaky auth test in worker.ts", False),
    ("run the tests and report back", False),
    # PASS: a long, multi-sentence imperative instruction. Long, but it opens
    # like a command and is not conversation-shaped, so it must not be rejected.
    ("Continue task 13, the voices V2 closing work. First rebase onto main, then "
     "run the worker test suite in worker-ts and fix any failures you find. "
     "After that, check the Cloud Run revision and redeploy if the migration did "
     "not apply cleanly. Report back when the whole suite passes and the "
     "revision is serving traffic again.", False),
    # PASS: a long, multi-sentence DECLARATIVE technical instruction - no
    # imperative verb at the head, proving the reject is not just an
    # imperative-start check. Low filler, no question flood, so it passes.
    ("The migration in packages/db keeps failing on staging because the enum "
     "column was renamed twice and the down migration was never regenerated. "
     "The retry wrapper we added last week does not cover the timeout path, so "
     "the deploy hangs instead of surfacing the error. A fresh baseline against "
     "a clean branch is what this needs before the next release tag.", False),
]


def selftest():
    ok = True
    for raw, want in NOISE_FIXTURES:
        got = harness_only(raw)
        if got != want:
            ok = False
            print("FAIL harness_only=%s want=%s: %r" % (got, want, raw[:70]))

    # End to end through the adapter: one real human turn, then every harness
    # notification above arriving on the human's role after it. `task` must
    # still be the human turn - not a notification, and not blank.
    f = {"title": "", "task": "", "task_ts": 0.0, "turns": [], "tool": "",
         "last_text": "", "last_role": "", "last_ts": 0.0, "entry_ts": 0.0,
         "pending_tools": [], "last_error": "", "queued": ""}
    ctx = {"pending": {}, "alt": [], "saw_events": False}
    human = "Continue task #13 (voices V2 closing), check the Cloud Run revision"
    f["entry_ts"] = time.time() - 300
    claude_entry({"type": "user", "message": {"role": "user", "content": human}}, f, ctx)
    for raw, want in NOISE_FIXTURES:
        if not want:
            continue
        f["entry_ts"] = time.time()
        claude_entry({"type": "user", "message": {"role": "user", "content": raw}}, f, ctx)
    if f["task"] != human:
        ok = False
        print("FAIL task fell through to noise: %r" % f["task"][:90])
    if [t for t in f["turns"] if t[0] == "human"] != [("human", human)]:
        ok = False
        print("FAIL noise reached the model digest: %r" % (f["turns"],))
    age = instruction_age(f["task_ts"])
    if not 290 <= age <= 310:
        ok = False
        print("FAIL instruction age %s, expected the human turn's own clock" % age)

    # A stale `last-prompt` record - clockless, and written after newer turns -
    # must not displace a dated instruction. Observed in the field: "go all" from
    # hours earlier overwriting the live standing ask.
    f["entry_ts"] = 0.0
    claude_entry({"type": "last-prompt", "lastPrompt": "go all"}, f, ctx)
    if f["task"] != human or instruction_age(f["task_ts"]) < 290:
        ok = False
        print("FAIL stale last-prompt displaced a dated instruction: %r age=%s"
              % (f["task"][:40], instruction_age(f["task_ts"])))

    # With no dated turn in the tail at all it is still the best source there is.
    g = {"title": "", "task": "", "task_ts": 0.0, "turns": [], "tool": "",
         "last_text": "", "last_role": "", "last_ts": 0.0, "entry_ts": 0.0,
         "pending_tools": [], "last_error": "", "queued": ""}
    claude_entry({"type": "last-prompt", "lastPrompt": "go all"}, g,
                 {"pending": {}, "alt": [], "saw_events": False})
    if g["task"] != "go all":
        ok = False
        print("FAIL last-prompt dropped when it is the only human text: %r" % g["task"])

    # ---- Fix 1: the shape-based pasted-conversation reject, both directions.
    # The labeled hard fixtures print one line each so the verifier sees every
    # P#/R# verdict.
    for label, want, raw in HARD_FIXTURES:
        got = looks_like_pasted_conversation(raw)
        fam, dist = _social_markers(raw)
        verdict = "REJECT" if got else "PASS"
        expect = "REJECT" if want else "PASS"
        good = got == want
        if not good:
            ok = False
        print("%s %s got=%s want=%s (families=%d markers=%d)"
              % ("ok  " if good else "FAIL", label, verdict, expect, fam, dist))

    for raw, want in PASTE_FIXTURES:
        got = looks_like_pasted_conversation(raw)
        if got != want:
            ok = False
            verb = "rejected" if got else "passed"
            print("FAIL pasted-reject %s (want %s): %r" % (verb, want, raw[:70]))

    # End to end: a real instruction, then a pasted call transcript on the
    # human's role. The paste must NOT become the instruction and must NOT reach
    # the digest turns - `task` stays the previous genuine instruction.
    poison = next(raw for raw, want in PASTE_FIXTURES if want)
    h = {"title": "", "task": "", "task_ts": 0.0, "turns": [], "tool": "",
         "last_text": "", "last_role": "", "last_ts": 0.0, "entry_ts": 0.0,
         "pending_tools": [], "last_error": "", "queued": ""}
    hctx = {"pending": {}, "alt": [], "saw_events": False}
    real = "fix the flaky auth test in worker.ts, then redeploy"
    h["entry_ts"] = time.time() - 120
    claude_entry({"type": "user", "message": {"role": "user", "content": real}}, h, hctx)
    h["entry_ts"] = time.time()
    claude_entry({"type": "user", "message": {"role": "user", "content": poison}}, h, hctx)
    if h["task"] != real:
        ok = False
        print("FAIL pasted call became the instruction: %r" % h["task"][:90])
    if [t for t in h["turns"] if t[0] == "human"] != [("human", real)]:
        ok = False
        print("FAIL pasted call reached the model digest: %r" % (h["turns"],))

    # With the pasted call as the ONLY human turn in the tail, there is no clean
    # instruction: lastInstruction is "" and its age is -1, never the garbage.
    e = {"title": "", "task": "", "task_ts": 0.0, "turns": [], "tool": "",
         "last_text": "", "last_role": "", "last_ts": 0.0, "entry_ts": 0.0,
         "pending_tools": [], "last_error": "", "queued": ""}
    ectx = {"pending": {}, "alt": [], "saw_events": False}
    e["entry_ts"] = time.time()
    claude_entry({"type": "user", "message": {"role": "user", "content": poison}}, e, ectx)
    if e["task"] != "" or instruction_age(e["task_ts"]) != -1:
        ok = False
        print("FAIL no-clean-instruction: task=%r age=%s (want '' and -1)"
              % (e["task"][:40], instruction_age(e["task_ts"])))

    # ---- Fix 2: the summarizer digest excludes a pasted call even if one is
    # forced into f["turns"], so enabling AF_SUMMARY_PROVIDER cannot summarize it.
    d = {"title": "", "task": "", "task_ts": 0.0, "queued": "", "last_error": "",
         "last_text": "wired the retry loop in worker-ts and reran the suite",
         "turns": [("human", real), ("human", poison), ("agent", "on it")]}
    digest = build_digest(d, "working", "")
    if poison[:30] in digest:
        ok = False
        print("FAIL pasted call reached the summarizer digest")
    if real not in digest:
        ok = False
        print("FAIL real instruction dropped from the summarizer digest")

    procs = live_agent_count()
    print("live_agent_count(%s) = %s" % (AGENT, procs))
    print("SELFTEST " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


# ---------------------------------------------------------------- main
def cached_mode():
    """Dashboard path: one stat, no transcript parse, no model call."""
    cache = read_cache()
    path = newest_transcript()
    if not cache or not path or cache.get("_path") != path:
        return run(no_llm=True)         # cache is missing or points at a dead session
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        mtime = cache.get("_mtime", 0)
    cache["idleSec"] = max(0, int(time.time() - max(mtime, cache.get("_last_ts", 0))))
    cache["at"] = now_iso()
    # Both of these have to be recomputed, not served from the cache. The
    # process count is what decides continue-vs-start-a-new-session, and an
    # agent that exited a timer period ago would otherwise still read live; the
    # instruction's age is a clock, and a cached clock is a stopped one.
    procs = live_agent_count()
    cache["agentProcs"] = procs
    cache["has_live_agent"] = procs > 0
    cache["lastInstructionAgeSec"] = (instruction_age(cache.get("_task_ts", 0))
                                      if cache.get("lastInstruction") else -1)

    # The cache is up to one timer period old, and that is long enough for a
    # session to launch a shell after its last turn read like a completion.
    # Re-reading the screen costs two tmux calls and no tokens, so a quiet cache
    # never gets to claim `done` over live work. One-directional on purpose:
    # this may promote to working, never demote - only the full run, which has
    # the transcript in front of it, may retire a state.
    if cache.get("state") in ("done", "idle", "unknown"):
        work, flags, panes, _sig = screen_work()
        cache["panes"] = panes
        if panes > 0 and outstanding(work, flags):
            cache["state"] = "working"
            cache["needs"] = ""
            cache["shells"] = work["shells"]
            cache["tasks"] = work["tasks"]
            cache["agents"] = work["agents"]
            cache["activity"] = activity_phrase(work)
    emit(cache)


def run(no_llm=False):
    path = newest_transcript()
    if not path:
        # No transcript is not evidence of a quiet machine. A box whose agent
        # has never finished a turn is most often one sitting at a prompt, and
        # every prompt signal - login, permission, MCP auth - exists only on the
        # pane. Returning `idle` here without looking at the screen is the one
        # direction that loses a machine that needs a human, so read it.
        work, flags, panes, _sig = screen_work()
        state, needs = "idle", ""
        prompt = next((k for k in PROMPT_NEEDS if flags.get(k)), "")
        if prompt:
            state, needs = "waiting_for_human", PROMPT_NEEDS[prompt]
        elif panes > 0 and outstanding(work, flags):
            state = "working"
        elif panes < 0:
            state = "unknown"       # the probe failed: quiet is unproven, not true
        out = empty("no %s session on this machine" % AGENT, state)
        out["needs"] = needs
        out["panes"] = panes
        # No transcript still says nothing about the process: an agent launched
        # a second ago has not written a turn yet.
        procs = live_agent_count()
        out["agentProcs"] = procs
        out["has_live_agent"] = procs > 0
        out["shells"] = work["shells"]
        out["tasks"] = work["tasks"]
        out["agents"] = work["agents"]
        out["activity"] = activity_phrase(work)
        write_cache(dict(out, _path="", _mtime=0, _llm_at=0, _last_ts=0))
        emit(out)
        return

    mtime = os.path.getmtime(path)
    f = parse(path)
    work, flags, panes, pane_sig = screen_work()
    idle = max(0, int(time.time() - max(mtime, f["last_ts"])))
    cache = read_cache()
    # Two readings of the same screens, one timer period apart. Only a change
    # counts as movement: no previous fingerprint (first run after a restart)
    # means nothing has been compared yet, and claiming movement then would
    # suppress a real stall on the one tick that has no history.
    prev_sig = cache.get("_pane_sig", "")
    pane_moving = bool(pane_sig) and bool(prev_sig) and pane_sig != prev_sig
    state, det_needs = detect_state(f, flags, idle, work, pane_moving)
    activity = activity_phrase(work)

    if panes < 0:
        # Without the screen there is no way to see a permission box or a
        # background shell, so "nothing outstanding" is unproven rather than
        # true. Say so instead of reporting a possibly busy machine as free.
        sys.stderr.write("af-status: tmux probe failed - screen signals unavailable\n")
        if state in ("done", "idle"):
            state = "unknown"

    same_session = cache.get("_path") == path
    unchanged = same_session and cache.get("_mtime") == mtime
    cooling = time.time() - cache.get("_llm_at", 0) < MIN_LLM_INTERVAL

    summary, needs, llm_at = "", "", cache.get("_llm_at", 0)
    provider = SUMMARY_PROVIDER if SUMMARY_PROVIDER in PROVIDER_DEFAULTS else ""
    if same_session and (unchanged or cooling) and cache.get("summary"):
        # Nothing new to say, or the model was called less than an interval ago.
        summary, needs = cache["summary"], cache.get("needs", "")
    elif not no_llm and provider and f["turns"]:
        # An empty transcript (fresh machine, or right after a context clear)
        # gives the model nothing to work from and it invents a summary out of
        # the instructions, which is worse than "idle, nothing started".
        key = read_key(provider)
        if key:
            try:
                obj = parse_model_json(
                    call_model(build_digest(f, state, activity), provider, key))
                if obj and obj.get("summary"):
                    summary = clamp_summary(obj.get("summary"))
                    needs = fold_ascii(str(obj.get("needs") or ""))[:90]
                    llm_at = time.time()
            except (urllib.error.URLError, urllib.error.HTTPError, OSError,
                    ValueError, TimeoutError) as exc:
                sys.stderr.write("af-status: summarizer failed: %s\n" % exc)

    if not summary:
        summary = fallback_summary(f, state)
    # A `needs` carried over from an earlier poll would keep the "needs you"
    # badge lit after the human already unblocked the machine.
    if state == "waiting_for_human":
        needs = det_needs or needs or "awaiting your call"
    elif state == "error":
        needs = det_needs or needs
    else:
        needs = ""

    procs = live_agent_count()
    out = {
        "summary": summary,
        "state": state,
        "needs": fold_ascii(needs)[:110],
        "activity": activity,
        "shells": work["shells"],
        "tasks": work["tasks"],
        "agents": work["agents"],
        "task": (f["task"] or f["title"])[:120],
        "has_live_agent": procs > 0,
        "agentProcs": procs,
        # `task` falls back to the session title and is cut to a column width.
        # This one is only ever the human's own words, and long enough to be
        # read back to him, so a caller never has to guess which it got.
        "lastInstruction": f["task"][:400],
        "lastInstructionAgeSec": instruction_age(f["task_ts"]) if f["task"] else -1,
        "tool": f["tool"],
        "idleSec": idle,
        "sessionId": os.path.basename(path)[:-6],
        "panes": panes,
        "at": now_iso(),
    }
    write_cache(dict(out, _path=path, _mtime=mtime, _llm_at=llm_at,
                     _last_ts=f["last_ts"], _task_ts=f["task_ts"],
                     _pane_sig=pane_sig))
    emit(out)


def main():
    args = set(sys.argv[1:])
    if "--help" in args or "-h" in args:
        print(__doc__.strip())
        return
    if "--selftest" in args:
        sys.exit(selftest())
    try:
        if "--work" in args:
            work, flags, panes, _sig = screen_work()
            work["flags"] = flags
            work["panes"] = panes
            work["activity"] = activity_phrase(work)
            print(json.dumps(work))
        elif "--cached" in args:
            cached_mode()
        else:
            run(no_llm="--no-llm" in args)
    except Exception as exc:            # a crash must never blank the dashboard
        # `unknown`, not the DEFAULTS `idle`: a collector that crashed knows
        # nothing about this machine, and idle is the one answer that reads as
        # good news.
        emit(empty("status unavailable: " + fold_ascii(str(exc))[:60], "unknown"))


if __name__ == "__main__":
    main()
