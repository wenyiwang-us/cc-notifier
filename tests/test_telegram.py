#!/usr/bin/env python3
"""Checks for src/receiver/cc_telegram.py: how a notification becomes Telegram messages.

    python3 tests/test_telegram.py
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "receiver"))
import cc_telegram as t  # noqa: E402

STATUS = "Claude Code: Round complete — host/proj"


def shown(part):
    return t.u16(t.render(part, False))


def test_a_short_body_is_one_plain_message():
    parts = t.compose("Planner tuning", "All four smokes passed.\n\n• S2\n• S3", STATUS)
    assert len(parts) == 1 and parts[0]["fold"] == ""
    assert t.render(parts[0], True) == "<b>Planner tuning</b>\nAll four smokes passed.\n\n• S2\n• S3\n\n" + STATUS
    assert t.render(parts[0], False) == "Planner tuning\nAll four smokes passed.\n\n• S2\n• S3\n\n" + STATUS


def test_a_long_body_opens_and_folds_the_rest():
    body = "The opening paragraph says what happened.\n\n" + "\n\n".join("Paragraph %d has the detail <b> & more." % i for i in range(60))
    parts = t.compose("Planner tuning", body, STATUS)
    assert len(parts) == 1, len(parts)
    p = parts[0]
    assert p["text"].startswith("The opening paragraph says what happened.") and t.u16(p["text"]) <= t.OPENING
    assert p["text"] + "\n\n" + p["fold"] == body                              # nothing lost, nothing repeated
    h = t.render(p, True)
    assert h.startswith("<b>Planner tuning</b>\nThe opening paragraph") and h.endswith("</blockquote>\n" + STATUS)
    assert "<blockquote expandable>" in h and "&lt;b&gt; &amp; more." in h and "<b> & more" not in h


def test_a_very_long_body_goes_out_in_order_and_whole():
    paras = ["Paragraph %d. " % i + "It carries a sentence of ordinary length for the report. " * 4 for i in range(120)]
    body = "\n\n".join(paras)
    parts = t.compose("Planner tuning", body, STATUS)
    assert len(parts) > 3 and all(shown(p) <= 4096 for p in parts), [shown(p) for p in parts]
    assert parts[0]["tail"] == STATUS and all(p["tail"] == "" for p in parts[1:])
    assert [p["head"] for p in parts[1:]] == ["(%d/%d) Planner tuning" % (i, len(parts)) for i in range(2, len(parts) + 1)]
    joined = "\n\n".join([parts[0]["text"]] + [p["fold"] for p in parts])
    assert joined.split() == body.split()                                      # every word, once, in order
    assert all(p["fold"].endswith(".") for p in parts)                         # cuts fall between paragraphs


def test_a_heading_stays_with_its_section():
    body = "The opening.\n\n" + "\n\n".join("Section %d\n\nParagraph %d explains one result in ordinary sentences. " % (i, i) + "More of it. " * 12 for i in range(40))
    parts = t.compose("T", body, STATUS)
    assert len(parts) >= 2
    assert not parts[0]["text"].splitlines()[-1].startswith("Section")           # not left dangling above the fold
    assert all(not p["fold"].splitlines()[-1].startswith("Section") for p in parts)
    assert all(p["fold"].startswith("Section") for p in parts)                  # each part opens with its heading
    joined = "\n\n".join([parts[0]["text"]] + [p["fold"] for p in parts])
    assert joined.split() == body.split()


def test_no_folding_on_request():
    body = "word " * 2000
    parts = t.compose("T", body, STATUS, fold=0)
    assert len(parts) == 3 and all(p["fold"] == "" for p in parts) and all(shown(p) <= 4096 for p in parts)
    assert " ".join(p["text"] for p in parts).split() == body.split()


def test_counting_is_telegrams():
    body = "\U0001F389" * 5000                                                 # each counts as two
    parts = t.compose("T", body, STATUS, fold=0)
    assert all(shown(p) <= 4096 for p in parts) and sum(p["text"].count("\U0001F389") for p in parts) == 5000
    assert t.take("one two three", 100) == ("one two three", "")
    assert t.take("First sentence here. Second one follows and is long.", 30) == ("First sentence here.", "Second one follows and is long.")


if __name__ == "__main__":
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for name, fn in tests:
        fn()
        print("ok  ", name)
    print("%d passed" % len(tests))
