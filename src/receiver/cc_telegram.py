#!/usr/bin/env python3
"""Send one notification to Telegram, whatever its length (receiver side).

Called by _attention.sh with everything in the environment:
  CC_TELEGRAM_TOKEN, CC_TELEGRAM_CHAT_ID   the bot and the chat
  CC_TG_STATUS            last line: agent, status, host/project
  CC_TITLE                session title
  CC_BODY_FILE            file with the final message as plain text, any length
                          (removed here once read; $CC_BODY is used when there is no file)
  CC_TELEGRAM_FOLD_CHARS  a body longer than this is folded (default 1500; 0 = never)

One Telegram message holds 4,096 characters, so a longer text goes out as several
messages, in order. To keep the chat short, a long body shows its opening and
folds the rest into an expandable quote: tap it to read on. Nothing is hosted
anywhere; the text lives in the chat and nowhere else.

The HTTPS call is curl's, as everywhere else in this kit. The bot token is part of
the URL, so curl reads the URL from its standard input (a config), never from its
command line, which any local user can list. Exit status 0 when the first message
was accepted; the caller sends its short form otherwise.
"""
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import time

LIMIT = 4000          # per message, counted as Telegram counts (UTF-16 units); the hard limit is 4096
OPENING = 700         # how much of a folded body stays visible above the fold
HERE = os.path.dirname(os.path.abspath(__file__))


def u16(s):
    return len(s.encode("utf-16-le")) // 2


