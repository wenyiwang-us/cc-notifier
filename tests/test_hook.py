#!/usr/bin/env python3
"""Checks for src/sender/cc_hook.py: per-session decisions and the one-sentence summary.

    python3 tests/test_hook.py
"""
import json
import os
import subprocess
import sys
import tempfile

SENDER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "sender")
sys.path.insert(0, SENDER)
import cc_hook as h  # noqa: E402


def _read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def _load(path):
    with open(path) as f:
        return json.load(f)


def _dump(obj, path):
    with open(path, "w") as f:
        json.dump(obj, f)

TYPED = {"prompt": "please fix the bug"}
TASK = {"prompt": "<task-notification>\n<task-id>b1</task-id>\n</task-notification>"}
SHELL = {"id": "b1", "type": "shell", "status": "running", "description": "wait for the job"}
MONITOR = {"id": "m1", "type": "monitor", "status": "running", "description": "live updates for artifact https://x"}


def stop(st, now, tasks=(), act="alarm", **extra):
    d = dict(background_tasks=list(tasks), stop_hook_active=False)
    d.update(extra)
    return h.decide_done(d, st, now, act)[0] == "notify"


def test_prompt_kind():
    assert h.prompt_kind(TYPED) == "typed"
    assert h.prompt_kind(TASK) == "task-notification"
    assert h.prompt_kind({"prompt": 'Another Claude session sent a message: <agent-message from="a1"> hi'}) == "agent-message"
    assert h.prompt_kind({"prompt": 'Another Claude session sent a message: <cross-session-message from="uds:/x">'}) == "session-message"
    assert h.prompt_kind({"prompt": "go on", "agent_id": "a1"}) == "subagent"
    for source in ("system", "loop_wakeup", "schedule_wakeup", "poll_event"):
        assert h.prompt_kind({"prompt": "check the queue", "source": source}) == source
    for source in ("user", "sdk"):
        assert h.prompt_kind({"prompt": "check the queue", "source": source}) == "typed"
    # a person quoting a notification further down the prompt is still a person
    assert h.prompt_kind({"prompt": "what does this mean?\n" + TASK["prompt"]}) == "typed"


def test_quick_and_long_turns():
    st = {}
    h.decide_prompt(TYPED, st, 0)
    assert stop(dict(st), 5) is False            # quick turn
    assert stop(dict(st), 30) is True
    assert stop({}, 30) is True                  # no state at all: notify


def test_wrap_up_after_background_work_notifies():
    st = {}
    h.decide_prompt(TYPED, st, 0)
    assert stop(st, 40, [SHELL]) is False        # paused on its own task
    h.decide_prompt(TASK, st, 600)               # the task finished and woke the session
    assert stop(st, 605) is True                 # 5 s wrap-up of 10 minutes of work
    h.decide_prompt(TASK, st, 900)               # a later self-started quick turn owes nothing
    assert stop(st, 905) is False


def test_person_back_at_the_desk_gets_no_alarm_for_a_quick_wrap_up():
    st = {}
    h.decide_prompt(TYPED, st, 0)
    assert stop(st, 40, [SHELL]) is False
    h.decide_prompt(TYPED, st, 100)              # typed again while the task runs
    assert stop(st, 104, [SHELL]) is False
    h.decide_prompt(TASK, st, 110)
    assert stop(st, 114) is False                # 14 s after they typed


def test_mid_turn_notification_keeps_the_clock():
    st = {}
    h.decide_prompt(TYPED, st, 0)
    cancel, info = h.decide_prompt(TASK, st, 100)
    assert cancel is False and "turn=running" in info and st["turn_start"] == 0
    assert stop(st, 105) is True


def test_monitor_does_not_hold_the_notification():
    st = {}
    h.decide_prompt(TYPED, st, 0)
    assert stop(dict(st), 60, [MONITOR]) is True
    assert stop(dict(st), 60, [MONITOR, SHELL]) is False


