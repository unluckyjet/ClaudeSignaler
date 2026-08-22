/**
 * Shared paths and config loading for the Node-side scripts.
 * PowerShell reads the same config.json directly via ConvertFrom-Json.
 */

import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** Repository root — one level above `scripts/`. */
export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

export const CONFIG_PATH = join(ROOT, "config.json");
export const SOUNDS_DIR = join(ROOT, "sounds");
export const WARM_DIR = join(SOUNDS_DIR, "warm");
export const STAMP_PATH = join(SOUNDS_DIR, ".render-stamp.json");

const DEFAULTS = {
  events: {
    done: { enabled: true, cue: "ready" },
    needsInput: { enabled: true, cue: "chime" },
    failed: { enabled: true, cue: "error" },
  },
  audio: { volume: 0.32, leadInMs: 400, sampleRate: 48000 },
  media: { mode: "pause", resume: true, settleMs: 180, resumeDelayMs: 250 },
  cooldownMs: 1200,
  logging: { enabled: true, maxLines: 400 },
};

/**
 * Reads config.json and fills in any missing keys from DEFAULTS.
 * Throws only if the file exists but is not valid JSON — a missing file
 * falls back to defaults so the tool still makes a sound.
 */
export function loadConfig() {
  let raw = {};
  try {
    raw = JSON.parse(readFileSync(CONFIG_PATH, "utf8"));
  } catch (error) {
    if (error.code !== "ENOENT") {
      throw new Error(`config.json is not valid JSON: ${error.message}`);
    }
  }

  return {
    events: { ...DEFAULTS.events, ...(raw.events ?? {}) },
    audio: { ...DEFAULTS.audio, ...(raw.audio ?? {}) },
    media: { ...DEFAULTS.media, ...(raw.media ?? {}) },
    cooldownMs: raw.cooldownMs ?? DEFAULTS.cooldownMs,
    logging: { ...DEFAULTS.logging, ...(raw.logging ?? {}) },
  };
}