def take(text, budget):
    """-> (head, rest): the longest head within budget that ends at a paragraph,
    else at a line, a sentence, a word."""
    if u16(text) <= budget:
        return text, ""
    cut = text[:budget]
    while u16(cut) > budget:                      # characters outside the basic plane count twice
        cut = cut[:-max(1, (u16(cut) - budget) // 2)]
    for sep, keep, least in (("\n\n", 0, 0.5), ("\n", 0, 0.5), (". ", 1, 0.4), (" ", 0, 0.3)):
        at = cut.rfind(sep)
        if at >= len(cut) * least:
            before = cut[:at].rfind("\n\n")
            last = cut[before + 2:at] if before >= 0 else ""
            if sep == "\n\n" and last and len(last) <= 80 and "\n" not in last and last[-1] not in ".!?:)\u2026" \
                    and before >= len(cut) * 0.3:
                at = before                       # a heading goes with the section it opens
            return cut[:at + keep].rstrip(), text[at + keep:].lstrip()
    return cut, text[len(cut):]


def compose(title, body, status, fold=1500, limit=LIMIT):
    """-> the messages to send, each a dict: head (bold), text (shown), fold (in an
    expandable quote), tail (status line). Their shown length stays within limit."""
    title, body, status = title.strip(), body.strip(), status.strip()
    shown, rest = body, ""
    if fold > 0 and u16(body) > fold:
        shown, rest = take(body, OPENING)
    first = dict(head=title, text=shown, fold="", tail=status)
    room = limit - u16(title) - u16(shown) - u16(status) - 8
    if fold <= 0:                                 # no folding: the body simply continues in the next message
        first["text"], rest = take(body, limit - u16(title) - u16(status) - 8)
    elif rest:
        first["fold"], rest = take(rest, max(room, 200))
    parts = [first]
    while rest:
        chunk, rest = take(rest, limit - u16(title) - 24)
        parts.append(dict(head="", text="" if fold > 0 else chunk, fold=chunk if fold > 0 else "", tail=""))
    for i, part in enumerate(parts[1:], 2):
        part["head"] = ("(%d/%d) %s" % (i, len(parts), title)).strip()
    return parts


def render(part, as_html):
    """One message as Telegram HTML, or as plain text when Telegram would not take that."""
    esc = (lambda s: html.escape(s, quote=False)) if as_html else (lambda s: s)
    out = []
    if part["head"]:
        out.append("<b>%s</b>" % esc(part["head"]) if as_html else part["head"])
    if part["text"]:
        out.append(esc(part["text"]))
    if part["fold"]:
        out.append("<blockquote expandable>%s</blockquote>" % esc(part["fold"]) if as_html else "\n" + part["fold"])
    text = "\n".join(out)
    if part["tail"]:
        text += ("\n" if part["fold"] and as_html else "\n\n") + esc(part["tail"])
    return text


def curl_config(options):
    """[(option, value)] -> a curl config file (curl --config -), values quoted."""
    q = lambda v: '"%s"' % v.replace("\\", "\\\\").replace('"', '\\"')
    return "".join("%s = %s\n" % (name, q(value)) for name, value in options).encode("utf-8")


def send(token, chat, text, as_html):
    """-> Telegram's answer as a dict ({} when there was none)."""
    if not (re.match(r"[0-9A-Za-z:_-]+\Z", token) and re.match(r"[0-9A-Za-z@_-]+\Z", chat)):
        return {"description": "CC_TELEGRAM_TOKEN or CC_TELEGRAM_CHAT_ID has an unexpected character"}
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".txt", delete=False) as f:
        f.write(text)
    options = [("url", "https://api.telegram.org/bot%s/sendMessage" % token),
               ("data-urlencode", "chat_id=" + chat), ("data-urlencode", "text@" + f.name),
               ("data-urlencode", "disable_web_page_preview=true")]
    if as_html:
        options.append(("data-urlencode", "parse_mode=HTML"))
    try:
        p = subprocess.run(["curl", "-s", "--max-time", "15", "--config", "-"], input=curl_config(options),
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return json.loads(p.stdout.decode("utf-8", "replace"))
    except Exception:
        return {}
    finally:
        os.unlink(f.name)


def deliver(token, chat, part):
    """Send one message: as HTML, then as plain text if Telegram refuses the HTML;
    wait once when it asks for a pause. -> (accepted?, what Telegram said)"""
    answer = {}
    for as_html in (True, False):
        for attempt in (1, 2):
            answer = send(token, chat, render(part, as_html), as_html)
            if answer.get("ok"):
                return True, "html" if as_html else "plain"
            wait = (answer.get("parameters") or {}).get("retry_after")
            if answer.get("error_code") != 429 or not isinstance(wait, int):
                break
            time.sleep(min(wait, 20) + 1)
    return False, "%s %s" % (answer.get("error_code", "no answer"), answer.get("description", ""))


def log(line):
    path = os.path.join(HERE, "telegram.log")
    try:
        if os.path.exists(path) and os.path.getsize(path) > 200000:
            os.replace(path, path + ".1")
        with open(path, "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), line))
    except Exception:
        pass


def main():
    env = os.environ
    try:
        os.setsid()       # outlive the alarm: stopping it must not leave half a message in the chat
    except OSError:
        pass
    token, chat = env.get("CC_TELEGRAM_TOKEN", ""), env.get("CC_TELEGRAM_CHAT_ID", "")
    body, path = env.get("CC_BODY", ""), env.get("CC_BODY_FILE", "")
    if path:
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                body = f.read()
            os.unlink(path)
        except Exception:
            pass
    if not (token and chat and body.strip()):
        return 1
    try:
        fold = int(env.get("CC_TELEGRAM_FOLD_CHARS") or 1500)
    except ValueError:
        fold = 1500
    parts = compose(env.get("CC_TITLE", ""), body, env.get("CC_TG_STATUS", ""), fold)
    tag = "session=%s chars=%d parts=%d" % (env.get("CC_SESSION", "")[:8] or "-", len(body), len(parts))
    for i, part in enumerate(parts, 1):
        ok, said = deliver(token, chat, part)
        if not ok:
            log("%s FAILED at part %d: %s" % (tag, i, said))
            return 1 if i == 1 else 0             # nothing sent: the caller's short form goes out instead
        if said == "plain":
            log("%s part %d sent as plain text (Telegram refused the formatted one)" % (tag, i))
        if i < len(parts):
            time.sleep(0.4)                       # keep the order, stay under the per-chat rate
    log("%s sent" % tag)
    return 0


if __name__ == "__main__":
    sys.exit(main())