def verdict(st, now, tasks=()):
    return h.decide_done(dict(background_tasks=list(tasks), stop_hook_active=False), st, now, "alarm")[0]


def test_a_pause_that_lasts_is_reported():
    st, d = {}, {"background_tasks": [SHELL]}
    h.decide_prompt(TYPED, st, 0)
    assert verdict(st, 40, [SHELL]) == "held"
    wait, seq = h.plan_pause_notice(d, st, 40, "Title", "Queued the run.", "Claude Code", "host/proj")
    assert wait == h.PAUSE_SECONDS == 300
    notice = h.decide_late(st, seq, 340, "alarm")                # 5 minutes on, nothing has happened
    assert notice["brief"] == "Queued the run. — still waiting on 1 background task: wait for the job", notice
    assert st["alarm"] is True and st["owed"] is True            # the wrap-up is still owed
    assert h.decide_late(st, seq, 341, "alarm") is None          # never twice
    h.decide_prompt(TASK, st, 900)                               # one task finished; another still runs
    assert verdict(st, 905, [SHELL]) == "held"
    wait, seq = h.plan_pause_notice(d, st, 905, "T", "b", "a", "l")
    assert wait == 340 + 1800 - 905                              # told at 340: next notice once it has been quiet for 30 min
    h.decide_prompt(TASK, st, 1500)
    assert h.decide_late(st, seq, 2140, "alarm") is None         # it woke up before that
    assert verdict(st, 1505) == "notify"                         # the wrap-up notifies as before
    h.decide_prompt(TASK, st, 2000)
    assert verdict(st, 2100, [dict(SHELL, id="b2")]) == "held"   # a pause in the next round: 5 minutes again
    wait, seq = h.plan_pause_notice(d, st, 2100, "T", "", "a", "l")
    assert wait == 300 and st["pending"]["brief"] == "Still waiting on 1 background task: wait for the job"


def test_waking_up_before_the_limit_says_nothing():
    st = {}
    h.decide_prompt(TYPED, st, 0)
    assert verdict(st, 40, [SHELL]) == "held"
    wait, seq = h.plan_pause_notice({"background_tasks": [SHELL]}, st, 40, "T", "b", "a", "l")
    h.decide_prompt(TASK, st, 100)                               # woke up after a minute
    assert h.decide_late(st, seq, 340, "alarm") is None and "pending" not in st
    assert verdict(st, 105) == "notify"                          # and its wrap-up notifies


def test_a_busy_session_is_not_quiet_for_more_than_half_an_hour():
    st = {}
    h.decide_prompt(TYPED, st, 0)
    for i, now in enumerate(range(120, 1800, 120)):              # work keeps handing back every two minutes
        assert verdict(st, now, [dict(SHELL, id="t%d" % i)]) == "held", now
        h.decide_prompt(TASK, st, now + 60)
    assert verdict(st, 1810, [dict(SHELL, id="tx")]) == "progress"       # 30 minutes without a word: this round end is reported
    assert st["owed"] is True and st["told_at"] == 1810
    h.decide_prompt(TASK, st, 1900)
    assert verdict(st, 1960, [dict(SHELL, id="ty")]) == "held"           # and then not again for another 30 minutes
    assert h.waiting_note({"background_tasks": [SHELL, MONITOR]}, "Half done.") == \
        "Half done. — still waiting on 1 background task: wait for the job"


def test_a_long_running_task_stops_holding():
    watch = dict(SHELL, id="w1", description="watch the chat folder")
    st = {}
    h.decide_prompt(TYPED, st, 0)
    assert verdict(st, 40, [watch]) == "held"                    # first seen: it holds
    h.decide_prompt(TASK, st, 1000)
    assert verdict(st, 1100, [watch]) == "held"                  # 18 minutes on: still holds
    h.decide_prompt(TASK, st, 2000)
    v, why, info = h.decide_done(dict(background_tasks=[watch]), st, 2100, "alarm")
    assert v == "notify" and "long_running=1" in info, (v, info) # in flight for over 30 minutes: no longer
    h.decide_prompt(TASK, st, 3000)
    assert verdict(st, 3100, [watch, dict(SHELL, id="new")]) == "held"   # a fresh task next to it holds again
    h.decide_prompt(TASK, st, 4000)
    assert verdict(st, 4005, [watch]) == "notify"                # the fresh task is done: its wrap-up notifies
    h.decide_prompt(TASK, st, 5000)
    assert verdict(st, 5005, [watch]) == "silent"                # with only the watcher left, a 5 s tick is a quick turn


