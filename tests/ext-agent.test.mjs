// Test for container/ext-agent.mjs, the guard of the host-managed Pi settings.
//
// Packages are installed with the official `pi install` against a host
// directory whose settings.json sessions later mount in place of the baked one.
// This script is what keeps the sandbox's security keys in that file: seeded
// from the baked defaults, reapplied after every Pi command, and checked by the
// entrypoint before every session. Package declarations and every other key
// must survive untouched.
//
// Usage: node tests/ext-agent.test.mjs

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { SECURITY_KEYS, enforced, violations } from "../container/ext-agent.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const script = join(here, "..", "container", "ext-agent.mjs");
const baseFile = join(here, "..", "container", "settings.base.json");
const base = JSON.parse(readFileSync(baseFile, "utf8"));
const root = mkdtempSync(join(tmpdir(), "ext-agent-"));
let failures = 0;

const check = (name, ok, detail = "") => {
  if (!ok) {
    failures++;
    console.log(`FAIL ${name}${detail ? ` -> ${detail}` : ""}`);
  }
};

const run = (args, env = {}) =>
  spawnSync(process.execPath, [script, ...args], {
    encoding: "utf8",
    env: {
      ...process.env,
      PI_DOCKERIZED_TEST: "1",
      PI_DOCKERIZED_BASE_SETTINGS: baseFile,
      ...env,
    },
  });
const read = (dir) => JSON.parse(readFileSync(join(dir, "settings.json"), "utf8"));
const fresh = (name) => {
  const dir = join(root, name);
  mkdirSync(dir, { recursive: true });
  return dir;
};

// --- The baked defaults really are the sandbox keys ---------------------------------------
check("base defines every security key", SECURITY_KEYS.every((key) => key in base));
check("base asks before trusting a project", base.defaultProjectTrust === "ask");
check("the baked settings declare no packages (they are host-managed)", !("packages" in base));

// --- Pure helpers ----------------------------------------------------------------------------
check("the baked settings have no violations", violations(base, base).length === 0);
check("a loosened trust is a violation", violations({ ...base, defaultProjectTrust: "always" }, base).length === 1);
check("a missing key is a violation", violations({ ...base, sessionDir: undefined }, base).length === 1);
check("a changed tool list is a violation", violations({ ...base, defaultTools: ["bash"] }, base).length === 1);
check("a non-object is a violation", violations([], base).length === 1 && violations(null, base).length === 1);
check("extra keys are not violations", violations({ ...base, packages: ["npm:x"], theme: "dark" }, base).length === 0);
const fixed = enforced({ defaultProjectTrust: "always", packages: ["npm:x"] }, base);
check("enforced restores the keys", violations(fixed, base).length === 0);
check("enforced keeps everything else", fixed.packages?.[0] === "npm:x");

// --- seed ---------------------------------------------------------------------------------------
let dir = fresh("seed");
let res = run(["seed", dir]);
check("seed succeeds", res.status === 0, res.stderr);
check("seed creates settings.json from the baked defaults", JSON.stringify(read(dir)) === JSON.stringify(base));
check("seed says what it did", /seeded/.test(res.stdout), res.stdout);

// seed must not overwrite what `pi install` already wrote.
writeFileSync(join(dir, "settings.json"), JSON.stringify({ ...base, packages: ["npm:@s/pkg@1.0.0"], theme: "dark" }));
res = run(["seed", dir]);
check("seeding twice is quiet", res.status === 0 && res.stdout.trim() === "", res.stdout);
check("seed keeps installed packages", read(dir).packages?.[0] === "npm:@s/pkg@1.0.0");
check("seed keeps the user's other settings", read(dir).theme === "dark");

