# cc-notifier

Get a sound + desktop notification on your Mac when **Claude Code** finishes a round of work — or when it stops to ask you a question. Works whether Claude Code runs **locally on your Mac** or **on a remote machine** (HPC login node, dev box, container) over an SSH reverse tunnel.

No polling, no daemons you babysit: it rides Claude Code's hooks and a tiny launchd listener.

## What you get

- **Round complete** → a short chime (or, when *armed*, a 15s×3 alarm with a Stop button for when you've walked away).
- **Claude needs your input** (the `AskUserQuestion` multiple-choice prompt) → a distinct sound + a persistent alert.
- **Arm/disarm per session**, a global **stop hotkey**, and a **health check** that warns you at session start if the tunnel is down.

## How it works

```
[ machine running Claude Code ]                      [ your Mac ]
  Stop / AskUserQuestion / ...  hooks
        │  curl localhost:28765/<beep|alarm|ask|stop>
        ▼
   (local CC: direct)  ────────────────────────────►  launchd listener
   (remote CC: ssh -R 28765 reverse tunnel) ────────►  (127.0.0.1 + ::1)
                                                          │
                                              afplay + alerter (sound + alert)
```

The hooks are **identical** for local and remote use. The only difference: a remote machine reaches your Mac's listener through an SSH `RemoteForward`; a local Mac hits it directly.

## Requirements

- **Receiver (your Mac):** macOS, [Homebrew](https://brew.sh), and [`alerter`](https://github.com/vjeantet/alerter) (the installer runs `brew install vjeantet/tap/alerter`). `alerter` provides the Stop button; on macOS Tahoe 26 `terminal-notifier` no longer can.
- **Sender (any machine where Claude Code runs):** `bash`, `curl`, `python3`.
- **Remote senders:** the SSH server must allow reverse port forwarding (`AllowTcpForwarding`).

## Quick start

### 1. On your Mac (the notification target)

```bash
bash install.sh          # auto-detects macOS → receiver role
```

Then finish the one-time GUI steps the installer prints:

1. **System Settings → Notifications → alerter** → Allow, style **Alerts**.
2. **System Settings → Focus → (each mode)** → allow the **alerter** app (so notifications pierce Do-Not-Disturb / Work focus).
3. **Stop hotkey:** Shortcuts app → new shortcut → *Run Shell Script* `~/.cc-notifier/cc_stop.sh` → assign a key (e.g. ⌃⌥Z; avoid ⌘-combos and ⌃⌥Space).
4. Pick sounds: `~/.cc-notifier/cc_preview_sounds.sh loop`.

### 2. On a remote machine (where Claude Code runs)

```bash
bash install.sh          # auto-detects Linux → sender role
```

Then add **one line** to your Mac's `~/.ssh/config`, under the host you use for that machine:

```
RemoteForward 28765 localhost:28765
```

Reconnect (or `ssh -O forward -R 28765:localhost:28765 <host>`), and make sure the receiver is installed on your Mac. Restart the Claude Code session so the hooks load.

## Usage

```bash
~/.cc-notifier/cc_notify_arm.sh on      # armed: long alarm at round end (you're away)
~/.cc-notifier/cc_notify_arm.sh off     # disarmed: short chime (you're at the desk)
~/.cc-notifier/cc_notify_arm.sh status

~/.cc-notifier/cc_tunnel_test.sh ping   # is the path healthy?
~/.cc-notifier/cc_tunnel_test.sh beep   # fire each notification type to test
~/.cc-notifier/cc_tunnel_test.sh alarm
~/.cc-notifier/cc_tunnel_test.sh ask
```

The arm flag lives at `~/.cc-notifier/armed` and persists across reboots.

## Hooks installed (user-level `~/.claude/settings.json`)

| Event | Matcher | Action |
|---|---|---|
| `Stop` | — | round complete → `/beep` (disarmed) or `/alarm` (armed); skips turns < 20s |
| `PreToolUse` | `AskUserQuestion` | CC needs your input → `/ask` (always) |
| `UserPromptSubmit` | — | record turn-start + cancel any active alarm |
| `SessionStart` | — | warn in-context if the listener is unreachable |

Merged idempotently — re-running the installer never duplicates hooks or clobbers your existing ones.

## Configuration

Sound, number of repeats, and spacing for the **long alarms** (`done` and `ask`) live in **`~/.cc-notifier/config`** on the Mac (created on install). Edit it — changes apply on the next alarm, no reload. The short **beep is always a single play** (its sound is configurable; repeats are not).

```sh
# ~/.cc-notifier/config
CC_ALARM_SOUND=/System/Library/Sounds/Blow.aiff   # armed round-end alarm
CC_ALARM_REPEATS=10                                # how many times the sound plays
CC_ALARM_INTERVAL=1                                # seconds between plays
CC_ASK_SOUND=/System/Library/Sounds/Funk.aiff      # "needs your input"
CC_ASK_REPEATS=3
CC_ASK_INTERVAL=1
CC_BEEP_SOUND=/System/Library/Sounds/Glass.aiff    # disarmed chime (single play)
```

Preview options with `~/.cc-notifier/cc_preview_sounds.sh loop`.

Sender-side env vars (on the machine running Claude Code):

| Var | Default | Meaning |
|---|---|---|
| `CC_NOTIFY_PORT` | `28765` | listener port (use `install.sh --port N` to set everywhere) |
| `CC_NOTIFY_MIN_SECONDS` | `20` | skip round-end notify for shorter turns (`0` = always) |

## Troubleshooting

- **No beep, `cc_tunnel_test.sh ping` fails with exit 56** — the reverse tunnel is stale. From your Mac: `ssh -O cancel -R 28765:localhost:28765 <host>; ssh -O forward -R 28765:localhost:28765 <host>`.
- **Sound plays but no visual alert** — grant `alerter` notification permission (Alerts style) and allow it in your Focus modes.
- **Stop hotkey only works when a window is focused** — the combo is already taken (e.g. ⌃⌥Space = input-source switch). Pick a free one; `~/.cc-notifier/cc_check_hotkeys.py <key>` lists system shortcuts.

## Uninstall

```bash
bash install.sh --uninstall     # removes hooks + launchd; leaves ~/.cc-notifier (rm -rf to finish)
```

## Development

`install.sh` is **generated** — don't edit it directly. The real sources live in `src/`:

```
src/sender/               hooks + arm/test scripts (run wherever Claude Code runs)
src/receiver/             listener, alarms, sound/hotkey helpers (run on the Mac)
src/install.template.sh   the installer framework
build.sh                  bundles src/ into the self-contained install.sh
```

Edit a file under `src/`, run `./build.sh`, then commit both the source change and the regenerated `install.sh`.

## License

MIT — see [LICENSE](LICENSE).
