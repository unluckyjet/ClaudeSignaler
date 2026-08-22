#!/usr/bin/env node
/**
 * Registers (or removes) the signaler hooks in ~/.claude/settings.json.
 *
 * Idempotent and additive: the file is backed up first, existing hook entries
 * are left alone, and this tool's own entries are recognised by the absolute
 * path in their `args` so re-running replaces rather than duplicates them.
 *
 *   node scripts/install.js              install / refresh
 *   node scripts/install.js --uninstall  remove
 *   node scripts/install.js --status     show what is registered
 *   node scripts/install.js --test [k]   fire a cue now (done|needsInput|failed)
 */

import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import { ROOT } from "./lib/config.js";

const SETTINGS_PATH = join(homedir(), ".claude", "settings.json");
const BACKUP_DIR = join(homedir(), ".claude", "backups");

/** Forward slashes throughout: valid on Windows and safe to embed in JSON. */
const HOOK_ENTRY = join(ROOT, "hooks", "signaler.js").replace(/\\/g, "/");
const SIGNAL_SCRIPT = join(ROOT, "scripts", "signal.ps1");

/**
 * matcher values per https://code.claude.com/docs/en/hooks
 *
 * `Notification` deliberately omits `idle_prompt`: it fires ~60s after Stop
 * already sounded for the same idle turn.
 */
const REGISTRATIONS = [
  { event: "Stop", matcher: "*", signal: "done", note: "Claude finished its turn" },
  {
    event: "Notification",
    matcher: "permission_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog",
    signal: "needsInput",
    note: "Claude is waiting on you",
  },
  { event: "StopFailure", matcher: "*", signal: "failed", note: "turn died on an API error" },
];

/**
 * The matcher already identifies the event, so the signal is passed as an arg
 * and the hook never has to read stdin.
 *
 * Deliberately not `async: true`. The hook exits in ~150ms, so blocking the turn
 * is imperceptible, and async is the one flag likely to change how Claude Code
 * manages the hook's process tree - which the detached PowerShell grandchild
 * depends on surviving.
 */
function buildHook(event, signal) {
  return {
    type: "command",
    command: "node",
    args: [HOOK_ENTRY, "--signal", signal, "--reason", event],
    timeout: 10,
  };
}

function isOurs(hook) {
  return Array.isArray(hook?.args) && hook.args.some((arg) => arg === HOOK_ENTRY);
}

function readSettings() {
  if (!existsSync(SETTINGS_PATH)) return {};
  try {
    return JSON.parse(readFileSync(SETTINGS_PATH, "utf8"));
  } catch (error) {
    throw new Error(
      `~/.claude/settings.json is not valid JSON, refusing to touch it: ${error.message}`,
    );
  }
}

