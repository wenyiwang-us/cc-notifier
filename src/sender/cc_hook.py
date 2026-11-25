#!/usr/bin/env python3
"""Per-session decisions for the cc-notifier hooks (sender side).

Works for any agent whose hooks hand over a Claude Code style JSON payload
(`session_id`, `prompt`, `last_assistant_message`, ...): Claude Code and Codex do.

Every session keeps its own state file, <dir>/sessions/<session_id>.json, so one
session's prompts, stops and background tasks never change what another
session's hooks decide:

  turn_start   when the current turn began
  human_start  when a person last typed a prompt in this session
  busy         a turn is in progress (a prompt started it, no Stop since)
  owed         an earlier Stop stayed silent because background work was in flight
  alarm        this session raised an alarm that has not been cancelled yet
  title        the session title the agent reports
  seq          counts this session's prompts and stops (tells a pause from a resume)
  seen         when each background task was first seen in flight at a stop
  told_at      when this session last notified
  pending      the notice to send if the pause after a held stop lasts too long
  paused_told  a "still waiting" notice went out since the last full notification

usage: cc_hook.py prompt [agent] | done <alarm|beep> [agent] | ask [agent] | check
       (hook payload on stdin; `agent` names who is calling, e.g. codex)
       cc_hook.py late <alarm|beep> <session_id> <seq>     (no payload; see notify_done.sh)

Prints one field per line for the calling hook script. On any failure it prints
nothing, and the callers then notify without a summary (never over-suppress).
The message itself, for the phone push, has line breaks, so it goes into files:
<dir>/sessions/<session_id>.body (whole) and .short (its first 3,400 characters,
for a listener that cannot take the whole). Their paths are the last two fields.
"""
import glob
import json
import os
import re
import socket
import subprocess
import sys
import time


def _env_int(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


DIR = os.environ.get("CC_NOTIFIER_DIR") or os.path.join(os.path.expanduser("~"), ".cc-notifier")
STATE_DIR = os.path.join(DIR, "sessions")
MIN_SECONDS = _env_int("CC_NOTIFY_MIN_SECONDS", 20)
BRIEF_CHARS = _env_int("CC_NOTIFY_BRIEF_CHARS", 240)   # longest summary; one sentence is rarely longer
# The phone push carries more than the alert can show: the final message itself as
# plain text. The receiver splits it over as many Telegram messages as it takes,
# so this bound is only a guard against a runaway output.
BODY_CHARS = min(_env_int("CC_NOTIFY_BODY_CHARS", 40000), 60000)
SHORT_CHARS = 3400       # what a listener older than protocol 5 can show
TITLE_CHARS = 60
# Background-task types that do not hold a notification back. A `monitor` is an
# open-ended watch (e.g. "live updates for artifact ..."): it never finishes, so a
# session holding one would otherwise never notify.
STANDBY_IGNORE = set(os.environ.get("CC_NOTIFY_STANDBY_IGNORE", "monitor").lower().replace(",", " ").split())
# A session's own background work holds its notification back, but not for ever.
# PAUSE_SECONDS: a pause that lasts this long is reported ("still waiting on ...").
# QUIET_SECONDS: the longest that background work can keep a session quiet. A task
# in flight for that long (a standing watcher, a wait for a queued job) no longer
# holds anything, and a session that has not notified for that long reports its
# next round end even while younger work is in flight. 0 switches a rule off.
PAUSE_SECONDS = _env_int("CC_NOTIFY_PAUSE_SECONDS", 300)
QUIET_SECONDS = _env_int("CC_NOTIFY_QUIET_SECONDS", 1800)
# `source` values Claude Code uses for prompts it injects itself.
MACHINE_SOURCES = ("system", "loop_wakeup", "schedule_wakeup", "poll_event")
# What a hook command may call its agent (`notify_done.sh codex`) -> name shown.
AGENTS = {"claude": "Claude Code", "claude-code": "Claude Code", "cc": "Claude Code", "codex": "Codex"}
# A period after one of these does not end a sentence.
ABBREVIATIONS = ("e.g", "i.e", "etc", "vs", "cf", "al", "approx", "fig", "figs", "sec", "eq", "no", "nos",
                 "dr", "mr", "mrs", "ms", "st", "inc", "ltd", "resp", "ca")
SENTENCE_END = re.compile(r"[.!?]+[\"')\]”’]*(?=\s+[\"'(\[“‘]?[A-Z0-9])|[。！？]")
AUDIENCE = re.compile(r"(?i)^written for:.*?(?:[.!?](?=\s|$)|$)\s*")


# --- small helpers -----------------------------------------------------------

def one_line(s):
    """One printable line: line breaks and control characters become spaces."""
    return " ".join("".join(c if c.isprintable() else " " for c in str(s)).split())


def as_list(v):
    if v is None:
        return []
    return v if isinstance(v, list) else [v]


def session_key(d):
    return re.sub(r"[^A-Za-z0-9_-]", "", str(d.get("session_id") or ""))[:64]


def state_path(sid):
    return os.path.join(STATE_DIR, sid + ".json")


def load(sid):
    if not sid:
        return {}
    try:
        with open(state_path(sid)) as f:
            st = json.load(f)
    except Exception:
        return {}
    return st if isinstance(st, dict) else {}


def save(sid, st):
    if not sid:
        return
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = "%s.tmp.%d" % (state_path(sid), os.getpid())
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, state_path(sid))
    except Exception:
        pass


