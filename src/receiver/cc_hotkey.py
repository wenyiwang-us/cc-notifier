#!/usr/bin/env python3
"""Print the cc-notifier stop hotkey as a chord (e.g. "⌃⌥Z"), read from the
Karabiner-Elements config, so the alarm banner can remind you how to silence it.
Looks at the active config first, then the staged asset. Prints nothing if no
cc-notifier rule is found (e.g. Karabiner not used)."""
import json
import os

SYM = {"control": "⌃", "option": "⌥", "command": "⌘", "shift": "⇧", "fn": "fn"}
ORDER = ["control", "option", "shift", "command", "fn"]


def _base(mod):
    return mod.replace("left_", "").replace("right_", "")


def chord_from_rule(rule):
    for m in rule.get("manipulators", []):
        frm = m.get("from", {})
        key = frm.get("key_code")
        if not key:
            continue
        mods = frm.get("modifiers", {}).get("mandatory", [])
        mods = sorted(mods, key=lambda x: ORDER.index(_base(x)) if _base(x) in ORDER else 99)
        syms = "".join(SYM.get(_base(x), "") for x in mods)
        return f"{syms}{key.upper()}"
    return None


def find_chord():
    home = os.path.expanduser("~")
    active = os.path.join(home, ".config/karabiner/karabiner.json")
    try:
        with open(active) as f:
            cfg = json.load(f)
        for prof in cfg.get("profiles", []):
            for rule in prof.get("complex_modifications", {}).get("rules", []):
                if "cc-notifier" in rule.get("description", "").lower():
                    c = chord_from_rule(rule)
                    if c:
                        return c
    except Exception:
        pass
    asset = os.path.join(home, ".config/karabiner/assets/complex_modifications/cc-notifier.json")
    try:
        with open(asset) as f:
            data = json.load(f)
        for rule in data.get("rules", []):
            c = chord_from_rule(rule)
            if c:
                return c
    except Exception:
        pass
    return None


if __name__ == "__main__":
    c = find_chord()
    if c:
        print(c)