// --- enforce ---------------------------------------------------------------------------------------
dir = fresh("enforce");
writeFileSync(
  join(dir, "settings.json"),
  JSON.stringify({ defaultProjectTrust: "always", sessionDir: "/tmp/x", enableInstallTelemetry: true, defaultTools: ["bash"], packages: ["npm:a", { source: "npm:b", extensions: ["!x"] }], model: "m" }),
);
res = run(["enforce", dir]);
check("enforce succeeds", res.status === 0, res.stderr);
check("enforce says it repaired", /repaired/.test(res.stdout), res.stdout);
let s = read(dir);
check("enforce restores every security key", violations(s, base).length === 0, JSON.stringify(s));
check("enforce keeps package declarations (string and object form)", s.packages?.length === 2 && s.packages[1].source === "npm:b");
check("enforce keeps other settings", s.model === "m");
check("enforce on a healthy file changes nothing", run(["enforce", dir]).stdout.trim() === "");
check("enforce does not create a missing file", run(["enforce", fresh("empty")]).status === 1);

// --- check ---------------------------------------------------------------------------------------------
check("check passes on the baked settings", run(["check", baseFile]).status === 0);
dir = fresh("check");
writeFileSync(join(dir, "settings.json"), JSON.stringify({ ...base, defaultProjectTrust: "always" }));
res = run(["check", join(dir, "settings.json")]);
check("check fails on loosened trust", res.status === 1);
check("check names the key", /defaultProjectTrust/.test(res.stderr), res.stderr);
writeFileSync(join(dir, "settings.json"), "{ not json");
check("check fails on invalid JSON", run(["check", join(dir, "settings.json")]).status === 1);
check("check fails on a missing file", run(["check", join(dir, "nope.json")]).status === 1);
check("check fails closed without the baked reference", run(["check", baseFile], { PI_DOCKERIZED_BASE_SETTINGS: join(dir, "nope.json") }).status === 1);

// The reference override only works in test mode: a session cannot point it elsewhere.
const live = spawnSync(process.execPath, [script, "check", baseFile], {
  encoding: "utf8",
  env: { ...process.env, PI_DOCKERIZED_TEST: "", PI_DOCKERIZED_BASE_SETTINGS: baseFile },
});
check("the baked reference path is not overridable outside test mode", live.status === 1 && /usr\/local\/lib/.test(live.stderr), live.stderr);

// --- host settings (check --host): preferences only -------------------------------------------------
check("the baked settings are a valid host file", run(["check", baseFile, "--host"]).status === 0);
check("the baked settings hold no key outside the host allowlist", violations(base, base, { host: true }).length === 0);
for (const key of ["packages", "extensions", "skills", "prompts", "themes", "npmCommand", "shellCommandPrefix", "shellPath", "externalEditor", "httpProxy", "enableAnalytics"]) {
  check(`host file may not set ${key}`, violations({ ...base, [key]: "x" }, base, { host: true }).length === 1);
}
check("host file may set a preference", violations({ ...base, theme: "dark" }, base, { host: true }).length === 0);
check("host mode still pins the security keys", violations({ ...base, defaultProjectTrust: "always" }, base, { host: true }).length === 1);
check("without --host, extra keys stay allowed (the packages file)", violations({ ...base, packages: ["npm:x"] }, base).length === 0);
dir = fresh("host");
writeFileSync(join(dir, "settings.json"), JSON.stringify({ ...base, packages: ["npm:x"] }));
res = run(["check", join(dir, "settings.json"), "--host"]);
check("check --host rejects packages", res.status === 1 && /packages is not a host setting/.test(res.stderr), res.stderr);

// --- usage ------------------------------------------------------------------------------------------------
check("unknown command fails", run(["frobnicate", dir]).status === 1);
check("missing target fails", run(["seed"]).status === 1);
check("no leftover files in the seeded directory", !existsSync(join(root, "seed", "settings.json.lock")));

rmSync(root, { recursive: true, force: true });

if (failures > 0) {
  console.log(`\n${failures} failure(s)`);
  process.exit(1);
}
console.log("All ext-agent tests passed.");