def test_forced_continuation_is_silent_and_leaves_state():
    st = {}
    h.decide_prompt(TYPED, st, 0)
    before = dict(st)
    assert stop(st, 60, stop_hook_active=True) is False
    assert st == before


def test_only_a_typed_prompt_cancels_this_sessions_alarm():
    st = {}
    h.decide_prompt(TYPED, st, 0)
    assert stop(st, 60) is True and st["alarm"] is True
    assert h.decide_prompt(TASK, st, 70)[0] is False and st["alarm"] is True
    assert h.decide_prompt(TYPED, st, 80)[0] is True and st["alarm"] is False
    assert h.decide_prompt(TYPED, st, 90)[0] is False      # nothing left to cancel
    assert stop(st, 150, act="beep") is True and st["alarm"] is False


def test_summary_is_one_sentence():
    one = lambda msg, n=240: h.summary(msg, n)
    assert one("## Result\n\nAll **four** smokes passed; see `run.log`. Details follow.\n\n- S2\n- S3") == \
        "All four smokes passed; see run.log."
    assert one("**No job is running.** We have two reproductions, but the last run failed.") == "No job is running."
    assert one("Written for: the team.\n\nThe [plan](docs/plan.md#L3) is updated. Next: review.") == "The plan is updated."
    assert one("**Written for:** you, on the 2.3 design. The rest follows.\n\n## Next") == "The rest follows."
    # a period that does not end the sentence: abbreviations, version numbers, file names
    assert one("Use e.g. Chutes for v0.4.0 of main.tex. Then rerun.") == "Use e.g. Chutes for v0.4.0 of main.tex."
    # too short to say anything: the next sentence comes along
    assert one("Done. All four runs passed. Logs are in run/.") == "Done. All four runs passed."
    # a lead-in that only announces what follows takes the next block with it
    assert one("Status:\n\n- 12 of 14 runs finished. Two are queued.\n- rest") == "Status: 12 of 14 runs finished."
    assert one("```\ncode\n```\n- first item is long enough\n- second") == "first item is long enough"
    assert one("Intro line\ncontinues here.\n- item") == "Intro line continues here."
    assert one("---\n| a | b |\n|---|---|\n| 1 | 2 |") == "a | b"
    assert one("") == "" and one(None) == ""
    long = one("The planner " + "keeps moving replicas between the pools " * 12 + "all night. Then it stops.", 100)
    assert len(long) <= 100 and long.endswith("…")          # one sentence over the limit is cut at a word
    assert h.shorten("short", 50) == "short" and h.shorten("anything", 0) == ""
    ask = {"tool_input": {"questions": [{"question": "Which trace?", "header": "Trace"}, {"question": "Which node count?"}]}}
    assert h.ask_brief(ask) == "Which trace? (+1 more)"
    assert h.ask_brief({}) == ""