# --- text for the notification ---------------------------------------------

def clean(line):
    """Markdown line -> plain text."""
    s = re.sub(r"^\s*>+\s?", "", line)                         # quote
    s = re.sub(r"^\s*#+\s*", "", s)                            # heading
    s = re.sub(r"^\s*(?:[-*+•]|\d+[.)])\s+(?:\[[ xX]\]\s+)?", "", s)  # list marker, checkbox
    s = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", s)           # [text](url) -> text
    s = re.sub(r"</?[A-Za-z][\w-]*(?:\s[^<>]*)?/?>", "", s)    # html-like tags
    s = s.replace("**", "").replace("`", "")
    return one_line(s)


def blocks(msg):
    """Cleaned blocks of a message in order: ("p", prose paragraph or list item)
    and ("h", heading or table row). Code blocks are dropped."""
    para, fenced = [], False
    for raw in str(msg or "")[:20000].splitlines() + [""]:   # the brief comes from the start
        line = raw.strip()
        if line.startswith(("```", "~~~")):
            fenced, line = not fenced, ""
        elif fenced:
            line = ""
        kind = ("h" if re.match(r"#{1,6}\s|\||[-=*_ ]{3,}$", line) else
                "i" if re.match(r"(?:[-*+•]|\d+[.)])\s", line) else
                "p" if line else "")
        if kind == "p":
            para.append(clean(line))
            continue
        if para:
            yield "p", one_line(" ".join(para))
            para = []
        if kind:
            yield ("p" if kind == "i" else "h"), clean(line.strip("| "))


def first_sentence(text, least=12):
    """The first sentence of a paragraph; more than one while they are too short
    to say anything ("Done. All four runs passed.")."""
    text = one_line(text)
    for m in SENTENCE_END.finditer(text):
        word = re.search(r"([^\s(\[\"']*?)[.!?]+[\"')\]”’]*$", text[:m.end()])
        token = word.group(1).lower() if word else ""
        if token in ABBREVIATIONS or re.match(r"[a-z]$", token):
            continue                              # "e.g. Foo", an initial: the sentence goes on
        if m.end() >= least:
            return text[:m.end()]
    return text


