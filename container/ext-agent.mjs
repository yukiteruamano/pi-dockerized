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
//   ext-agent.mjs check <file>     exit 1 unless <file> holds the security keys
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

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`cannot read ${path}: ${error.message}`);
  }
}

/** Security keys of `settings` that differ from `base`. */
export function violations(settings, base) {
  if (settings === null || typeof settings !== "object" || Array.isArray(settings)) {
    return ["settings is not a JSON object"];
  }
  return SECURITY_KEYS.filter((key) => !same(settings[key], base[key])).map(
    (key) =>
      `${key} is ${JSON.stringify(settings[key])}, expected ${JSON.stringify(base[key])}`,
  );
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
  const [command, target] = argv;
  if (!target) throw new Error("usage: ext-agent.mjs seed|enforce <dir> | check <file>");
  if (command === "seed" || command === "enforce") {
    const result = enforce(target, { create: command === "seed" });
    if (result !== "ok") console.log(`settings.json ${result}`);
    return 0;
  }
  if (command === "check") {
    const found = violations(readJson(target), readJson(BASE_PATH));
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