def test_message_body_for_the_phone_push():
    msg = ("Written for: the team.\n\n**All four smokes passed.** See [run.log](logs/run.log#L3).\n\n"
           "## What changed\n\n- **S2:** now `cache off`\n  - nested point\n1. first step\n\n"
           "| Check | Result | Note |\n|---|---|---|\n| S2 | pass | 60/60 served |\n| S3 | fail | |\n\n"
           "| Knob | Value |\n|---|---|\n| pause | 300 |\n\n```bash\nqsub  run.sh   # keep  as typed\n```\n---\nDone.")
    assert h.plain(msg, 3000) == "\n".join([
        "All four smokes passed. See run.log.", "",
        "What changed", "",
        "• S2: now cache off", "  • nested point", "1. first step", "",
        "• S2", "   Result: pass", "   Note: 60/60 served", "• S3", "   Result: fail", "",
        "• pause: 300", "",
        "qsub run.sh # keep as typed", "",
        "Done."])
    long = "\n".join("Line %d of the report says something useful." % i for i in range(200))
    assert h.plain(long, h.BODY_CHARS) == long                    # no trimming at any length a message has
    cut = h.plain(long, 500)                                      # the bound only guards against a runaway output
    assert cut.startswith("Line 0 of") and len(cut) < 560, len(cut)
    assert cut.splitlines()[-1] == "… (%d more characters in the session)" % (len(long) - len("\n".join(cut.splitlines()[:-1])))
    assert h.plain("short", 3000) == "short" and h.plain("x", 0) == "" and h.plain(None, 100) == ""
    assert h.waiting_note({"background_tasks": [SHELL]}, "b", "Body text.") == \
        "Body text.\n\nStill waiting on 1 background task: wait for the job"
    ask = {"tool_input": {"questions": [{"question": "Which trace?", "options": [
        {"label": "Chutes", "description": "the recorded one"}, {"label": "Azure 2024"}]}]}}
    assert h.ask_body(ask) == "Which trace?\n• Chutes: the recorded one\n• Azure 2024"


def test_agent_name():
    assert h.agent_name("", {}) == "Claude Code"
    assert h.agent_name("", {"transcript_path": "/home/u/.codex/sessions/2026/10/05/rollout-x.jsonl"}) == "Codex"
    assert h.agent_name("codex", {}) == "Codex" and h.agent_name("claude", {}) == "Claude Code"
    assert h.agent_name("Nightly job", {"transcript_path": "/home/u/.codex/x"}) == "Nightly job"


def run(mode, payload, env_dir, *args):
    env = dict(os.environ, CC_NOTIFIER_DIR=env_dir, CODEX_HOME=os.path.join(env_dir, "codex"), LC_ALL="C",
               CC_NOTIFY_PAUSE_SECONDS="0")     # no deferred check from these runs
    p = subprocess.run([sys.executable, os.path.join(SENDER, "cc_hook.py"), mode] + list(args),
                       input=json.dumps(payload, ensure_ascii=False).encode("utf-8"), stdout=subprocess.PIPE, env=env)
    return p.stdout.decode("utf-8").split("\n")[:-1]


