# cc-notifier

Get a sound + desktop notification on your Mac when **Claude Code** or **Codex** finishes a round of work — or when it stops to ask you a question — with one sentence saying what the round did. Works whether the agent runs **locally on your Mac** or **on a remote machine** (HPC login node, dev box, container) over an SSH reverse tunnel.

No polling, no daemons you babysit: it rides the agents' hooks and a tiny launchd listener. Anything else (a script, another agent) can send the same notification with one command.

## What you get

- **Round complete** → a short chime (or, when *armed*, a 15s×3 alarm with a Stop button for when you've walked away).
- **Claude needs your input** (the `AskUserQuestion` multiple-choice prompt) → a distinct sound + a persistent alert.
- **The alert says who, which session and what happened**: the agent (Claude Code, Codex), the session title, a one-sentence summary (the sentence the final message opens with, or the question asked), and the host/project. The optional phone push carries the title and the whole final message, whatever its length.
- **Sessions are independent**: each session decides from its own turns and background tasks, raises its own alarm, and only a prompt you type in that session cancels it. See [Several sessions at once](#several-sessions-at-once).
- **Arm/disarm**, a global **stop hotkey**, and a **health check** that warns you at session start if the tunnel is down.

## How it works

```
[ machine running Claude Code / Codex ]               [ your Mac ]
  Stop / AskUserQuestion / ...  hooks
        │  curl localhost:28765/<beep|alarm|ask|stop>
        ▼
   (local: direct)  ───────────────────────────────►  launchd listener
   (remote: ssh -R 28765 reverse tunnel) ───────────►  (127.0.0.1 + ::1)
                                                          │
                                              afplay + alerter (sound + alert)
```

The hooks are **identical** for local and remote use. The only difference: a remote machine reaches your Mac's listener through an SSH `RemoteForward`; a local Mac hits it directly.

## Requirements

- **Receiver (your Mac):** macOS, [Homebrew](https://brew.sh), and [`alerter`](https://github.com/vjeantet/alerter) (the installer runs `brew install vjeantet/tap/alerter`). `alerter` provides the Stop button; on macOS Tahoe 26 `terminal-notifier` no longer can.
- **Sender (any machine where Claude Code or Codex runs):** `bash`, `curl`, `python3`.
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

1. **System Settings → Notifications → Terminal** → Allow, style **Alerts**. (alerter posts under Terminal's identity — it has no entry of its own; see the Focus section.)
2. **System Settings → Focus → Work** → Allowed Notifications → add **Terminal** (so notifications pierce that Focus; keep it out of Sleep/DND).
3. **Stop hotkey** (works even in the Claude Code chat box): the installer stages a **Karabiner-Elements** rule — enable it in *Karabiner → Complex Modifications → Add rule → "cc-notifier: Ctrl+Opt+Z → stop"*. Karabiner intercepts the key at the device level, so it fires even when the CC input (a webview) has focus. Without Karabiner, a macOS Shortcut running `~/.cc-notifier/cc_stop.sh` works everywhere **except** the CC input box.
4. Pick sounds: `~/.cc-notifier/cc_preview_sounds.sh loop`.

### 2. On a remote machine (where the agent runs)

```bash
bash install.sh          # auto-detects Linux → sender role
```

Then add **one line** to your Mac's `~/.ssh/config`, under the host you use for that machine:

```
RemoteForward 28765 localhost:28765
```

Reconnect (or `ssh -O forward -R 28765:localhost:28765 <host>`), and make sure the receiver is installed on your Mac. Restart the Claude Code session so the hooks load. For Codex on that machine, see [Codex](#codex).

## Usage

```bash
~/.cc-notifier/cc_notify_arm.sh on      # armed: long alarm at round end (you're away)
~/.cc-notifier/cc_notify_arm.sh off     # disarmed: short chime (you're at the desk)
~/.cc-notifier/cc_notify_arm.sh status

~/.cc-notifier/cc_tunnel_test.sh ping   # is the path healthy?
~/.cc-notifier/cc_tunnel_test.sh beep   # fire each notification type to test
~/.cc-notifier/cc_tunnel_test.sh alarm  # alarm/ask carry a sample title + summary
~/.cc-notifier/cc_tunnel_test.sh ask
~/.cc-notifier/cc_tunnel_test.sh stop   # silence every alarm

~/.cc-notifier/cc_doctor.sh             # full health check: listener, tunnel, auth, perms, hotkey, Telegram
```

The arm flag lives at `~/.cc-notifier/armed` and persists across reboots; it applies to every session on that machine.

### Notify from a script or any other agent

The hooks cover Claude Code and Codex. Anything else can send the same
notification explicitly:

```bash
~/.cc-notifier/cc_notify.sh --title "Nightly sweep" \
  --session nightly-sweep \
  --message "All 40 pairs finished; 2 failed."
```

The message is the one-sentence summary shown in the alert and the phone push;
`--body TEXT` adds a longer text, line breaks kept, that only the phone push carries.
`cc_notify.sh` waits for the listener, prints its HTTP result, and exits with
status 1 when delivery fails (the Stop hook intentionally runs in the background
and always exits 0). It honors the armed flag, or accepts `--action alarm`,
`--action beep`, or `--action ask`. Alarm and ask display the title/message; beep
plays only the short chime. A successful response means the listener accepted the
request; macOS notification permissions and Focus still control what appears on
screen. Use a distinct `--session` for independent work; the default is
`CODEX_THREAD_ID` when set, otherwise `manual`. `--agent NAME` sets who the alert
is from; run from inside Codex or Claude Code it names that agent by itself.

This command uses the existing token and tunnel and bypasses proxies for
localhost. An agent whose hooks are wired already notifies at every round end,
so call it from the agent only for something the hooks do not cover.

## Hooks installed (user-level `~/.claude/settings.json`)

| Event | Matcher | Action |
|---|---|---|
| `Stop` | — | round complete → `/beep` (disarmed) or `/alarm` (armed), with the session title and a one-sentence summary; skips turns < 20s and stops that are only a pause on the session's own background work |
| `PreToolUse` | `AskUserQuestion` | CC needs your input → `/ask` (always), with the question as the summary |
| `UserPromptSubmit` | — | start this session's turn clock; a prompt you typed cancels this session's alarm |
| `SessionStart` | — | warn in-context if the listener is unreachable or older than the hooks |

Merged idempotently — re-running the installer never duplicates hooks or clobbers your existing ones.

### Codex

Codex reads hooks of the same shape from `~/.codex/hooks.json` and hands them the same kind of payload, so it uses the same scripts. Switch it on where Codex runs:

```bash
~/.cc-notifier/cc_codex_hooks.sh on       # or: bash install.sh --codex
~/.cc-notifier/cc_codex_hooks.sh status   # off removes them again
```

| Event | Command | Action |
|---|---|---|
| `Stop` | `notify_done.sh codex` | round complete, as above; the title is the Codex thread name |
| `UserPromptSubmit` | `notify_stop.sh codex` | start this thread's turn clock; your prompt cancels this thread's alarm |

The two entries are appended after whatever is in the file; nothing already there is moved or changed, and the previous file is kept as `hooks.json.bak-cc-notifier`. Two things stay yours: Codex runs a hook only after you have reviewed it there (it tells you when hooks need review), and hooks need `codex_hooks = true` under `[features]` in `~/.codex/config.toml`. The script changes neither.

Any other agent whose hooks pass a JSON payload with `session_id`, `prompt` and `last_assistant_message` on stdin can register the same two commands with its own name in place of `codex`.

## Several sessions at once

Each session (a Claude Code session, a Codex thread) keeps its own state in `~/.cc-notifier/sessions/<session-id>.json`, and every request to the Mac names its session. Nothing one session does changes what another one decides or shows.

**When a session's round end notifies.** Only that session's own events count:

- **Its own background work holds the notification, for a while.** If the session stops while a shell, subagent or workflow it started is still running, it is only paused and will wake up again, so it stays silent. The notification comes when it stops with nothing left in flight.
- **The hold has limits, so a session is never silent for hours.** If the pause lasts 5 minutes, you get the round's summary with "still waiting on N background tasks" (once per round; further pauses are reported when the session has been quiet for 30 minutes). A session that keeps working in the background reports a round end at least every 30 minutes. And a task that has been in flight for 30 minutes (a standing watcher, a wait for a queued job) no longer holds anything: round ends beside it notify at once. Set the two times with `CC_NOTIFY_PAUSE_SECONDS` and `CC_NOTIFY_QUIET_SECONDS`.
- **Open-ended watches do not hold it.** A task of type `monitor` (for example the "live updates for artifact …" watch a session keeps after publishing a page) never finishes, so a session holding one would never notify. Change the list with `CC_NOTIFY_STANDBY_IGNORE`.
- **Quick turns are skipped** (< 20 s), timed from the start of that session's own turn. Agents also submit "prompts" of their own (in Claude Code a finished background task or a subagent hand-back); when one arrives in the middle of a turn, the clock keeps running.
- **The wrap-up after background work always counts.** When a stop ends work that an earlier stop left paused, it is timed from the last prompt you typed, so the 5-second reply that follows a 20-minute background job still notifies.

**What cancels an alarm.** A prompt you type in a session cancels that session's alarm. Prompts in other sessions, and the ones an agent submits itself, cancel nothing. The stop hotkey and `cc_tunnel_test.sh stop` silence every alarm.

**On the Mac**, the listener keeps one alarm per session: a second session finishing adds its own alert instead of replacing the first.

**Why did (or didn't) it notify?** Every hook decision is one line in `~/.cc-notifier/hook.log` on the machine running the agent:

```
… done sent act=alarm http=200 curl_exit=0 session=6717398a agent=claude age=612s since=turn_start cwd=proj bg=0 crons=0 title=29c brief=88c
… done sent act=alarm http=200 curl_exit=0 session=01a10977 agent=codex age=493s since=turn_start cwd=paper bg=0 crons=0 title=30c brief=19c
… done silent reason=background_tasks session=f4903eb2 agent=claude cwd=proj bg=1 crons=0 bg_tasks=[shell/running:wait for the job] notice_in=300s
… done sent act=alarm http=200 curl_exit=0 session=f4903eb2 agent=claude paused=300s title=39c brief=96c
… done silent reason=quick_turn age=5s min=20s since=turn_start session=4c990e6c agent=claude cwd=proj bg=0 crons=0
… prompt cancel http=200 curl_exit=0 session=6717398a agent=claude kind=typed turn=started
… prompt keep session=f4903eb2 agent=claude kind=task-notification turn=running
```

Both ends must be current for all of this: a listener older than the hooks still shows the alarm, but an older one cuts a long message in the phone push or sends only its one-sentence summary, one older still titles every alarm Claude Code and sends no summary to the phone, and the oldest has one shared slot and no title or summary at all (`cc_doctor.sh` and the `SessionStart` check say which).

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

Sender-side env vars (on the machine running the agent):

| Var | Default | Meaning |
|---|---|---|
| `CC_NOTIFY_PORT` | `28765` | listener port (use `install.sh --port N` to set everywhere) |
| `CC_NOTIFY_MIN_SECONDS` | `20` | skip round-end notify for shorter turns (`0` = always) |
| `CC_NOTIFY_BRIEF_CHARS` | `240` | longest summary sent with a notification; a sentence over it is cut at a word (`0` = no summary) |
| `CC_NOTIFY_BODY_CHARS` | `40000` | a guard against runaway output: the phone push gets the final message up to this length (at most 60000; `0` = only the summary). No real message is this long |
| `CC_NOTIFY_STANDBY_IGNORE` | `monitor` | background-task types that do not hold a notification back (space-separated; empty = every task holds it) |
| `CC_NOTIFY_PAUSE_SECONDS` | `300` | a pause on background work that lasts this long is reported ("still waiting on …"); `0` = never, background work holds the notification until it is done |
| `CC_NOTIFY_QUIET_SECONDS` | `1800` | the longest background work can keep a session quiet: a task in flight this long no longer holds anything, and a session that has not notified for this long reports its next round end anyway; `0` = off |

Hooks inherit the environment of the agent's process, so set these where it starts (your shell profile, or `"env"` in `~/.claude/settings.json`).

## Phone push (Telegram, optional)

Get a Telegram message on your phone alongside the Mac alarm — free, and it uses the Telegram app you already have. It's **relayed from your Mac**, so the machine running the agent never talks to Telegram (which matters on networks that block it — e.g. some HPC sites sinkhole it). It fires for the long alarms (`done` armed, `ask`), and only while your Mac is on.

1. In Telegram, message **@BotFather** → `/newbot` → follow the prompts → copy the **bot token**.
2. Send your new bot any message (opens a chat it can reply in).
3. From your **Mac** (a network that can reach Telegram), open `https://api.telegram.org/bot<TOKEN>/getUpdates` and copy the `"chat":{"id": … }` number.
4. Add both to `~/.cc-notifier/config` on the Mac:
   ```sh
   CC_TELEGRAM_TOKEN=123456789:ABCdef...
   CC_TELEGRAM_CHAT_ID=123456789
   ```
5. Test: `~/.cc-notifier/cc_tunnel_test.sh alarm` → expect a Telegram push.

The push is the session title, then the whole final message as plain text (lists stay lists, a table becomes one short block per row), then a line with the agent, the status and `host/project`:

```
Nightly benchmark sweep
All 40 configurations finished; the 2 that failed are listed below.

What failed
• batch 512: out of memory after 3 minutes
• batch 1024: timed out at the 1 h limit

Claude Code: Round complete — login-node/my-project
```

Nothing is trimmed, and nothing is published anywhere: the text lives in the chat and nowhere else (set Telegram's auto-delete timer on the chat if you do not want it to pile up).

- **Long messages fold.** Above `CC_TELEGRAM_FOLD_CHARS` characters (1500; `0` = never) the push shows the opening and puts the rest in a quote that is collapsed until you tap it, so the chat stays short.
- **Very long messages continue.** One Telegram message holds 4,096 characters; a longer text goes out as several messages in order, marked `(2/3)`, `(3/3)`, each folded the same way.
- **If Telegram refuses the formatted text** it is sent again as plain text, and if nothing gets through, a short form (title and one-sentence summary) is sent instead. `~/.cc-notifier/telegram.log` on the Mac records what was sent (sizes and errors, never the text).
- **A question** (`ask`) carries its choices.

The whole message travels from the agent's machine as the body of a POST, which needs curl 7.87 or newer there; with an older curl the push gets the first 3,400 characters and says how much is left.

All of this is text from your session. Add `CC_TELEGRAM_BRIEF=0` to the config to keep it on the Mac; the push then carries the last line only.

## Focus modes (break through Work, stay quiet in Sleep / Do Not Disturb)

The **banner** and the **sound** are gated by different mechanisms — set up both. (These steps are verified on macOS Tahoe 26.)

### Banner — pure System Settings, no code

⚠️ **alerter never appears under its own name** in System Settings — its notifications are attributed to **Terminal** in both the Notifications pane and the Focus app picker. Configure **Terminal** everywhere. (If your build does show an "alerter" entry, configure that instead.)

1. **System Settings → Notifications → Terminal** → Allow Notifications ON, style **Alerts** (Alerts persist and show the Stop button; Banners don't).
2. **System Settings → Focus → Work → Allowed Notifications → Apps → ＋ add `Terminal`.**
3. **Focus → Sleep** and **Focus → Do Not Disturb** → make sure **Terminal is *not*** in their allowed lists.

Side effect: anything else Terminal posts will also break through Work. Usually negligible.

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

## Keeping the reverse tunnel alive (remote setups)

The reverse tunnel rides your SSH connection, so a network change, window reload, or sleep can drop it (and `ControlPersist` may reuse a stale master that lost the forward). To self-heal, set your ssh host alias in `~/.cc-notifier/config`:

```sh
CC_TUNNEL_HOST=aurora
```

A launchd keeper (`com.ccnotifier.tunnel`, installed on the Mac) then checks the tunnel **every 60s and immediately on a network change** (it watches `/etc/resolv.conf`) and re-injects the `RemoteForward` if it's down. It only ever acts on your **existing** SSH master (shared `ControlPath`), so it opens **no new connections** (nothing for an HPC admin to flag) and keeps the forward on the same node as your session. The `SessionStart` healthcheck still warns in-session if the tunnel is down.

## Troubleshooting

**First run `~/.cc-notifier/cc_doctor.sh`** — it checks every link (listener, tunnel, auth, IPv4/IPv6, alerter, Karabiner, Telegram) and prints the specific fix. Common cases:

- **No beep, `cc_tunnel_test.sh ping` fails with exit 56** — the reverse tunnel is stale. From your Mac: `ssh -O cancel -R 28765:localhost:28765 <host>; ssh -O forward -R 28765:localhost:28765 <host>`.
- **The path is healthy but one session stayed quiet** — read `~/.cc-notifier/hook.log` on the machine running the agent: it has the decision for every stop and the reason for each silent one (see [Several sessions at once](#several-sessions-at-once)).
- **No session title or summary in the alert or the phone push, only one sentence or a cut message in the phone push, or a Codex alarm titled Claude Code** — the Mac listener is older than the hooks; re-run `install.sh` on the Mac.
- **The alert shows but nothing reaches Telegram** — read `~/.cc-notifier/telegram.log` on the Mac; it has Telegram's own error for each failed send.
- **Codex rounds do not notify** — switch the hooks on (`cc_codex_hooks.sh on`), review them in Codex and check `codex_hooks = true` (see [Codex](#codex)); `cc_doctor.sh` says whether they are in `~/.codex/hooks.json`.
- **Sound plays but no visual alert** — grant **Terminal** notification permission (Alerts style) and allow **Terminal** in your Focus mode's apps (alerter posts under Terminal's identity).
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
src/sender/               hooks + arm/test scripts (run wherever the agent runs)
src/receiver/             listener, alarms, sound/hotkey helpers (run on the Mac)
src/install.template.sh   the installer framework
build.sh                  bundles src/ into the self-contained install.sh
tests/test_hook.py        checks for the per-session decisions and the summary (src/sender/cc_hook.py)
tests/test_notify.py      local HTTP checks for explicit completion delivery
tests/test_telegram.py    checks for how a message becomes Telegram messages (src/receiver/cc_telegram.py)
```

Edit a file under `src/`, run `python3 tests/test_hook.py`, `python3 tests/test_notify.py`, `python3 tests/test_telegram.py`, and `./build.sh`, then commit both the source change and the regenerated `install.sh`.

## License

MIT — see [LICENSE](LICENSE).