def summary(msg, limit):
    """One sentence for the notification: how the final message opens. Agents lead
    with the outcome, so this is the round's own summary. Code blocks, tables,
    headings and a "Written for: ..." audience sentence are skipped; a lead-in that
    only announces what follows ("Status:") takes the next block with it."""
    lead = fallback = ""
    for kind, text in blocks(msg):
        if kind == "h":
            if not fallback and re.search(r"\w", text):
                fallback = text
            continue
        if not lead:
            text = AUDIENCE.sub("", text)
            if not text:
                continue
        sentence = first_sentence(text)
        if not lead and sentence.endswith(":") and len(sentence) < 30:
            lead = sentence
            continue
        return shorten((lead + " " + sentence).strip(), limit)
    return shorten(lead or fallback, limit)


def table_lines(rows):
    """A markdown table as lines that read on a narrow screen. With a header row,
    each row becomes its first cell followed by "header: cell" lines."""
    cells = [[clean(c) for c in r.strip().strip("|").split("|")] for r in rows]
    is_rule = lambda r: bool(r) and all(re.match(r":?-{2,}:?$", c) for c in r)
    if len(cells) < 3 or not is_rule(cells[1]):
        return [" | ".join(c for c in r if c) for r in cells if not is_rule(r)]
    head, out = cells[0], []
    for r in cells[2:]:
        if len(head) == 2:
            out.append("\u2022 " + ": ".join(c for c in r if c))
            continue
        out.append("\u2022 " + (r[0] if r else ""))
        out.extend("   %s: %s" % (h_, c) if h_ else "   " + c for h_, c in zip(head[1:], r[1:]) if c)
    return out


def plain(msg, limit):
    """The message as plain text for the phone push: markdown marks dropped, lists,
    paragraphs and code kept line by line, tables turned into lines. Over the
    limit it is cut at a line, and the last line says how much is left."""
    if limit <= 0:
        return ""
    out, fenced, table = [], False, []
    for raw in str(msg or "").splitlines() + [""]:
        line = raw.strip()
        if table and not (line.startswith("|") and not fenced):
            out.extend(table_lines(table))
            table = []
        if line.startswith(("```", "~~~")):
            fenced = not fenced
        elif fenced:
            out.append(one_line(raw.rstrip()) if raw.strip() else "")
        elif line.startswith("|"):
            table.append(line)
        elif not line or re.match(r"[-=*_ ]{3,}$", line):         # blank line, rule
            out.append("")
        else:
            item = re.match(r"([-*+\u2022]|\d+[.)])\s+(.*)", line)
            indent = " " * min(len(raw) - len(raw.lstrip()), 6)
            if item:
                mark = item.group(1) + " " if item.group(1)[0].isdigit() else "\u2022 "
                out.append(indent + mark + clean(item.group(2)))
            else:
                out.append(clean(line))
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip()
    text = AUDIENCE.sub("", text, count=1).lstrip()             # an opening "Written for: ..." sentence
    if len(text) <= limit:
        return text
    cut = text[:limit]
    at = cut.rfind("\n")
    if at < limit * 0.6:
        at = cut.rfind(" ")
    cut = cut[:at if at > 0 else limit].rstrip()
    return "%s\n\u2026 (%d more characters in the session)" % (cut, len(text) - len(cut))


def shorten(s, n):
    """At most n characters: ends at a sentence when one fits, else at a word plus an ellipsis."""
    s = one_line(s)
    if n <= 0:
        return ""
    if len(s) <= n:
        return s
    ends = [m.end() for m in re.finditer(r"[.!?](?=\s)|[。！？]", s[:n + 1]) if m.end() <= n]
    if ends and ends[-1] >= 12:
        return s[:ends[-1]]
    cut = s[:n - 1]
    sp = cut.rfind(" ")
    if sp >= n * 0.6:
        cut = cut[:sp]
    return cut.rstrip(" ,;:—-") + "…"


