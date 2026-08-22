#!/usr/bin/env node
/**
 * Renders the cuelume cue palette to WAV files a plain Windows player can open.
 *
 * cuelume (https://cuelume.dev, MIT, Danilaa1/cuelume) synthesizes its 17 cues
 * live in the browser and ships no audio files at all. So this script rebuilds
 * cuelume's own audio graph on an OfflineAudioContext and captures the output.
 * The graph code below is a direct port of `cuelume/dist/audio/engine.js`; the
 * recipes are imported unmodified from the installed package, so `npm update
 * cuelume` picks up new or retuned cues on the next render.
 *
 * Two variants are written per cue:
 *   sounds/<cue>.wav       - with a near-silent lead-in, for a cold Bluetooth
 *                            link that would otherwise swallow the attack
 *   sounds/warm/<cue>.wav  - no lead-in, used when media was just playing and
 *                            the link is already awake
 */

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

import { OfflineAudioContext } from "node-web-audio-api";

import { loadConfig, ROOT, SOUNDS_DIR, STAMP_PATH, WARM_DIR } from "./lib/config.js";

/** Bumped whenever the render pipeline changes, so stale WAVs are re-rendered. */
const RENDERER_VERSION = 1;

// --- cuelume engine constants (engine.js) -----------------------------------
const SOURCE_STOP_PADDING = 0.05;
const CLEANUP_MARGIN = 0.05;
const INAUDIBLE_GAIN = 0.001;
const OUTPUT_GAIN = 4;

// `RECIPES` is not in cuelume's package `exports` map, so import the file
// directly by URL rather than by specifier.
const recipesUrl = pathToFileURL(
  join(ROOT, "node_modules", "cuelume", "dist", "sounds", "recipes.js"),
);
const { RECIPES } = await import(recipesUrl.href);

function renderTone(context, destination, layer, startTime) {
  const oscillator = context.createOscillator();
  oscillator.type = layer.waveform;
  oscillator.frequency.setValueAtTime(layer.frequency, startTime);
  if (layer.detune) oscillator.detune.value = layer.detune;
  if (layer.glideTo !== undefined) {
    const glideTime = layer.glideTime ?? layer.attack + layer.decay;
    oscillator.frequency.exponentialRampToValueAtTime(layer.glideTo, startTime + glideTime);
  }

  const gain = context.createGain();
  gain.gain.setValueAtTime(0.0001, startTime);
  gain.gain.exponentialRampToValueAtTime(layer.peak, startTime + layer.attack);
  gain.gain.exponentialRampToValueAtTime(0.0001, startTime + layer.attack + layer.decay);

  oscillator.connect(gain).connect(destination);
  oscillator.start(startTime);
  oscillator.stop(startTime + layer.attack + layer.decay + SOURCE_STOP_PADDING);
}

function renderNoise(context, destination, layer, startTime) {
  const duration = layer.attack + layer.decay + SOURCE_STOP_PADDING;
  const length = Math.max(1, Math.floor(duration * context.sampleRate));
  const buffer = context.createBuffer(1, length, context.sampleRate);
  const data = buffer.getChannelData(0);
  for (let i = 0; i < length; i++) data[i] = 2 * Math.random() - 1;
  buffer.copyToChannel(data, 0);

  const source = context.createBufferSource();
  source.buffer = buffer;

  const filter = context.createBiquadFilter();
  filter.type = layer.filterType;
  filter.frequency.value = layer.filterFrequency;
  if (layer.filterQ !== undefined) filter.Q.value = layer.filterQ;

  const gain = context.createGain();
  gain.gain.setValueAtTime(0.0001, startTime);
  gain.gain.exponentialRampToValueAtTime(layer.peak, startTime + layer.attack);
  gain.gain.exponentialRampToValueAtTime(0.0001, startTime + layer.attack + layer.decay);

  source.connect(filter).connect(gain).connect(destination);
  source.start(startTime);
  source.stop(startTime + duration);
}

/** Wires a soft echo/shimmer send off `source`, feeding back into `destination`. */
function attachShimmer(context, source, destination, shimmer) {
  const delay = context.createDelay(1);
  delay.delayTime.value = shimmer.delay;

  const feedbackFilter = context.createBiquadFilter();
  feedbackFilter.type = "lowpass";
  feedbackFilter.frequency.value = shimmer.lowpass;

  const feedbackGain = context.createGain();
  feedbackGain.gain.value = shimmer.feedback;

  const wetGain = context.createGain();
  wetGain.gain.value = shimmer.wet;

  source.connect(delay);
  delay.connect(feedbackFilter);
  feedbackFilter.connect(feedbackGain);
  feedbackGain.connect(delay);
  feedbackFilter.connect(wetGain);
  wetGain.connect(destination);
}

function sourceEnd(recipe) {
  return Math.max(
    ...recipe.layers.map(
      (layer) => (layer.offset ?? 0) + layer.attack + layer.decay + SOURCE_STOP_PADDING,
    ),
  );
}

function shimmerTail(shimmer) {
  if (!shimmer || shimmer.feedback <= 0) return 0;
  if (shimmer.feedback >= 1) return shimmer.delay;
  return shimmer.delay * (1 + Math.ceil(Math.log(INAUDIBLE_GAIN) / Math.log(shimmer.feedback)));
}

