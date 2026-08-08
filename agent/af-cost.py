#!/usr/bin/env python3
"""What this machine has spent on model tokens TODAY, split by vendor.

Runs on the machine behind a timer and writes ~/.cache/agentfleet/cost.json, so
the dashboard reads one small file instead of scanning gigabytes of transcript
on every poll.

Two sources, both written by the agent CLIs themselves:
  Claude Code  ~/.claude/projects/**/*.jsonl   per-assistant-message `usage`
  Codex        ~/.codex/sessions/**/*.jsonl    `last_token_usage` per-turn delta

Buckets by LOCAL day, deliberately. Bucketing by UTC is what made an earlier
report announce a four-figure spend "today" when that was the previous
evening's work: a day ends at local midnight, not at whatever hour UTC rolls
over where you are.

    af-cost.py            # scan and refresh the cache
    af-cost.py --cached   # print the cache, no scan
"""
import glob
import json
import os
import sys
import time
from datetime import date, datetime, timezone

HOME = os.path.expanduser("~")
CACHE_DIR = os.environ.get("AF_CACHE_DIR") or (HOME + "/.cache/agentfleet")
CACHE = os.path.join(CACHE_DIR, "cost.json")

# USD per 1M tokens. THIS IS A STATIC ESTIMATE AND IT WILL DRIFT: vendors change
# list prices, and a machine may be billed on a plan or a committed-use rate
# that these numbers know nothing about. Treat the output as an order of
# magnitude, not an invoice. Point AF_COST_PRICES at a JSON file with the same
# shape to correct any of it without editing this program:
#
#   {"claude": {"opus": [15.0, 75.0], "sonnet": [3.0, 15.0]},
#    "codex":  {"input": 1.25, "cached": 0.125, "output": 10.0},
#    "cacheWrite": 1.25, "cacheRead": 0.10}
#
# Matching is by substring against the model id, longest key first, so "opus"
# catches every opus revision without a table update.
PRICES = {
    "claude": {
        "fable": [10.0, 50.0],
        "opus": [15.0, 75.0],
        "sonnet": [3.0, 15.0],
        "haiku": [1.0, 5.0],
    },
    "codex": {"input": 1.25, "cached": 0.125, "output": 10.0},
    # Cache writes bill above the input rate, cache reads far below it.
    "cacheWrite": 1.25,
    "cacheRead": 0.10,
}
# An unpriced model must never be counted as free: a silent zero looks exactly
# like an idle machine on the dashboard. Charge it at the mid tier and list it
# in `unknownModels` so the reader knows the number is a floor, not a fact.
FALLBACK_RATE = "sonnet"


def load_prices():
    path = os.environ.get("AF_COST_PRICES", "")
    if not path:
        return PRICES
    try:
        with open(os.path.expanduser(path)) as fh:
            override = json.load(fh)
    except (OSError, ValueError) as exc:
        # Loudly, not silently: a typo in the override path must not quietly
        # bill everything at the built-in guesses.
        sys.stderr.write("af-cost: ignoring AF_COST_PRICES (%s): %s\n" % (path, exc))
        return PRICES
    merged = json.loads(json.dumps(PRICES))
    for k, v in (override or {}).items():
        if isinstance(v, dict) and isinstance(merged.get(k), dict):
            merged[k].update(v)
        else:
            merged[k] = v
    return merged


def claude_rate(prices, model, unknown):
    m = (model or "").lower()
    table = prices.get("claude") or {}
    for key in sorted(table, key=len, reverse=True):
        if key in m:
            rate = table[key]
            return float(rate[0]), float(rate[1])
    if m:
        unknown.add(m[:60])
    fb = table.get(FALLBACK_RATE) or [3.0, 15.0]
    return float(fb[0]), float(fb[1])


def local_day(ts):
    """Transcript timestamps are ISO-8601, usually UTC. Compare in local time."""
    try:
        dt = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone().date()


def recent(pattern, today):
    """Only files touched today. Scanning every transcript ever written costs
    seconds on a box that has been running agents for months."""
    for path in glob.glob(os.path.expanduser(pattern), recursive=True):
        try:
            if date.fromtimestamp(os.path.getmtime(path)) >= today:
                yield path
        except OSError:
            continue


def _lines(path):
    try:
        fh = open(path, errors="ignore")
    except OSError:
        return
    with fh:
        for line in fh:
            yield line


