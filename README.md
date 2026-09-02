# ClaudeSignaler

Tells you when a Claude Code session finished, needs you, or died — with a real
Windows toast carrying Claude's own icon, and a one-line summary of what it
actually said.

Built for Windows 11 + PowerShell. No dependencies, no accounts, no build step.

![event](https://img.shields.io/badge/hooks-Stop%20%7C%20Notification%20%7C%20StopFailure-blue)

## Why this exists

The first version fired on every single turn and shook the screen. It was
impossible to ignore and told you nothing, which is a bad combination. This one
inverts both halves:

- **It stays quiet by default.** A turn under 30 seconds is not an event.
  Neither is one that ended while you were looking at the window.
- **It tells you what happened.** The toast body is Claude's closing message,
  stripped of code fences and trimmed. You can decide whether to walk back
  without walking back.

## Install

```powershell
git clone https://github.com/unluckyjet/ClaudeSignaler.git
cd ClaudeSignaler
.\scripts\install.ps1
```

Then restart Claude Code, since hooks load at session start.

**Then tune the focus gate — this is a required step, not a nicety.** Click your
Claude Code window and run `.\scripts\install.ps1 -WhoHasFocus`. It prints the
foreground window title; set `focusPattern` in `config.json` to a regex that
matches it. The shipped default (`claude`) is a guess, because the right answer
depends on what your terminal puts in its title bar. Too broad and the gate
silently suppresses everything; too narrow and it never fires. Either way
`logs\signaler.log` records the reason for every skip, so check there first if
the behaviour surprises you.

```powershell
.\scripts\install.ps1 -Test         # fire all four signals now
.\scripts\install.ps1 -Status       # what is registered
.\scripts\install.ps1 -WhoHasFocus  # tune the focus gate
.\scripts\install.ps1 -Uninstall    # remove, leaving other hooks alone
```

`settings.json` is backed up to `~/.claude/backups/` before every write, and only
hook entries pointing into this repo are ever touched.

## The four signals

| Signal | Fires on | Default |
|---|---|---|
| `done` | `Stop` — Claude finished a turn | Toast, but only if the turn ran ≥30s |
| `needsInput` | `Notification` — permission prompt, agent question | Toast, always. You are the bottleneck |
| `idle` | `Notification/idle_prompt` — ~60s after Stop, still no you | Toast **+ phone push** |
| `failed` | `StopFailure` — turn died on an API error | Toast with an alarm sound |

The escalation is the point. A finished turn is a soft nudge. Sixty seconds of
you not reacting means you left the room, and that is the one worth sending to
your phone.

Two events are deliberately left unwired. `Notification/agent_completed` would
duplicate `Stop` on the same turn, and unlike `Stop` it does not carry
`last_assistant_message`, so it can only produce a worse, contentless toast.
`SubagentStop` fires many times inside a single turn and would bury the signal
that matters.

## Gates

Every gate exists to make the signal mean something. In the order they run:

1. **`enabled`** — per event, in `config.json`.
2. **`minTurnSeconds`** — silence for short turns. The best single filter.
   Requires the `UserPromptSubmit` hook, which stamps when the turn began.
3. **Focus** — if the foreground window title matches `focusPattern`, say
   nothing. Run `-WhoHasFocus` to see the live title and write a regex for it.
4. **Cooldown** — swallow a second signal within `cooldownMs`, so overlapping
   events do not stack.

Every skip is logged with its reason in `logs/signaler.log`, so when it is quiet
you can find out why.

## Phone push

Off by default. To turn it on, set in `config.json`:

```json
"push": { "enabled": true, "server": "https://ntfy.sh", "ntfyTopic": "claude-<something-random>" }
```

Install the [ntfy](https://ntfy.sh) app and subscribe to that exact topic. No
account, no API key.

> **ntfy.sh topics are readable by anyone who guesses the name**, and the body
> contains Claude's closing message. Use a long random topic, or self-host and
> change `server`.

## Speech

Also off by default. Set `"speak": true` on any event and Windows reads a short
headline aloud through the built-in voice — no API key, no network. Speaking
blocks for several seconds, so it is handed to a detached window-less process
and the turn is never held up.

## Performance

Hooks are synchronous: Claude Code waits for them. Measured on this machine
(Windows 11, PowerShell 5.1, median of 11 runs):

| | |
|---|---|
| `powershell.exe` startup, doing nothing | ~320 ms |
| `turn-start.ps1` (every prompt you submit) | ~0.7–0.9 s |
| `signal.ps1` (every turn end) | ~1.0–1.4 s |

Nearly all of it is interpreter startup and assembly loading, not this code —
script parsing measures at only ~85 ms. Two things follow:

- `turn-start.ps1` is a deliberately tiny separate file rather than a mode of
  `signal.ps1`, because it runs on the latency-sensitive path.
- **Installing PowerShell 7 is the single biggest win available.** `install.ps1`
  automatically prefers `pwsh.exe` when it is on PATH, so installing it and
  re-running the installer is the whole upgrade.

If the added latency bothers you more than the missed notifications, set
`minTurnSeconds` to `0` and delete the `UserPromptSubmit` hook — you lose the
duration gate and get half the overhead back.

## Config

Everything lives in `config.json`, which is commented via `_`-prefixed keys and
is read fresh on every signal — edit it and the next notification uses it. No
reinstall, no restart.

## How the toast gets Claude's icon

It borrows Claude Desktop's registered app id
(`Claude_pzs8sxrjxfjjc!Claude`) as the toast's AUMID, so Windows attributes the
notification to Claude rather than to PowerShell. Native WinRT, no BurntToast
dependency. If Claude Desktop is not installed the toast is skipped and a system
sound plays instead.

Anthropic [declined to ship this natively](https://github.com/anthropics/claude-code/issues/67220)
(issue closed as not planned), so it lives here.

## Layout

```
hooks/signal.ps1       the whole decision + notification path
hooks/turn-start.ps1   stamps turn start; tiny on purpose
scripts/install.ps1    register / uninstall / status / test
config.json            every knob
```

## License

MIT