/** Renders one recipe offline and returns mono Float32 samples. */
async function renderCue(name, sampleRate) {
  const recipe = RECIPES[name];
  const duration = sourceEnd(recipe) + shimmerTail(recipe.shimmer) + CLEANUP_MARGIN;
  const length = Math.ceil(duration * sampleRate);
  const context = new OfflineAudioContext(1, length, sampleRate);

  const output = context.createGain();
  output.gain.value = OUTPUT_GAIN;

  // cuelume's shared safety limiter, kept so loud recipes stay in character.
  const limiter = context.createDynamicsCompressor();
  limiter.threshold.value = -8;
  limiter.knee.value = 6;
  limiter.ratio.value = 12;
  limiter.attack.value = 0.002;
  limiter.release.value = 0.08;
  output.connect(limiter).connect(context.destination);

  const master = context.createGain();
  master.gain.value = recipe.masterGain;
  master.connect(output);

  if (recipe.shimmer) attachShimmer(context, master, output, recipe.shimmer);

  for (const layer of recipe.layers) {
    const startTime = layer.offset ?? 0;
    if (layer.kind === "tone") renderTone(context, master, layer, startTime);
    else renderNoise(context, master, layer, startTime);
  }

  const rendered = await context.startRendering();
  return rendered.getChannelData(0);
}

/** Scales samples so the loudest one sits exactly at `peak`. */
function normalize(samples, peak) {
  let max = 0;
  for (const sample of samples) {
    const magnitude = Math.abs(sample);
    if (magnitude > max) max = magnitude;
  }
  if (max === 0) return samples;

  const scale = peak / max;
  const out = new Float32Array(samples.length);
  for (let i = 0; i < samples.length; i++) out[i] = samples[i] * scale;
  return out;
}

/**
 * Prepends near-silent dither. AirPods drop the A2DP stream when idle and the
 * first few hundred ms after it wakes get swallowed; this padding is what gets
 * eaten instead of the cue's attack. Amplitude is ~1 LSB of 16-bit, inaudible.
 */
function withLeadIn(samples, sampleRate, leadInMs) {
  if (leadInMs <= 0) return samples;

  const padLength = Math.round((leadInMs / 1000) * sampleRate);
  const out = new Float32Array(padLength + samples.length);
  const dither = 2 / 32768;
  for (let i = 0; i < padLength; i++) out[i] = (Math.random() * 2 - 1) * dither;
  out.set(samples, padLength);
  return out;
}

/** Encodes mono Float32 samples as a 16-bit PCM WAV file. */
function encodeWav(samples, sampleRate) {
  const dataBytes = samples.length * 2;
  const buffer = Buffer.alloc(44 + dataBytes);

  buffer.write("RIFF", 0, "ascii");
  buffer.writeUInt32LE(36 + dataBytes, 4);
  buffer.write("WAVE", 8, "ascii");
  buffer.write("fmt ", 12, "ascii");
  buffer.writeUInt32LE(16, 16); // PCM chunk size
  buffer.writeUInt16LE(1, 20); // format = PCM
  buffer.writeUInt16LE(1, 22); // channels
  buffer.writeUInt32LE(sampleRate, 24);
  buffer.writeUInt32LE(sampleRate * 2, 28); // byte rate
  buffer.writeUInt16LE(2, 32); // block align
  buffer.writeUInt16LE(16, 34); // bits per sample
  buffer.write("data", 36, "ascii");
  buffer.writeUInt32LE(dataBytes, 40);

  for (let i = 0; i < samples.length; i++) {
    const clamped = Math.max(-1, Math.min(1, samples[i]));
    buffer.writeInt16LE(Math.round(clamped * 32767), 44 + i * 2);
  }
  return buffer;
}

async function main() {
  const config = loadConfig();
  const { sampleRate, leadInMs } = config.audio;
  const volume = Math.max(0, Math.min(1, config.audio.volume));

  mkdirSync(SOUNDS_DIR, { recursive: true });
  mkdirSync(WARM_DIR, { recursive: true });

  const names = Object.keys(RECIPES);
  const report = [];

  for (const name of names) {
    const raw = await renderCue(name, sampleRate);
    const warm = normalize(raw, volume);
    const cold = withLeadIn(warm, sampleRate, leadInMs);

    writeFileSync(join(WARM_DIR, `${name}.wav`), encodeWav(warm, sampleRate));
    writeFileSync(join(SOUNDS_DIR, `${name}.wav`), encodeWav(cold, sampleRate));

    report.push({ name, ms: Math.round((warm.length / sampleRate) * 1000) });
  }

  writeFileSync(
    STAMP_PATH,
    `${JSON.stringify(
      {
        renderer: RENDERER_VERSION,
        volume,
        leadInMs,
        sampleRate,
        cues: names,
        renderedAt: new Date().toISOString(),
      },
      null,
      2,
    )}\n`,
  );

  const summary = report.map((cue) => `${cue.name} ${cue.ms}ms`).join(", ");
  process.stdout.write(
    `rendered ${report.length} cues at ${sampleRate} Hz, peak ${volume}, lead-in ${leadInMs}ms\n` +
      `  ${SOUNDS_DIR}\n  ${WARM_DIR}\n  ${summary}\n`,
  );
}

await main();
