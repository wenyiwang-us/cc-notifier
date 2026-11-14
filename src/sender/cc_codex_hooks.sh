#!/bin/bash
# Turn round-end notifications for Codex on or off. Usage: cc_codex_hooks.sh [on|off|status]
#
# Codex reads hooks of the same shape as Claude Code's from ~/.codex/hooks.json and
# hands them the same kind of payload, so it gets the same two scripts:
#   UserPromptSubmit -> notify_stop.sh codex        Stop -> notify_done.sh codex
# `on` appends them after whatever is in the file; nothing already there is moved or
# changed, and the previous file is kept as hooks.json.bak-cc-notifier. `off` takes
# them out again. Codex decides when a hook runs: it asks you to review hooks first,
# and it needs `codex_hooks = true` under [features] in ~/.codex/config.toml. This
# script changes neither.
HERE="$(cd "$(dirname "$0")" && pwd)"
CODEX="${CODEX_HOME:-$HOME/.codex}"
ACT="${1:-status}"
case "$ACT" in on|off|status) ;; *) echo "usage: $0 [on|off|status]"; exit 2;; esac
[ -d "$CODEX" ] || { echo "Codex is not set up here ($CODEX not found)."; exit 1; }
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
"$PYBIN" - "$CODEX/hooks.json" "$HERE" "$ACT" <<'PY' || exit $?
import json, os, shutil, sys
path, d, act = sys.argv[1:4]
cmds = {"UserPromptSubmit": os.path.join(d, "notify_stop.sh") + " codex",
        "Stop": os.path.join(d, "notify_done.sh") + " codex"}

def stop(msg, code=1):
    print(msg)
    sys.exit(code)

existed = True
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg, existed = {}, False
except Exception as e:
    stop("%s could not be read as JSON (%s); left untouched." % (path, e))
hooks = cfg.setdefault("hooks", {}) if isinstance(cfg, dict) else None
if not isinstance(hooks, dict) or not all(isinstance(hooks.get(ev, []), list) for ev in cmds):
    stop("%s has an unexpected layout; left untouched." % path)

def has(group, cmd):
    return isinstance(group, dict) and any(isinstance(h, dict) and h.get("command") == cmd for h in group.get("hooks") or [])

present = [ev for ev, cmd in cmds.items() if any(has(g, cmd) for g in hooks.get(ev, []))]
if act == "status":
    stop("Codex hooks: %d/%d in %s" % (len(present), len(cmds), path), 0 if len(present) == len(cmds) else 3)
changed = []
for ev, cmd in cmds.items():
    if act == "on" and ev not in present:
        hooks.setdefault(ev, []).append({"hooks": [{"type": "command", "command": cmd, "timeout": 5}]})
        changed.append(ev)
    elif act == "off" and ev in present:
        for g in hooks[ev]:
            if has(g, cmd):
                g["hooks"] = [h for h in g["hooks"] if not (isinstance(h, dict) and h.get("command") == cmd)]
        hooks[ev] = [g for g in hooks[ev] if not (isinstance(g, dict) and g.get("hooks") == [])]
        if not hooks[ev]:
            del hooks[ev]
        changed.append(ev)
if not changed:
    stop("Codex hooks already %s in %s" % ("present" if act == "on" else "absent", path), 0)
if existed:
    shutil.copy2(path, path + ".bak-cc-notifier")
with open(path + ".tmp", "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(path + ".tmp", path)
print("Codex: %s hooks %s %s" % (" + ".join(changed), "added to" if act == "on" else "removed from", path))
PY
if [ "$ACT" = on ]; then
  echo "Codex runs hooks only after you have reviewed them there. If it says hooks need review (the new ones, or earlier ones again), approve them in Codex."
  grep -Eqs '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$CODEX/config.toml" \
    || echo "Hooks also need 'codex_hooks = true' under [features] in $CODEX/config.toml."
fi
exit 0