def claude_today(today, prices, unknown):
    """Today's Claude Code spend, counted ONCE PER ASSISTANT RESPONSE.

    The naive loop - sum `usage` from every line that has one - looks obviously
    correct and is roughly 2x wrong. Claude Code writes one JSONL line per
    CONTENT BLOCK of a single assistant response, and every one of those lines
    repeats that response's whole `usage` object verbatim: same `message.id`,
    byte-identical input / cache_creation / cache_read counters. A turn that
    emits thinking plus three tool calls therefore lands four times, and gets
    billed four times. Measured on real transcripts: 5,162 usage lines collapse
    to 2,565 actual responses, with one response spread over 8 lines.

    So the unit of billing is the message id, not the line. Keep the LAST line
    seen for an id: earlier blocks carry a partial `output_tokens` (7 against
    the closing line's 345), only the final one has the whole response's count.
    Dedup is global rather than per file because resuming or forking a session
    copies earlier lines into the new transcript, and a copied response was not
    a second API call either.

    None of this applies to Codex: its `last_token_usage` entries are per-turn
    DELTAS that sum to the session total (verified against the final
    `total_token_usage`), so codex_today must keep summing every line.
    """
    cw_mult = float(prices.get("cacheWrite", 1.25))
    cr_mult = float(prices.get("cacheRead", 0.10))
    per_msg = {}                # message id -> (usd, tokens) for that response
    anon = 0                    # a line with no id is its own reading
    for path in recent("~/.claude/projects/**/*.jsonl", today):
        for line in _lines(path):
            if '"usage"' not in line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            msg = e.get("message") if isinstance(e, dict) else None
            msg = msg if isinstance(msg, dict) else {}
            u = msg.get("usage") or {}
            if not u or local_day(e.get("timestamp")) != today:
                continue
            rin, rout = claude_rate(prices, msg.get("model"), unknown)
            i = u.get("input_tokens", 0) or 0
            o = u.get("output_tokens", 0) or 0
            cw = u.get("cache_creation_input_tokens", 0) or 0
            cr = u.get("cache_read_input_tokens", 0) or 0
            mid = msg.get("id")
            if not isinstance(mid, str) or not mid:
                anon += 1
                mid = ("no-id", path, anon)
            per_msg[mid] = (
                (i * rin + o * rout + cw * rin * cw_mult + cr * rin * cr_mult) / 1e6,
                i + o + cw + cr,
            )
    usd = sum(v[0] for v in per_msg.values())
    tokens = sum(v[1] for v in per_msg.values())
    return usd, tokens


def _last_usage(obj, depth=0):
    """The per-turn delta is nested at a different depth across CLI versions."""
    if depth > 6 or not isinstance(obj, dict):
        return None
    u = obj.get("last_token_usage")
    if isinstance(u, dict):
        return u
    for v in obj.values():
        found = _last_usage(v, depth + 1)
        if found:
            return found
    return None


def codex_today(today, prices):
    usd = tokens = 0.0
    rate = prices.get("codex") or {}
    r_in = float(rate.get("input", 1.25))
    r_cached = float(rate.get("cached", 0.125))
    r_out = float(rate.get("output", 10.0))
    for path in recent("~/.codex/sessions/**/*.jsonl", today):
        for line in _lines(path):
            if '"last_token_usage"' not in line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if local_day(e.get("timestamp")) != today:
                continue
            u = _last_usage(e)
            if not u:
                continue
            cached = u.get("cached_input_tokens", 0) or 0
            fresh = max((u.get("input_tokens", 0) or 0) - cached, 0)
            out = u.get("output_tokens", 0) or 0
            usd += (fresh * r_in + cached * r_cached + out * r_out) / 1e6
            tokens += fresh + cached + out
    return usd, tokens


def collect():
    today = date.today()
    prices = load_prices()
    unknown = set()
    c_usd, c_tok = claude_today(today, prices, unknown)
    x_usd, x_tok = codex_today(today, prices)
    return {
        "day": today.isoformat(),
        "tz": time.strftime("%Z"),
        "claudeUsd": round(c_usd, 4), "claudeTokens": int(c_tok),
        "codexUsd": round(x_usd, 4), "codexTokens": int(x_tok),
        "totalUsd": round(c_usd + x_usd, 4),
        # Both flags exist so nobody reads this as billing truth.
        "estimate": True,
        "unknownModels": sorted(unknown)[:10],
        "at": datetime.now().astimezone().isoformat(timespec="seconds"),
    }


def main():
    out = collect()
    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        tmp = CACHE + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(out, fh)
        os.replace(tmp, CACHE)      # atomic: a poll never reads a half file
    except OSError as exc:
        sys.stderr.write("af-cost: cannot write %s: %s\n" % (CACHE, exc))
    print(json.dumps(out))


if __name__ == "__main__":
    if "--cached" in sys.argv:
        try:
            print(open(CACHE).read().strip())
        except OSError:
            print("{}")     # a missing cache is an empty reading, not a crash
    else:
        main()