def transcript_title(path):
    """Latest session title recorded near the end of the transcript."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 262144))
            tail = f.read().decode("utf-8", "replace")
    except Exception:
        return ""
    for line in reversed(tail.splitlines()):
        if "-title" not in line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        if isinstance(e, dict) and e.get("type") in ("ai-title", "custom-title"):
            t = e.get("customTitle") or e.get("aiTitle") or e.get("title")
            if t:
                return one_line(t)
    return ""


def codex_thread_name(sid):
    """Codex keeps thread names in $CODEX_HOME/session_index.jsonl; the latest entry wins."""
    home = os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")
    try:
        with open(os.path.join(home, "session_index.jsonl"), "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 262144))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except Exception:
        return ""
    for line in reversed(lines):
        if sid not in line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        if isinstance(e, dict) and e.get("id") == sid and e.get("thread_name"):
            return one_line(e["thread_name"])
    return ""


def user_session_name(sid):
    """The name the user gave this session in Claude Code, from its live record
    ($CLAUDE_CONFIG_DIR or ~/.claude)/sessions/<pid>.json; "" when none. A rename lives
    only there: the transcript keeps the generated title."""
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    best = (0, "")
    for p in glob.glob(os.path.join(base, "sessions", "*.json")):
        try:
            with open(p, encoding="utf-8") as f:
                e = json.load(f)
            if isinstance(e, dict) and e.get("sessionId") == sid and e.get("nameSource") == "user" and e.get("name"):
                best = max(best, (os.path.getmtime(p), one_line(e["name"])))
        except Exception:
            continue
    return best[1]


def session_title(d, st, sid):
    """Session title as the user sees it: their own name for the session, else the one the
    agent records (Claude Code: transcript; Codex: thread index), else the last one seen."""
    title = (user_session_name(sid) if sid else "") or transcript_title(d.get("transcript_path") or "") \
        or (codex_thread_name(sid) if sid else "")
    if title:
        st["title"] = title
    return shorten(title or st.get("title") or "", TITLE_CHARS)


def agent_name(arg, d):
    """Who is notifying. The hook command names its agent (`notify_done.sh codex`);
    without that it is read off the payload."""
    arg = one_line(arg or "")
    if arg:
        return AGENTS.get(arg.lower(), arg)[:32]
    return "Codex" if "/.codex/" in str(d.get("transcript_path") or "") else "Claude Code"


def label(d):
    """host/project, from the session's working directory."""
    cwd = str(d.get("cwd") or "") or os.getcwd()
    return "%s/%s" % (socket.gethostname().split(".")[0] or "host", os.path.basename(cwd.rstrip("/")))


# --- decisions (pure: payload + state in, verdict out; state is updated in place) ---

def prompt_kind(d):
    """Who sent this prompt. An agent fires the prompt hook for a person's message
    and for its own: a subagent's turn, and in Claude Code a finished background
    task, another session handing back, a scheduled wake-up."""
    if d.get("agent_id"):
        return "subagent"
    if d.get("source") in MACHINE_SOURCES:
        return str(d.get("source"))
    head = str(d.get("prompt") or "").lstrip()[:300]
    if head.startswith("<task-notification"):
        return "task-notification"
    if "<agent-message from=" in head:
        return "agent-message"
    if "<cross-session-message from=" in head:
        return "session-message"
    return "typed"


def decide_prompt(d, st, now):
    """-> (cancel this session's alarm?, log text)"""
    kind = prompt_kind(d)
    cancel = False
    st["seq"] = st.get("seq", 0) + 1              # the session is no longer paused
    st.pop("pending", None)
    if kind == "typed":
        # A person is at this session: restart its clocks, and its alarm has been seen.
        cancel = bool(st.get("alarm"))
        st.update(turn_start=now, human_start=now, busy=True, owed=False, alarm=False, paused_told=False)
        turn = "started"
    elif not st.get("busy"):
        st.update(turn_start=now, busy=True)      # the agent woke the session itself
        turn = "started"
    else:
        turn = "running"                          # delivered mid-turn: the clock keeps running
    title = one_line(d.get("session_title") or "")
    if title:
        st["title"] = title
    return cancel, "kind=%s turn=%s" % (kind, turn)


