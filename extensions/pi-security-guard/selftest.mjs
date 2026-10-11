// pi-dockerized security guard — boot self-test.
//
//   node selftest.mjs            exit 0 when the guard is intact, 1 otherwise
//   node selftest.mjs --version  print GUARD_VERSION
//
// entrypoint.sh runs it before every command: if the guard files are missing,
// the pattern sets are empty or a canary call is judged wrongly, the container
// refuses to start instead of running Pi without enforcement. The canaries are
// built-in backstops, so they must hold in every policy mode, including "off".

import {
  GUARD_VERSION,
  compile,
  evaluateToolCall,
  loadRuleFile,
  selectRules,
} from "./policy.mjs";

if (process.argv.includes("--version")) {
  console.log(GUARD_VERSION);
  process.exit(0);
}

const mode = (process.env.PI_DOCKERIZED_POLICY || "balanced").toLowerCase();
const failures = [];

const load = (name) => {
  const rules = compile(
    loadRuleFile(new URL(`./policies/${name}`, import.meta.url), (m) => failures.push(m)),
    (rule) => failures.push(`${name}: invalid rule ${rule?.id ?? "(no id)"}`),
  );
  if (rules.length === 0) failures.push(`${name}: no rules loaded`);
  return rules;
};

const unsafe = load("unsafe-tool-patterns.json");
const injection = load("prompt-injection-patterns.json");
const allow = load("allow-patterns.json");

const base = {
  cwd: "/selftest/project",
  unsafePatterns: selectRules(unsafe, mode),
  injectionPatterns: selectRules(injection, mode),
  allowPatterns: allow,
};

// [tool, input, expected]: "block" or "allow".
const canaries = [
  ["bash", { command: "cat .env" }, "block"],
  ["bash", { command: "cat .e''nv" }, "block"],
  ["bash", { command: "rm -rf /" }, "block"],
  ["bash", { command: "echo x > .git/hooks/pre-commit" }, "block"],
  ["read", { path: "/home/coder/.ssh/id_rsa" }, "block"],
  ["write", { path: "../outside.txt", content: "x" }, "block"],
  ["write", { path: ".git/hooks/pre-commit", content: "x" }, "block"],
  ["bash", { command: "ls -la" }, "allow"],
  ["read", { path: "src/index.ts" }, "allow"],
  ["write", { path: "notes.txt", content: "mentions .env and rm -rf /" }, "allow"],
];

for (const [tool, input, expected] of canaries) {
  const got = evaluateToolCall({ tool, input, ...base }) ? "block" : "allow";
  if (got !== expected) {
    failures.push(`canary ${tool} ${JSON.stringify(input)}: ${got} (want ${expected})`);
  }
}

if (failures.length > 0) {
  console.error(`pi-security-guard self-test FAILED (guard ${GUARD_VERSION}, mode ${mode}):`);
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
