#!/usr/bin/env node
// Keeps the security keys of the host-managed Pi settings intact.
//
// Extensions are Pi Packages installed with the official `pi install`, run in a
// throwaway container whose agent directory is a host directory (ext-agent/).
// `pi install` writes that directory's settings.json, and sessions later mount
// it read-only in place of the baked one. So the baked security defaults can no
// longer be guaranteed by the image alone; this script guarantees them instead:
//
//   ext-agent.mjs seed <dir>       create <dir>/settings.json from the baked
//                                  defaults when missing, then enforce
//   ext-agent.mjs enforce <dir>    reapply the security keys, keep everything else
//   ext-agent.mjs check <file> [--host]
//                                  exit 1 unless <file> holds the security keys;
//                                  --host also rejects keys that are not
//                                  preferences (see PREFERENCE_KEYS)
//
// `seed`/`enforce` run in the installer container after every `pi install`;
// `check` runs in entrypoint.sh before every session and fails closed.

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";

// The baked reference copy (settings.base.json is also shadowed by the host
// file inside sessions, so the image keeps one that is never mounted over).
// Overridable only in tests.
const BASE_PATH =
  process.env.PI_DOCKERIZED_TEST === "1" && process.env.PI_DOCKERIZED_BASE_SETTINGS
    ? process.env.PI_DOCKERIZED_BASE_SETTINGS
    : "/usr/local/lib/pi-dockerized/settings.base.json";

// Settings whose value is part of the sandbox: project trust, where sessions
// live, telemetry and the default tool set. Everything else (packages, theme,
// model, ...) is the user's.
export const SECURITY_KEYS = [
  "defaultProjectTrust",
  "sessionDir",
  "enableInstallTelemetry",
  "defaultTools",
];

// Keys a host-written settings.json may carry besides the security keys: user
// preferences only. Left out on purpose: packages, extensions, skills, prompts
// and themes (they load code or paths), externalEditor, shellPath,
// shellCommandPrefix and npmCommand (they run commands), httpProxy (routes
// traffic), enableAnalytics and trackingId (telemetry), deviceId (identity).
export const PREFERENCE_KEYS = [
  "$schema",
  "defaultThinkingLevel",
  "hideThinkingBlock",
  "showCacheMissNotices",
  "cacheWarming",
  "steeringMode",
  "followUpMode",
  "doubleEscapeAction",
  "treeFilterMode",
  "theme",
  "quietStartup",
  "tuiMode",
  "fullscreenExitOutput",
  "fullscreenScrollbar",
  "fullscreenCopyOnSelect",
  "fullscreenWheelScrollLines",
  "editorPaddingX",
  "outputPad",
  "autocompleteMaxVisible",
  "showHardwareCursor",
  "terminal",
  "images",
  "markdown",
  "transport",
  "httpIdleTimeoutMs",
  "websocketConnectTimeoutMs",
  "retry",
  "compaction",
  "branchSummary",
  "codemode",
  "enableSkillCommands",
  "collapseChangelog",
  "warnings",
  "defaultProvider",
  "defaultModel",
  "modelThinkingLevels",
  "thinkingBudgets",
  "enabledModels",
];

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`cannot read ${path}: ${error.message}`);
  }
}

/**
 * Problems with `settings`: security keys that differ from `base`, and, with
 * `host`, keys that are neither security keys nor preferences.
 */
export function violations(settings, base, { host = false } = {}) {
  if (settings === null || typeof settings !== "object" || Array.isArray(settings)) {
    return ["settings is not a JSON object"];
  }
  const pinned = SECURITY_KEYS.filter((key) => !same(settings[key], base[key])).map(
    (key) =>
      `${key} is ${JSON.stringify(settings[key])}, expected ${JSON.stringify(base[key])}`,
  );
  if (!host) return pinned;
  const foreign = Object.keys(settings)
    .filter((key) => !SECURITY_KEYS.includes(key) && !PREFERENCE_KEYS.includes(key))
    .map((key) => `${key} is not a host setting`);
  return [...pinned, ...foreign];
}

/** `settings` with the security keys of `base` applied over it. */
export function enforced(settings, base) {
  const out = { ...settings };
  for (const key of SECURITY_KEYS) out[key] = base[key];
  return out;
}

function enforce(dir, { create }) {
  const base = readJson(BASE_PATH);
  const file = join(dir, "settings.json");
  mkdirSync(dir, { recursive: true });
  if (!existsSync(file)) {
    if (!create) throw new Error(`${file} does not exist`);
    writeFileSync(file, JSON.stringify(base, null, 2) + "\n");
    return "seeded";
  }
  const current = readJson(file);
  if (violations(current, base).length === 0) return "ok";
  writeFileSync(file, JSON.stringify(enforced(current, base), null, 2) + "\n");
  return "repaired";
}

function main(argv) {
  const [command, target, flag] = argv;
  if (!target) throw new Error("usage: ext-agent.mjs seed|enforce <dir> | check <file> [--host]");
  if (command === "seed" || command === "enforce") {
    const result = enforce(target, { create: command === "seed" });
    if (result !== "ok") console.log(`settings.json ${result}`);
    return 0;
  }
  if (command === "check") {
    const found = violations(readJson(target), readJson(BASE_PATH), {
      host: flag === "--host",
    });
    if (found.length === 0) return 0;
    console.error(`${target} breaks the sandbox settings:`);
    for (const line of found) console.error(`  - ${line}`);
    return 1;
  }
  throw new Error(`unknown command "${command}"`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    process.exit(main(process.argv.slice(2)));
  } catch (error) {
    console.error(`ext-agent: ${error.message}`);
    process.exit(1);
  }
}