def task_type(t):
    return str(t.get("type") or "").lower() if isinstance(t, dict) else "?"


def describe(t):
    if not isinstance(t, dict):
        return "?"
    desc = one_line(t.get("description") or t.get("command") or t.get("tool") or t.get("name") or "")[:60]
    text = "%s/%s%s" % (t.get("type"), t.get("status"), (":" + desc) if desc else "")
    return text + (" (not held)" if task_type(t) in STANDBY_IGNORE else "")


def task_key(t):
    return str(t.get("id") or t.get("description") or t.get("command") or "?")[:80] if isinstance(t, dict) else "?"


def decide_done(d, st, now, act):
    """-> (verdict, why, what was in flight); the last two are log text. Verdict:
    "notify"; "silent"; "held" (silent now, background work is in flight); or
    "progress" (work is in flight, but the session has been quiet for too long)."""
    tasks = as_list(d.get("background_tasks"))
    info = "cwd=%s bg=%d crons=%d" % (
        str(d.get("cwd") or "").rstrip("/").split("/")[-1], len(tasks), len(as_list(d.get("session_crons"))))
    if tasks:
        info += " bg_tasks=[%s]" % "; ".join(describe(t) for t in tasks[:6])
    if d.get("stop_hook_active"):                 # forced continuation: the turn goes on
        return "silent", "reason=stop_hook_active", info
    st["busy"] = False
    st["seq"] = st.get("seq", 0) + 1
    st.pop("pending", None)
    # Which of its own tasks still hold the notification: not the ignored types,
    # and not one that has been in flight for QUIET_SECONDS.
    seen, st["seen"], holding, old = st.get("seen") if isinstance(st.get("seen"), dict) else {}, {}, [], 0
    for t in tasks:
        if task_type(t) in STANDBY_IGNORE:
            continue
        first = seen.get(task_key(t), now)
        st["seen"][task_key(t)] = first
        if QUIET_SECONDS > 0 and now - first >= QUIET_SECONDS:
            old += 1
        else:
            holding.append(t)
    if old:
        info += " long_running=%d" % old
    if holding:
        st["owed"] = True                         # paused on its own work; it will be back
        quiet = None if last_contact(st) is None else now - last_contact(st)
        if PAUSE_SECONDS > 0 and QUIET_SECONDS > 0 and quiet is not None and quiet >= QUIET_SECONDS:
            if act != "beep":
                st["alarm"] = True
            st.update(told_at=now, paused_told=True)
            return "progress", "quiet=%ds" % quiet, info
        return "held", "reason=background_tasks", info
    # A stop that completes work an earlier stop left paused is timed from the
    # last prompt a person typed; any other stop from the start of its own turn.
    since = "last_typed_prompt" if st.get("owed") else "turn_start"
    ref = st.get("human_start") if st.get("owed") else st.get("turn_start")
    st["owed"] = False
    age = (now - ref) if isinstance(ref, (int, float)) else None
    if MIN_SECONDS > 0 and age is not None and 0 <= age < MIN_SECONDS:
        return "silent", "reason=quick_turn age=%ds min=%ds since=%s" % (age, MIN_SECONDS, since), info
    if act != "beep":
        st["alarm"] = True
    st.update(told_at=now, paused_told=False)
    return "notify", "age=%s since=%s" % ("?" if age is None else "%ds" % age, since), info


def last_contact(st):
    """When this session last notified, or a person last typed in it (None: unknown)."""
    known = [x for x in (st.get("told_at"), st.get("human_start")) if isinstance(x, (int, float))]
    return max(known) if known else None


