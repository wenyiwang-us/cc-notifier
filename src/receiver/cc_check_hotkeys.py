#!/usr/bin/env python3
"""List enabled macOS *system* keyboard shortcuts (does NOT cover app/3rd-party).
Usage: cc_check_hotkeys.py [filter]"""
import os, plistlib, subprocess, sys
PLIST = os.path.expanduser("~/Library/Preferences/com.apple.symbolichotkeys.plist")
MODS = [(1<<17,"Shift"),(1<<18,"Control"),(1<<19,"Option"),(1<<20,"Command")]
def mods(m): return "+".join(s for b,s in MODS if int(m)&b) or "(none)"
def kc(p1,p2): p1=int(p1); return chr(p1).upper() if 32<=p1<127 else f"keycode-{int(p2)}"
def main():
    needle = sys.argv[1].lower() if len(sys.argv)>1 else None
    try:
        xml = subprocess.run(["plutil","-convert","xml1","-o","-",PLIST],capture_output=True,check=True).stdout
        keys = plistlib.loads(xml).get("AppleSymbolicHotKeys",{})
    except Exception as e: print(f"could not read {PLIST}: {e}"); return
    rows=[]
    for kid,info in keys.items():
        if not isinstance(info,dict) or not info.get("enabled"): continue
        v=info.get("value",{}); p=v.get("parameters") if isinstance(v,dict) else None
        if not p or len(p)<3: continue
        rows.append(f"{mods(p[2])+' + '+kc(p[0],p[1]):28s}  system hotkey id {kid}")
    for r in sorted(rows):
        if not needle or needle in r.lower(): print(r)
    print("\nApp-menu & third-party global hotkeys are NOT listed — also check System Settings > Keyboard > Keyboard Shortcuts.")
if __name__=="__main__": main()
