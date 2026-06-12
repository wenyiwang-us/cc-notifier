# cc-notifier

Get a sound + desktop notification on your Mac when **Claude Code** finishes a round of work — or when it stops to ask you a question. Works whether Claude Code runs **locally on your Mac** or **on a remote machine** (HPC login node, dev box, container) over an SSH reverse tunnel.

No polling, no daemons you babysit: it rides Claude Code's hooks and a tiny launchd listener.

## What you get

- **Round complete** → a short chime (or, when *armed*, a 15s×3 alarm with a Stop button for when you've walked away).
- **Claude needs your input** (the `AskUserQuestion` multiple-choice prompt) → a distinct sound + a persistent alert.
- **Arm/disarm per session**, a global **stop hotkey**, **labeled** notifications (which host/project finished), and a **health check** that warns you at session start if the tunnel is down.

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

Fetch the single installer — it auto-detects its role (macOS → receiver, Linux → sender):

```bash
curl -fsSL https://raw.githubusercontent.com/wenyiwang-us/cc-notifier/main/install.sh -o install.sh
```

…or run it in one shot: `curl -fsSL https://raw.githubusercontent.com/wenyiwang-us/cc-notifier/main/install.sh | bash`

### 1. On your Mac (the notification target)

```bash
bash install.sh          # auto-detects macOS → receiver role
```

Then finish the one-time GUI steps the installer prints:

1. **System Settings → Notifications → alerter** → Allow, style **Alerts**.
2. **System Settings → Focus → (each mode)** → allow the **alerter** app (so notifications pierce Do-Not-Disturb / Work focus).
3. **Stop hotkey** (works even in the Claude Code chat box): the installer stages a **Karabiner-Elements** rule — enable it in *Karabiner → Complex Modifications → Add rule → "cc-notifier: Ctrl+Opt+Z → stop"*. Karabiner intercepts the key at the device level, so it fires even when the CC input (a webview) has focus. Without Karabiner, a macOS Shortcut running `~/.cc-notifier/cc_stop.sh` works everywhere **except** the CC input box.
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

~/.cc-notifier/cc_doctor.sh             # full health check: listener, tunnel, auth, perms, hotkey, Telegram
```

The arm flag lives at `~/.cc-notifier/armed` and persists across reboots. Notifications are labeled with `host/project` (from the machine running Claude Code) so you can tell sessions apart.

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

Preview options with `~/.cc-notifier/cc_preview_sounds.sh loop`. The alert banner also shows a static `(auto-off in Ns · N×Sound)` hint so you can see how it's configured at a glance.

Sender-side env vars (on the machine running Claude Code):

| Var | Default | Meaning |
|---|---|---|
| `CC_NOTIFY_PORT` | `28765` | listener port (use `install.sh --port N` to set everywhere) |
| `CC_NOTIFY_MIN_SECONDS` | `20` | skip round-end notify for shorter turns (`0` = always) |

## Phone push (Telegram, optional)

Get a Telegram message on your phone alongside the Mac alarm — free, and it uses the Telegram app you already have. It's **relayed from your Mac**, so the machine running Claude Code never talks to Telegram (which matters on networks that block it — e.g. some HPC sites sinkhole it). It fires for the long alarms (`done` armed, `ask`), and only while your Mac is on.

1. In Telegram, message **@BotFather** → `/newbot` → follow the prompts → copy the **bot token**.
2. Send your new bot any message (opens a chat it can reply in).
3. From your **Mac** (a network that can reach Telegram), open `https://api.telegram.org/bot<TOKEN>/getUpdates` and copy the `"chat":{"id": … }` number.
4. Add both to `~/.cc-notifier/config` on the Mac:
   ```sh
   CC_TELEGRAM_TOKEN=123456789:ABCdef...
   CC_TELEGRAM_CHAT_ID=123456789
   ```
5. Test: `~/.cc-notifier/cc_tunnel_test.sh alarm` → expect a Telegram push.

## Focus modes (break through Work, stay quiet in Sleep / Do Not Disturb)

The **banner** and the **sound** are gated by different mechanisms — set up both. (These steps are verified on macOS Tahoe 26.)

### Banner — pure System Settings, no code

1. **System Settings → Notifications → alerter** → Allow Notifications ON, style **Alerts** (Alerts persist and show the Stop button; Banners don't).
2. **System Settings → Focus → Work → Allowed Notifications → Apps → ＋ add `Terminal`.**
   ⚠️ **Add *Terminal*, not alerter.** alerter does **not** appear in the Focus app picker — its notifications are attributed to **Terminal** for Focus filtering, even though the Notifications pane lists them under "alerter". The two panels disagree; this is the #1 trap.
3. **Focus → Sleep** and **Focus → Do Not Disturb** → make sure **Terminal is *not*** in their allowed lists.

Side effect of step 2: anything else Terminal posts will also break through Work. Usually negligible.

### Sound — needs the Focus-detector Shortcut

`afplay` is raw audio, not a notification, so Focus can never mute it. cc-notifier detects the active Focus itself and skips the sound in muted modes. The detector is a Shortcut, and **it must be built exactly like this** (a bare "Get Current Focus" produces *no* CLI output):

1. Shortcuts.app → ＋ new shortcut → name it exactly **`CurrentFocus`**.
2. Add action **Get Current Focus**.
3. Add action **Stop and Output** → set its output to the **Current Focus** magic variable. **This step is required** — without "Stop and Output", `shortcuts run` returns nothing and detection silently degrades to always-play.
4. Verify (turn any Focus on first):
   ```bash
   shortcuts run CurrentFocus --output-path /tmp/focus.txt && cat /tmp/focus.txt
   ```
   It should print the focus name (e.g. `Work`). No trailing newline — zsh shows a `%` after it; that's cosmetic. Note `--output-path` writes to a **file**; `-` is *not* stdout. The first run may pop a one-time automation permission prompt — allow it.
5. The sound is muted while the detected Focus matches **`CC_MUTE_FOCUS`** in `~/.cc-notifier/config` (default `sleep donotdisturb.mode.default`, matched case-insensitively; "Do Not Disturb" is also caught by name).

**Self-test** per mode:
```bash
source ~/.cc-notifier/cc_focus.sh; CC_FOCUS_DEBUG=1 cc_should_play; echo play=$?
#   Work / no Focus -> play=0 (sounds)     Sleep / DND -> play=1 (muted)
~/.cc-notifier/cc_tunnel_test.sh beep     # chime in Work/none, silent in Sleep/DND
~/.cc-notifier/cc_tunnel_test.sh alarm    # in Work: loop + banner with Stop button
```

Caveats:
- Detection **fails safe to PLAY** when it can't tell (no Shortcut, empty output) — a miss leaks a sound rather than swallowing an alarm. So if sounds ignore your Focus, the Shortcut is misbuilt — recheck step 3.
- Expect ~1–2s of extra latency before the sound (the `shortcuts` call runs first).
- If your Sleep mode's identifier differs, add its substring to `CC_MUTE_FOCUS`.
- The `~/Library/DoNotDisturb/DB/Assertions.json` fallback is TCC-blocked on Tahoe (permission denied even in Terminal) and misses scheduled focuses — don't rely on it; build the Shortcut.
- Don't trust detection? Set **`CC_SOUND_VIA_ALERTER=1`**: the sound rides the notification and the Focus allow-list gates it for free — but you lose the looping alarm.

## Troubleshooting

**First run `~/.cc-notifier/cc_doctor.sh`** — it checks every link (listener, tunnel, auth, IPv4/IPv6, alerter, Karabiner, Telegram) and prints the specific fix. Common cases:

- **No beep, `cc_tunnel_test.sh ping` fails with exit 56** — the reverse tunnel is stale. From your Mac: `ssh -O cancel -R 28765:localhost:28765 <host>; ssh -O forward -R 28765:localhost:28765 <host>`.
- **Sound plays but no visual alert** — grant `alerter` notification permission (Alerts style) and allow it in your Focus modes.
- **Stop hotkey only works when a window is focused** — the combo is already taken (e.g. ⌃⌥Space = input-source switch). Pick a free one; `~/.cc-notifier/cc_check_hotkeys.py <key>` lists system shortcuts.

## Uninstall

```bash
bash install.sh --uninstall     # removes hooks + launchd; leaves ~/.cc-notifier (rm -rf to finish)
```

## Security

The listener is loopback-only and never runs as root, but two things are worth knowing:

- **Shared remote hosts.** An ssh `RemoteForward` binds the port on the *remote's* loopback, which on a multi-user login node is reachable by **every user on that host** — so another user could trigger or silence your alarms. Enable a shared token to stop that:
  ```bash
  ~/.cc-notifier/cc_token.sh new            # on your Mac — prints a value
  ~/.cc-notifier/cc_token.sh set <value>    # on each remote — same value
  ```
  With a token set, the action endpoints require a matching `X-CC-Token` header (`/ping` stays open). The listener re-reads the token per request, so enabling/disabling it needs no restart.
- **Browser requests.** The listener rejects any request carrying a non-local `Origin` header, blocking CSRF / DNS-rebinding from web pages.
- **Telegram token** lives in `~/.cc-notifier/config` (it's `chmod 600`) and rides the Telegram API URL — fine on a single-user Mac.

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