def waiting_note(d, brief, body=None):
    """The summary of a round end that leaves background work in flight; with
    `body`, the same for the longer text (the note becomes its last paragraph)."""
    waiting = [t for t in as_list(d.get("background_tasks")) if task_type(t) not in STANDBY_IGNORE]
    first = one_line(waiting[0].get("description") or waiting[0].get("command") or "")[:60] if waiting and isinstance(waiting[0], dict) else ""
    note = "still waiting on %d background task%s%s" % (len(waiting), "" if len(waiting) == 1 else "s", (": " + first) if first else "")
    if body is not None:
        return (body + "\n\n" if body else "") + note[0].upper() + note[1:]
    return (brief + " \u2014 " + note) if brief else note[0].upper() + note[1:]


def plan_pause_notice(d, st, now, title, brief, agent, where, body=""):
    """After a held stop: remember what to say if the pause lasts too long, and how
    long that is. The first time in a round: PAUSE_SECONDS. After that: until the
    session has been quiet for QUIET_SECONDS (subagents handing back every few
    minutes should not each ring). -> (seconds to wait, seq to check then) or None."""
    if PAUSE_SECONDS <= 0 or (st.get("paused_told") and QUIET_SECONDS <= 0):
        return None
    wait = PAUSE_SECONDS
    if st.get("paused_told") and last_contact(st) is not None:
        wait = max(PAUSE_SECONDS, last_contact(st) + QUIET_SECONDS - now)
    st["pending"] = dict(seq=st.get("seq"), wait=wait, title=title, agent=agent, label=where,
                         brief=waiting_note(d, brief), body=waiting_note(d, brief, body) if body else "")
    return wait, st["pending"]["seq"]


def decide_late(st, seq, now, act):
    """The check after a held stop: still paused since then? -> notice or None."""
    notice = st.get("pending")
    if not isinstance(notice, dict) or notice.get("seq") != seq or st.get("seq") != seq or st.get("busy"):
        return None                               # it woke up meanwhile; its own stop decides
    del st["pending"]
    st.update(told_at=now, paused_told=True)
    if act != "beep":
        st["alarm"] = True
    return notice


def ask_brief(d):
    ti = d.get("tool_input")
    qs = [q for q in as_list(ti.get("questions") if isinstance(ti, dict) else None) if isinstance(q, dict)]
    if not qs:
        return ""
    more = " (+%d more)" % (len(qs) - 1) if len(qs) > 1 else ""
    return shorten(clean(str(qs[0].get("question") or qs[0].get("header") or "")), BRIEF_CHARS) + more


def ask_body(d):
    """The questions with their choices, for the phone push."""
    ti = d.get("tool_input")
    out = []
    for q in as_list(ti.get("questions") if isinstance(ti, dict) else None):
        if not isinstance(q, dict):
            continue
        out.append(clean(str(q.get("question") or q.get("header") or "")))
        for o in as_list(q.get("options")):
            if isinstance(o, dict) and o.get("label"):
                desc = clean(str(o.get("description") or ""))
                out.append("\u2022 " + clean(str(o["label"])) + ((": " + desc) if desc else ""))
        out.append("")
    return "\n".join(out).strip()[:BODY_CHARS] if BODY_CHARS > 0 else ""


def write_body(sid, text):
    """-> [path of the file with the whole body, path of the one with its opening]
    for this notification ("" where there is none)."""
    if not sid or not text:
        return ["", ""]
    short = text
    if len(text) > SHORT_CHARS:
        cut = text[:SHORT_CHARS]
        cut = cut[:cut.rfind("\n")].rstrip() if cut.rfind("\n") > SHORT_CHARS * 0.6 else cut
        short = "%s\n\u2026 (%d more characters in the session)" % (cut, len(text) - len(cut))
    paths = []
    for suffix, content in ((".body", text), (".short", short)):
        path = os.path.join(STATE_DIR, sid + suffix)
        try:
            os.makedirs(STATE_DIR, exist_ok=True)
            with open(path, "wb") as f:
                f.write(content.encode("utf-8", "replace"))
            paths.append(path)
        except Exception:
            paths.append("")
    return paths