function backupSettings() {
  if (!existsSync(SETTINGS_PATH)) return null;
  mkdirSync(BACKUP_DIR, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const target = join(BACKUP_DIR, `settings.json.${stamp}.signaler.bak`);
  copyFileSync(SETTINGS_PATH, target);
  return target;
}

/** Drops every matcher group whose hooks are all ours, and prunes ours from mixed groups. */
function stripOurHooks(settings) {
  let removed = 0;
  const hooks = settings.hooks ?? {};

  for (const [event, groups] of Object.entries(hooks)) {
    if (!Array.isArray(groups)) continue;

    const kept = [];
    for (const group of groups) {
      const inner = Array.isArray(group?.hooks) ? group.hooks : [];
      const survivors = inner.filter((hook) => !isOurs(hook));
      removed += inner.length - survivors.length;
      if (survivors.length > 0) kept.push({ ...group, hooks: survivors });
    }

    if (kept.length > 0) hooks[event] = kept;
    else delete hooks[event];
  }

  if (Object.keys(hooks).length > 0) settings.hooks = hooks;
  else delete settings.hooks;

  return removed;
}

function writeSettings(settings) {
  writeFileSync(SETTINGS_PATH, `${JSON.stringify(settings, null, 2)}\n`, "utf8");
}

function install() {
  const settings = readSettings();
  const backup = backupSettings();

  stripOurHooks(settings);
  settings.hooks = settings.hooks ?? {};

  for (const { event, matcher, signal } of REGISTRATIONS) {
    settings.hooks[event] = settings.hooks[event] ?? [];
    settings.hooks[event].push({ matcher, hooks: [buildHook(event, signal)] });
  }

  writeSettings(settings);
  prewarm();

  console.log("ClaudeSignaler installed.\n");
  console.log(`  settings : ${SETTINGS_PATH}`);
  if (backup) console.log(`  backup   : ${backup}`);
  console.log(`  hook     : node ${HOOK_ENTRY}\n`);
  for (const { event, matcher, note } of REGISTRATIONS) {
    console.log(`  ${event.padEnd(13)} ${note}`);
    console.log(`  ${" ".repeat(13)} matcher: ${matcher}`);
  }
  console.log("\nOther hooks in settings.json were left untouched.");
  console.log("Restart Claude Code (or start a new session) to pick up the hooks.");
}

/** Builds the foreground-detection DLL now, so no real signal pays the ~512ms compile. */
function prewarm() {
  spawnSync(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", SIGNAL_SCRIPT, "-Prewarm"],
    { stdio: "ignore", windowsHide: true },
  );
}

function uninstall() {
  const settings = readSettings();
  const backup = backupSettings();
  const removed = stripOurHooks(settings);
  writeSettings(settings);

  console.log(`ClaudeSignaler removed: ${removed} hook entr${removed === 1 ? "y" : "ies"}.`);
  if (backup) console.log(`  backup: ${backup}`);
}

function status() {
  const settings = readSettings();
  const found = [];

  for (const [event, groups] of Object.entries(settings.hooks ?? {})) {
    if (!Array.isArray(groups)) continue;
    for (const group of groups) {
      for (const hook of group?.hooks ?? []) {
        if (isOurs(hook)) found.push(`${event} (matcher: ${group.matcher ?? "*"})`);
      }
    }
  }

  console.log(`settings : ${SETTINGS_PATH}`);
  console.log(`hook     : ${HOOK_ENTRY}`);
  console.log(`installed: ${found.length > 0 ? "yes" : "no"}`);
  for (const entry of found) console.log(`  - ${entry}`);
}

function test(kind = "done") {
  console.log(`Playing the "${kind}" cue. Pausing any playing media first...`);
  const result = spawnSync(
    "powershell.exe",
    [
      "-NoProfile",
      "-NonInteractive",
      "-Sta",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      SIGNAL_SCRIPT,
      "-Signal",
      kind,
      "-Reason",
      "install --test",
      "-NoCooldown",
    ],
    { stdio: "inherit", windowsHide: true },
  );
  console.log(`Done (exit ${result.status}). See logs/signaler.log for what happened.`);
}

function help() {
  console.log(`claude-signaler - know when Claude Code is done without watching it.

Pauses whatever is playing, plays a cue so you actually hear it, shakes the whole
screen for a second, then resumes your music. Windows only.

SETUP
  npm install                       node-web-audio-api + cuelume
  npm run render                    synthesize the 17 cues to sounds/*.wav
  npm run install-hooks             register in ~/.claude/settings.json
                                    then restart Claude Code

COMMANDS
  node scripts/install.js           install or refresh the hooks
  node scripts/install.js --status  show what is registered
  node scripts/install.js --test [done|needsInput|failed]
  node scripts/install.js --uninstall
  node scripts/install.js --help

WHAT FIRES
  Stop          -> "done"        Claude finished, waiting on you
  Notification  -> "needsInput"  permission prompt, agent asking, MCP elicitation
  StopFailure   -> "failed"      turn died on an API error

  Installing only ever appends its own matcher groups; your other hooks are left
  alone, and ~/.claude/settings.json is backed up to ~/.claude/backups/ first.

CONFIG
  config.json, read fresh on every signal. Every key has a "_name" sibling
  explaining it. The ones you probably want:

    events.done.cue        which of the 17 cues to play
    audio.volume           0-1 peak loudness (re-renders itself on next signal)
    shake.enabled          false to keep the sound and lose the screen shake
    shake.amplitude        peak offset in px
    whenFocused.mode       what to do when you are already looking at Claude Code:
                           full | quiet (sound, no shake) | silent (nothing)
    media.mode             "none" to play over your music instead of pausing it

TROUBLESHOOTING
  logs/signaler.log records every signal, what was paused, and the timing.
  An empty log means the hook never fired - check --status, and that you
  restarted Claude Code after installing.

  Cues are synthesized from cuelume (https://cuelume.dev, MIT), which ships no
  audio files. See scripts/render-sounds.js.`);
}

const argv = process.argv.slice(2);
try {
  if (argv.includes("--help") || argv.includes("-h")) help();
  else if (argv.includes("--uninstall")) uninstall();
  else if (argv.includes("--status")) status();
  else if (argv.includes("--test")) test(argv[argv.indexOf("--test") + 1] ?? "done");
  else install();
} catch (error) {
  console.error(`error: ${error.message}`);
  process.exit(1);
}
