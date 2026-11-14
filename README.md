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
        │  signed request to localhost:28765/<beep|alarm|ask|stop>
        ▼
   (local: direct)  ───────────────────────────────►  launchd listener
   (remote: ssh -R 28765 reverse tunnel) ───────────►  (127.0.0.1 + ::1)
                                                          │
                                              afplay + alerter (sound + alert)
```

The hooks are **identical** for local and remote use. The only difference: a remote machine reaches your Mac's listener through an SSH `RemoteForward`; a local Mac hits it directly. Every request is signed with a key of that machine's own, which the Mac's listener also holds; the key itself never travels (see [Security](#security)).

## Requirements

- **Receiver (your Mac):** macOS, [Homebrew](https://brew.sh), and [`alerter`](https://github.com/vjeantet/alerter) (the installer runs `brew install vjeantet/tap/alerter`). `alerter` provides the Stop button; on macOS Tahoe 26 `terminal-notifier` no longer can.
- **Sender (any machine where Claude Code or Codex runs):** `bash`, `python3` (3.6 or newer), and `curl` for the Mac's tunnel check.
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

Make sure the receiver is installed on your Mac, connect to the remote, and give it a key and a port of its own, from the Mac (the key goes over ssh, on standard input, never on a command line):

```bash
~/.cc-notifier/cc_token.sh push <host>      # <host>: your ssh alias for it, in lowercase
```

It prints the **one line** to put under that host in your Mac's `~/.ssh/config`, with the Mac port this remote's tunnel ends at (28766 for the first remote, 28767 for the next, ...); if you are connected through a shared ssh master, it also moves the live tunnel there for you:

```
RemoteForward 28765 localhost:28766
```

**More than one remote** (say Aurora and Polaris): `cc_token.sh push aurora polaris`, the printed line under each host, and both in `CC_TUNNEL_HOST` for the [tunnel keeper](#keeping-the-reverse-tunnel-alive-remote-setups). Each machine gets its own key and its own Mac port: a key is taken, and proven, only on its own machine's port, so you can replace or revoke one without touching the others, a connection relayed through another machine's tunnel gets nothing, and the banner and the Mac's log say which machine sent each request.

Restart the Claude Code session so the hooks load. For Codex on that machine, see [Codex](#codex).

## Usage

```bash
~/.cc-notifier/cc_notify_arm.sh on      # armed: long alarm at round end (you're away)
~/.cc-notifier/cc_notify_arm.sh off     # disarmed: short chime (you're at the desk)
~/.cc-notifier/cc_notify_arm.sh status

~/.cc-notifier/cc_tunnel_test.sh ping   # is the path healthy? (the listener proves it holds this machine's key; nothing rings)
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
`--body TEXT` adds a longer text, line breaks kept, that only the phone push carries,
and `--body-file FILE` (`-` for standard input) reads it from a file. On a shared host,
prefer the file: other users can read a command's arguments while it runs.
`cc_notify.sh` waits for the listener, prints its HTTP result, and exits with
status 1 when delivery fails (the Stop hook intentionally runs in the background
and always exits 0). It honors the armed flag, or accepts `--action alarm`,
`--action beep`, or `--action ask`. Alarm and ask display the title/message; beep
plays only the short chime. A successful response means the listener accepted the
request; macOS notification permissions and Focus still control what appears on
screen. Use a distinct `--session` for independent work; the default is
`CODEX_THREAD_ID` when set, otherwise `manual`. `--agent NAME` sets who the alert
is from; run from inside Codex or Claude Code it names that agent by itself.

This command uses the machine's key and tunnel (the request is signed like the
hooks' requests) and bypasses proxies for localhost. An agent whose hooks are wired already notifies at every round end,
so call it from the agent only for something the hooks do not cover.

## Hooks installed (user-level `~/.claude/settings.json`)