# --- entry point -------------------------------------------------------------

def emit(*fields):
    out = "".join(one_line(f) + "\n" for f in fields)
    sys.stdout.buffer.write(out.encode("utf-8", "replace"))


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    if mode == "check":
        emit("ok")
        return
    os.umask(0o077)
    now = int(time.time())
    if mode == "late":                            # cc_hook.py late <act> <session_id> <seq>
        act, sid, seq = argv[2], re.sub(r"[^A-Za-z0-9_-]", "", argv[3])[:64], int(argv[4])
        st = load(sid)
        notice = decide_late(st, seq, now, act)
        if notice is None:
            return
        save(sid, st)
        title, brief, body = str(notice.get("title") or ""), str(notice.get("brief") or ""), str(notice.get("body") or "")
        emit("notify", sid, title, brief, "session=%s agent=%s paused=%ss title=%dc brief=%dc body=%dc" % (
            sid[:8], str(notice.get("agent") or "?").split()[0].lower(), notice.get("wait", "?"), len(title), len(brief), len(body)),
            notice.get("agent") or "", notice.get("label") or "", *write_body(sid, body))
        return
    try:
        d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
    except Exception:
        d = {}
    if not isinstance(d, dict):
        d = {}
    args = argv[2:]
    act = args.pop(0) if mode == "done" and args else "alarm"
    agent = agent_name(args[0] if args else "", d)
    sid = session_key(d)
    st = load(sid)
    tag = "session=%s agent=%s" % (sid[:8] or "?", agent.split()[0].lower())
    if mode == "prompt":
        cancel, info = decide_prompt(d, st, now)
        save(sid, st)
        emit("cancel" if cancel else "keep", sid, "%s %s" % (tag, info))
    elif mode == "done":
        verdict, why, info = decide_done(d, st, now, act)
        title = brief = body = ""
        check = None
        if verdict != "silent":
            title = session_title(d, st, sid)
            brief = summary(d.get("last_assistant_message"), BRIEF_CHARS)
            body = plain(d.get("last_assistant_message"), BODY_CHARS)
        if verdict == "progress":
            verdict, brief, body = "notify", waiting_note(d, brief), waiting_note(d, brief, body) if body else ""
        if verdict == "notify":
            info += " title=%dc brief=%dc body=%dc" % (len(title), len(brief), len(body))
        elif verdict == "held" and sid:
            check = plan_pause_notice(d, st, now, title, brief, agent, label(d), body)
            if check is not None:
                info += " notice_in=%ds" % check[0]
        save(sid, st)
        if check is not None:
            # Look again when the pause has lasted that long: a process of its own, so
            # it outlives this hook. It sends the notice only if nothing happened since.
            script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "notify_done.sh")
            try:
                subprocess.Popen(["/bin/bash", script, "--late", str(check[0]), sid, str(check[1])],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
            except Exception:
                pass
        # log text: "reason=... session=..." when silent, "session=... age=..." when sent
        emit("notify" if verdict == "notify" else "silent", sid, title if verdict == "notify" else "",
             brief if verdict == "notify" else "",
             "%s %s %s" % ((tag, why, info) if verdict == "notify" else (why, tag, info)), agent, label(d),
             *(write_body(sid, body) if verdict == "notify" else ["", ""]))
    elif mode == "ask":
        st["alarm"] = True
        title, brief, body = session_title(d, st, sid), ask_brief(d), ask_body(d)
        save(sid, st)
        emit("notify", sid, title, brief, "%s title=%dc brief=%dc body=%dc" % (tag, len(title), len(brief), len(body)),
             agent, label(d), *write_body(sid, body))


if __name__ == "__main__":
    main(sys.argv)