def test_sessions_are_independent_on_disk():
    with tempfile.TemporaryDirectory() as d:
        a = {"session_id": "aaaaaaaa-1111", "prompt": "long job", "session_title": "Session A — café"}
        b = {"session_id": "bbbbbbbb-2222", "prompt": "another job"}
        assert run("prompt", a, d)[:2] == ["keep", "aaaaaaaa-1111"]
        # make A's turn old enough to notify, then let B fire prompts and stops around it
        path = os.path.join(d, "sessions", "aaaaaaaa-1111.json")
        st = _load(path)
        st.update(turn_start=st["turn_start"] - 600, human_start=st["human_start"] - 600)
        _dump(st, path)
        assert run("prompt", b, d)[0] == "keep"
        assert run("prompt", dict(b, prompt=TASK["prompt"]), d)[0] == "keep"
        assert run("done", dict(b, last_assistant_message="ok"), d, "alarm")[0] == "silent"   # B's own quick turn
        out = run("done", dict(a, last_assistant_message="Done — 3 files changed. More detail below.\n\n- café.py\n- b.py", cwd="/x/proj"), d, "alarm")
        assert out[:4] == ["notify", "aaaaaaaa-1111", "Session A — café", "Done — 3 files changed."], out
        assert out[5] == "Claude Code" and out[6].endswith("/proj"), out
        # the message itself, for the phone push, is left in files, line breaks and all
        assert out[7:] == [os.path.join(d, "sessions", "aaaaaaaa-1111" + x) for x in (".body", ".short")], out
        assert _read(out[7]) == "Done — 3 files changed. More detail below.\n\n• café.py\n• b.py"
        assert _read(out[8]) == _read(out[7])     # short enough: the same
        big = "\n".join("Line %d of a long report." % i for i in range(1000))
        out = run("done", dict(a, last_assistant_message=big, cwd="/x/proj"), d, "alarm")
        whole, opening = _read(out[7]), _read(out[8])
        assert whole == big and len(opening) < 3500 and opening.startswith("Line 0 of") and "more characters in the session" in opening
        assert run("prompt", b, d)[0] == "keep"                    # B typing never cancels A's alarm
        assert run("prompt", a, d)[0] == "cancel"                  # A's own typed prompt does
        assert sorted(os.listdir(os.path.join(d, "sessions"))) == ["aaaaaaaa-1111.body", "aaaaaaaa-1111.json", "aaaaaaaa-1111.short", "bbbbbbbb-2222.json"]
        assert run("done", {}, d, "alarm")[0] == "notify"          # no session id: still notifies
        assert run("check", {}, d) == ["ok"]
        # the deferred check reads what the held stop left in the session's state
        st = _load(path)
        st.update(seq=7, busy=False, pending=dict(seq=7, title="Session A", brief="Queued — waiting", agent="Claude Code",
                                                 label="h/proj", body="Queued.\n\nStill waiting on 1 background task"))
        _dump(st, path)
        assert run("late", {}, d, "alarm", "aaaaaaaa-1111", "6") == []          # an older check: nothing
        out = run("late", {}, d, "alarm", "aaaaaaaa-1111", "7")
        assert out[:4] == ["notify", "aaaaaaaa-1111", "Session A", "Queued — waiting"] and out[5:7] == ["Claude Code", "h/proj"], out
        assert _read(out[7]) == "Queued.\n\nStill waiting on 1 background task"
        assert run("late", {}, d, "alarm", "aaaaaaaa-1111", "7") == []          # only once


def test_codex_payloads_use_the_same_path():
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "codex"))
        with open(os.path.join(d, "codex", "session_index.jsonl"), "w") as f:
            f.write(json.dumps({"id": "01a10977-ff71", "thread_name": "Old name"}) + "\n")
            f.write(json.dumps({"id": "01a10977-ff71", "thread_name": "Locate GPU runs and draw graph"}) + "\n")
        base = {"session_id": "01a10977-ff71", "cwd": "/home/u/paper", "model": "gpt", "permission_mode": "default",
                "turn_id": "t1", "transcript_path": None}
        out = run("prompt", dict(base, hook_event_name="UserPromptSubmit", prompt="draw the graph"), d, "codex")
        assert out[0] == "keep" and "agent=codex kind=typed" in out[2], out
        path = os.path.join(d, "sessions", "01a10977-ff71.json")
        st = _load(path)
        st.update(turn_start=st["turn_start"] - 600, human_start=st["human_start"] - 600)
        _dump(st, path)
        stop = dict(base, hook_event_name="Stop", stop_hook_active=False,
                    last_assistant_message="**The graph is drawn.** It is saved as [fig.pdf](/home/u/paper/fig.pdf).")
        out = run("done", stop, d, "alarm", "codex")
        assert out[:4] == ["notify", "01a10977-ff71", "Locate GPU runs and draw graph", "The graph is drawn."], out
        assert out[5] == "Codex" and out[6].endswith("/paper"), out
        assert run("prompt", dict(base, prompt="thanks"), d, "codex")[0] == "cancel"
        assert run("done", dict(stop, stop_hook_active=True), d, "alarm", "codex")[0] == "silent"


if __name__ == "__main__":
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for name, fn in tests:
        fn()
        print("ok  ", name)
    print("%d passed" % len(tests))