| Event | Matcher | Action |
|---|---|---|
| `Stop` | — | round complete → `/beep` (disarmed) or `/alarm` (armed), with the session title and a one-sentence summary; skips turns < 20s and stops that are only a pause on the session's own background work |
| `PreToolUse` | `AskUserQuestion` | CC needs your input → `/ask` (always), with the question as the summary |
| `UserPromptSubmit` | — | start this session's turn clock; a prompt you typed cancels this session's alarm |
| `SessionStart` | — | warn in-context if the listener is unreachable, cannot prove it holds this machine's key, has no key for it, or is older than the hooks |

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
… done sent act=alarm http=200 err=ok auth=signed session=6717398a agent=claude age=612s since=turn_start cwd=proj bg=0 crons=0 title=29c brief=88c
… done sent act=alarm http=200 err=ok auth=signed session=01a10977 agent=codex age=493s since=turn_start cwd=paper bg=0 crons=0 title=30c brief=19c
… done silent reason=background_tasks session=f4903eb2 agent=claude cwd=proj bg=1 crons=0 bg_tasks=[shell/running:wait for the job] notice_in=300s
… done sent act=alarm http=200 err=ok auth=signed session=f4903eb2 agent=claude paused=300s title=39c brief=96c
… done silent reason=quick_turn age=5s min=20s since=turn_start session=4c990e6c agent=claude cwd=proj bg=0 crons=0
… done sent act=alarm http=000 err=unverified auth=- session=77b0c2aa agent=claude age=95s since=turn_start cwd=proj bg=0 crons=0 title=24c brief=61c
… prompt cancel http=200 err=ok auth=signed session=6717398a agent=claude kind=typed turn=started
… prompt keep session=f4903eb2 agent=claude kind=task-notification turn=running
```

`err=` says what kept a request from going out: `unreachable` (no tunnel), `unverified` (something answers on the port but cannot prove it holds this machine's key: the keys differ, or someone else holds the port), `no_token` (no key on this machine), `key_unknown_at_listener` (the Mac has no key under this machine's name: never issued, or revoked), `no_key_for_this_machine` (this machine still has the shared key, which the Mac has retired, or its tunnel ends at a remote's port), `old_listener_proto<N>` (the Mac needs the current installer); `http=429` means this machine sent more than its rate allows (a burst of 20, then one every 3 s). The listener's answers that lead to these can be imitated by whoever holds the port when the tunnel is down, so the messages say so. `auth=signed` is a request signed with the machine's own key; `auth=shared` one signed with the key all machines shared before protocol 7, which works on the Mac's own port until `cc_token.sh revoke shared`; `auth=legacy` appears only on a machine upgraded from protocol 5 while its Mac still runs that version (see [Security](#security)).

Both ends must be current: these hooks send only signed requests (protocol 6), which a listener older than that cannot check, so it gets nothing (`cc_doctor.sh` and the `SessionStart` check say so). The one exception is the move from protocol 5, described under [Security](#security).

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

The whole message travels from the agent's machine as the body of a signed POST.

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

The reverse tunnel rides your SSH connection, so a network change, window reload, or sleep can drop it (and `ControlPersist` may reuse a stale master that lost the forward). To self-heal, set your ssh host alias in `~/.cc-notifier/config`, or several, separated by spaces:

```sh
CC_TUNNEL_HOST="aurora polaris"
```

A launchd keeper (`com.ccnotifier.tunnel`, installed on the Mac) then checks the tunnel **every 60s and immediately on a network change** (it watches `/etc/resolv.conf`) and checks each host's tunnel with a proof only your own listener can give, made with that host's key on that host's port. It changes a forward only when that is clearly right: nothing listens at the far end (it puts the forward back), or the tunnel leads to your Mac but to the wrong port (it points it at the right one). A busy port, or someone else holding it, is left alone and logged in `~/.cc-notifier/tunnel.log`: cancelling there would hand the port to whoever grabs it first. If this Mac's own key does not work, it changes nothing and says to run `cc_token.sh new`. It only ever acts on your **existing** SSH master (shared `ControlPath`), so it opens **no new connections** (nothing for an HPC admin to flag) and keeps the forward on the same node as your session. The `SessionStart` healthcheck still warns in-session if the tunnel is down.

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

The listener is loopback-only and never runs as root. What a shared remote host means for it, and what protects you:

- **Anyone on a shared login node can reach the port.** An ssh `RemoteForward` binds the port on the *remote's* loopback, so every user of that host can send to it. **Every request is therefore signed** with the sending machine's own key: the Mac keeps one per machine (`~/.cc-notifier/keys/<name>`, the name being the ssh alias it was issued to), each machine keeps its own (`~/.cc-notifier/token`, and its name in `key-name`). The signature is an HMAC-SHA256 over the key's name, the method, path, query, body, time and a one-time nonce. The listener carries out a request only when the signature is right for the key the request names, the time is within 5 minutes, and the nonce is new, so a copied request can be neither changed, nor sent again, nor passed off as another machine's. Without a key the listener refuses everything; every request it carries out or refuses is one line in its log (`~/.cc-notifier/listener.log`, readable by you only), with the machine's name; untrusted text is cleaned, and refused requests are logged at most one a second.
- **One port per remote, so a relay gets nothing.** If a remote's tunnel is down, a user on that login node could otherwise pass its connections on through *another* machine's live tunnel into your Mac, and the Mac would prove itself. So each remote's tunnel ends at a Mac port of its own (`ports/<name>`), and its key is taken, and proven, only there; this Mac's own key (`local`) and the shared key only on 28765. Each port has its own connection limit, so a flood on one tunnel does not silence the others.
- **Each machine's alarms are its own.** The banner shows the machine whose key signed the request (not the label the sender chose); a session's alarm can be replaced or stopped only by the same machine; a remote's `/stop` reaches only its own alarms (the Mac's stop hotkey reaches all); and each key has a rate limit (a burst of 20, then one every 3 s), so a leaked key cannot flood the alarm or the phone.
- **A key never travels.** It is a key, not a password: no request carries it, so whoever sees the traffic cannot reuse it. That matters on a shared host: when the tunnel is down, any user there can listen on the port. So before sending anything a sender asks the listener for a proof (`/ping?c=<random>&k=<name>` must come back with an HMAC of the challenge under that machine's key), and a listener that cannot give one gets nothing, neither the request nor the message. The Mac's tunnel keeper checks the same kind of proof, so it notices when the port on a remote is not leading to your Mac.
- **Slow or idle connections are cut off.** A connection has 5 seconds for its whole request, and at most 32 are handled at once on each port, so a few connections that send nothing cannot tie the listener up. Anyone on a login node can still flood that remote's tunnel, though, and that also loads your ssh connection: the request checks keep the alarms honest, not always on time.
- **Nothing secret goes on a command line.** Other users of a shared host can read every process's arguments. The token, the Telegram bot token and the message texts reach `curl` and the client through standard input, files or the environment (which only you can read), never as arguments.
- **One key per machine.** The Mac issues them, and they go over ssh, on standard input:
  ```bash
  ~/.cc-notifier/cc_token.sh push <host>...     # give each remote its own key and port (made if it has none)
  ~/.cc-notifier/cc_token.sh rotate <host>...   # a new key for those hosts; the others are not touched
  ~/.cc-notifier/cc_token.sh revoke <host>...   # forget a host's key: it can no longer send
  ~/.cc-notifier/cc_token.sh keys               # the machines that have a key
  ```
  A key is first staged on the host, then both ends switch. If sending it fails, nothing changes for that host; if the host then fails to switch, it cannot send until you `push` it again, and the tool says so. `push` and `rotate` refuse unless the Mac's listener and the host's sender both speak protocol 7, and refuse a host whose kit already holds another host's key (one home under two names). Names are lowercase (macOS file names ignore case). `cc_token.sh set <name>` on a remote reads a key from standard input, refuses one given as an argument, and refuses a name that looks like a key.
- **Moving from one shared token.** Before protocol 7 every machine shared one token. The Mac's installer keeps it as `keys/shared`, taken on the Mac's own port only, so those machines keep working (`auth=shared`) while you give each one a key of its own; once all have theirs, `cc_token.sh revoke shared` retires it. Until then the machines on it are one identity to the listener: one of them can stop or replace the others' alarms and use up their common rate.
- **What remains.** Anyone on a login node can flood that remote's tunnel (the alarms stay honest, but may be late or lost), and a sender pings and then sends on a second connection, so if the tunnel dropped in that instant and someone took the port, the message (not the key) would reach them.
- **Private files.** The installer keeps `~/.cc-notifier` readable by you only: the token, the config (with the Telegram bot token) and the message texts on their way to the phone. `cc_doctor.sh` flags anything that is not.
- **Browser requests.** The listener rejects any request whose `Origin` or `Host` is not a local address, blocking CSRF and DNS rebinding from web pages.
- **Moving from protocol 5.** The previous version sent the token itself in a header. A remote upgraded from it keeps `legacy-token.sha256`, the hash of the token it had; while the Mac still runs protocol 5, and for at most 72 hours, that remote keeps serving it the old way, with that same token only (never on a command line). Once the Mac's listener has proved itself the file is deleted and the token never leaves the remote again; a new token never matches the file. So: update the Mac (re-run `install.sh` there), then `cc_token.sh rotate <each remote>`.

## Development

`install.sh` is **generated** — don't edit it directly. The real sources live in `src/`:

```
src/sender/               hooks + arm/test scripts (run wherever the agent runs)
src/receiver/             listener, alarms, sound/hotkey helpers (run on the Mac)
src/install.template.sh   the installer framework
build.sh                  bundles src/ into the self-contained install.sh
tests/test_hook.py        checks for the per-session decisions and the summary (src/sender/cc_hook.py)
tests/test_notify.py      cc_notify.sh against the real listener on a spare port
tests/test_telegram.py    checks for how a message becomes Telegram messages (src/receiver/cc_telegram.py)
tests/test_security.py    signatures, replays, proofs, someone else on the port, command lines on both ends, the installer
tests/_harness.py         the fixtures they share (nothing reaches your real Mac or kit)
```

Edit a file under `src/`, run `python3 tests/test_hook.py`, `python3 tests/test_notify.py`, `python3 tests/test_telegram.py`, `python3 tests/test_security.py`, and `./build.sh`, then commit both the source change and the regenerated `install.sh`. `CC_TEST_BASH=/path/to/bash-3.2` runs the shell scripts in the tests with the shell macOS uses.

## License

MIT — see [LICENSE](LICENSE).
