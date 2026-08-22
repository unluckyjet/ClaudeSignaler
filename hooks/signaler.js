#!/usr/bin/env node
/**
 * Claude Code hook entry point.
 *
 * Hands off to scripts/signal.ps1 as an independent background process and
 * exits in ~150ms, so a turn is never held up by ~2s of pause/play/resume.
 *
 * Normal use is `node signaler.js --signal done`: the hook matcher in
 * settings.json already identifies the event, so stdin is never touched. Piping
 * a hook payload in still works for manual testing.
 *
 * Two hard rules:
 *   - print nothing to stdout. Another Stop hook already returns JSON there and
 *     a stray line would be parsed as hook output.
 *   - always exit 0. A signaler failure must never disturb a Claude Code turn.
 */

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SIGNAL_SCRIPT = join(ROOT, "scripts", "signal.ps1");
const LAUNCHER = join(ROOT, "scripts", "launch-hidden.vbs");

const SIGNALS = new Set(["done", "needsInput", "failed"]);

/**
 * Notification types that mean "Claude is blocked on you".
 * `idle_prompt` is deliberately absent: it fires ~60s after Stop already did,
 * which would sound a second cue for the same idle turn.
 */
const NEEDS_INPUT = new Set([
  "permission_prompt",
  "agent_needs_input",
  "elicitation_dialog",
  "elicitation_url_dialog",
]);

function readFlag(argv, name) {
  const index = argv.indexOf(name);
  return index >= 0 ? argv[index + 1] : null;
}

/** Only reached when no --signal was passed, i.e. manual testing. */
function classifyFromStdin() {
  let payload = {};
  try {
    const raw = readFileSync(0, "utf8");
    payload = raw.trim() ? JSON.parse(raw) : {};
  } catch {
    return [null, "manual"];
  }

  const reason = payload.notification_type || payload.hook_event_name || "manual";
  switch (payload.hook_event_name) {
    case "Stop":
      return ["done", reason];
    case "StopFailure":
      return ["failed", reason];
    case "Notification":
      return [NEEDS_INPUT.has(payload.notification_type) ? "needsInput" : null, reason];
    default:
      return [null, reason];
  }
}

/**
 * Launches signal.ps1 with no console window, ever.
 *
 * Two rejected approaches, both learned the hard way on this box:
 *   - Node's own `detached: true` sets Win32 DETACHED_PROCESS, under which
 *     `powershell.exe -File` exits 0 without running a line of the script.
 *   - `cmd /c start "" /b` runs, but hands PowerShell a fresh console, so a
 *     terminal window pops up on every single turn.
 *
 * wscript's `WScript.Shell.Run` with window style 0 never creates a console at
 * all - not even for a frame - and returns immediately, so the PowerShell it
 * starts is independent of this process.
 */
function launch(signal, reason) {
  spawnSync("wscript.exe", ["//nologo", LAUNCHER, SIGNAL_SCRIPT, signal, reason], {
    stdio: "ignore",
    windowsHide: true,
  });
}

function main() {
  const argv = process.argv.slice(2);
  const flag = readFlag(argv, "--signal");

  let signal = null;
  let reason = null;

  if (flag && SIGNALS.has(flag)) {
    signal = flag;
    reason = readFlag(argv, "--reason") ?? flag;
  } else {
    [signal, reason] = classifyFromStdin();
  }

  if (signal) launch(signal, reason);
}

try {
  main();
} catch {
  // Swallow everything. See the header: a broken cue must not break a turn.
}
process.exit(0);
