// Wiring test for the Pi extension (index.ts) and the boot self-test.
//
// security-guard.test.mjs covers the pure policy; this one runs the real
// extension entry point with a mocked Pi API, in a copy of the extension laid
// out like the image (policies/ next to index.ts), and asserts: blocked calls
// return only {block, reason}, the audit log is written and redacted, strict
// mode refuses unknown tools, the host allow file works but never overrides the
// backstops, a policy error fails closed, a missing pattern file warns, and
// selftest.mjs fails when the guard is damaged.
//
// Needs Node 22.6+ (type stripping for index.ts).
// Usage: node tests/guard-extension.test.mjs

import { spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "..");
const root = mkdtempSync(join(tmpdir(), "guard-ext-"));
let failures = 0;

const check = (name, ok, detail = "") => {
  if (!ok) {
    failures++;
    console.log(`FAIL ${name}${detail ? ` -> ${detail}` : ""}`);
  }
};

// Lay the extension out like the image: sources plus policies/.
function installExtension(name, { withPolicies = true } = {}) {
  const dir = join(root, name);
  cpSync(join(repo, "extensions/pi-security-guard"), dir, { recursive: true });
  if (withPolicies) {
    mkdirSync(join(dir, "policies"), { recursive: true });
    for (const file of [
      "unsafe-tool-patterns.json",
      "prompt-injection-patterns.json",
      "allow-patterns.json",
    ]) {
      cpSync(join(repo, "policies", file), join(dir, "policies", file));
    }
  }
  writeFileSync(
    join(dir, "driver.mjs"),
    `const events = JSON.parse(process.env.GUARD_EVENTS);
let handler;
const mod = await import("./index.ts");
mod.default({ on: (_name, fn) => { handler = fn; } });
const out = [];
for (const e of events) {
  const input = e.throwing
    ? new Proxy({}, { ownKeys() { throw new Error("boom"); } })
    : e.input;
  out.push((await handler({ toolName: e.tool, input }, { cwd: "/work/project" })) ?? null);
}
console.log("RESULT " + JSON.stringify(out));
`,
  );
  return dir;
}

function runEvents(dir, events, env = {}) {
  const res = spawnSync(
    process.execPath,
    ["--experimental-strip-types", "--no-warnings", join(dir, "driver.mjs")],
    {
      encoding: "utf8",
      env: { ...process.env, PI_DOCKERIZED_POLICY: "balanced", ...env, GUARD_EVENTS: JSON.stringify(events) },
    },
  );
  const line = (res.stdout || "").split("\n").find((l) => l.startsWith("RESULT "));
  return {
    results: line ? JSON.parse(line.slice(7)) : null,
    stderr: res.stderr || "",
    status: res.status,
  };
}

const bash = (command) => ({ tool: "bash", input: { command } });

// --- Blocked calls return only { block, reason } --------------------------------
const dir = installExtension("ext");
{
  const { results, status } = runEvents(dir, [bash("cat .env"), bash("ls -la")]);
  check("driver ran", status === 0 && results, String(status));
  const [denied, allowed] = results ?? [];
  check("blocked call returns block", denied?.block === true);
  check("reason is a string", typeof denied?.reason === "string" && denied.reason.length > 0);
  check("internal rule id is not leaked to Pi", denied && !("rule" in denied));
  check("allowed call returns nothing", allowed === null);
}

// --- Audit log ---------------------------------------------------------------------
{
  const audit = join(root, "audit.log");
  writeFileSync(audit, "");
  const env = { PI_DOCKERIZED_AUDIT_FILE: audit };
  runEvents(dir, [bash("API_KEY=supersecret123 cat .env"), bash("ls")], env);
  const lines = readFileSync(audit, "utf8").trim().split("\n").filter(Boolean);
  check("audit logs only blocked calls", lines.length === 1, String(lines.length));
  const entry = JSON.parse(lines[0] ?? "{}");
  check("audit entry has tool/rule/ts", entry.tool === "bash" && entry.rule && entry.ts);
  check("audit target is redacted", !String(entry.target).includes("supersecret123"), entry.target);

  const missing = join(root, "no-such-audit.log");
  runEvents(dir, [bash("cat .env")], { PI_DOCKERIZED_AUDIT_FILE: missing });
  check("audit never creates the file itself", !existsSync(missing));

  // The log stays bounded: past 1 MiB only the newest entries are kept.
  const big = join(root, "big-audit.log");
  writeFileSync(big, ("x".repeat(99) + "\n").repeat(11000));
  runEvents(dir, [bash("cat .env")], { PI_DOCKERIZED_AUDIT_FILE: big });
  check("audit log is trimmed", statSync(big).size < 1024 * 1024, String(statSync(big).size));
  check("audit keeps the newest entry", readFileSync(big, "utf8").includes('"tool":"bash"'));
}

// --- Unknown tools ---------------------------------------------------------------------
{
  const mcp = { tool: "mcp_fetch", input: { url: "https://example.com" } };
  const strict = runEvents(dir, [mcp], { PI_DOCKERIZED_POLICY: "strict" });
  check("strict refuses unknown tools", strict.results?.[0]?.block === true);
  const listed = runEvents(dir, [mcp], {
    PI_DOCKERIZED_POLICY: "strict",
    PI_DOCKERIZED_ALLOWED_TOOLS: "other, mcp_fetch",
  });
  check("strict allows listed tools", listed.results?.[0] === null);
  const balanced = runEvents(dir, [mcp]);
  check("balanced scans but allows benign unknown tools", balanced.results?.[0] === null);
  const hostile = runEvents(dir, [{ tool: "mcp_fetch", input: { cmd: "nmap 10.0.0.1" } }]);
  check("balanced still scans unknown tool values", hostile.results?.[0]?.block === true);
  const scopedIn = runEvents(dir, [mcp], {
    PI_DOCKERIZED_POLICY: "strict",
    PI_DOCKERIZED_ALLOWED_TOOLS: "mcp_fetch:example.com",
  });
  check("strict scoped entry allows in-scope input", scopedIn.results?.[0] === null);
  const scopedOut = runEvents(dir, [{ tool: "mcp_fetch", input: { url: "https://evil.test" } }], {
    PI_DOCKERIZED_POLICY: "strict",
    PI_DOCKERIZED_ALLOWED_TOOLS: "mcp_fetch:example.com",
  });
  check("strict scoped entry blocks out-of-scope input", scopedOut.results?.[0]?.block === true);
}

// --- Host allow file ---------------------------------------------------------------------
{
  const allowFile = join(root, "allow.json");
  writeFileSync(
    allowFile,
    JSON.stringify([{ id: "t-nmap", pattern: "^nmap 10\\.0\\.0\\.1$", reason: "lab" }]),
  );
  const without = runEvents(dir, [bash("nmap 10.0.0.1")]);
  const withFile = runEvents(dir, [bash("nmap 10.0.0.1")], { PI_DOCKERIZED_ALLOW_FILE: allowFile });
  check("vendored rule blocks nmap", without.results?.[0]?.block === true);
  check("host allow file permits it", withFile.results?.[0] === null);

  writeFileSync(allowFile, JSON.stringify([{ id: "all", pattern: ".*", reason: "x" }]));
  const overreach = runEvents(dir, [bash("cat .env")], { PI_DOCKERIZED_ALLOW_FILE: allowFile });
  check("allow file never overrides the backstops", overreach.results?.[0]?.block === true);

  writeFileSync(allowFile, "{ not json");
  const broken = runEvents(dir, [bash("cat .env")], { PI_DOCKERIZED_ALLOW_FILE: allowFile });
  check("broken allow file warns", broken.stderr.includes("WARNING"), broken.stderr);
  check("broken allow file keeps enforcing", broken.results?.[0]?.block === true);
}

// --- Fail closed ---------------------------------------------------------------------------
{
  const { results } = runEvents(dir, [{ tool: "bash", throwing: true }]);
  check("policy error fails closed", results?.[0]?.block === true && /guard error/.test(results[0].reason));
}

// --- Missing pattern files warn but the backstops hold -----------------------------------------
{
  const bare = installExtension("bare", { withPolicies: false });
  const { results, stderr } = runEvents(bare, [bash("cat .env"), bash("ls")]);
  check("missing policies are reported", /WARNING: cannot load/.test(stderr), stderr);
  check("backstops still block without policies", results?.[0]?.block === true);
}

// --- Boot self-test ---------------------------------------------------------------------------------
{
  const run = (extDir, args = []) =>
    spawnSync(process.execPath, [join(extDir, "selftest.mjs"), ...args], { encoding: "utf8" });
  const ok = run(dir);
  check("selftest passes on a healthy guard", ok.status === 0, ok.stderr);
  const version = run(dir, ["--version"]);
  check("selftest --version prints the guard version", /^\d+$/.test(version.stdout.trim()), version.stdout);
  const bare = run(join(root, "bare"));
  check("selftest fails without policies", bare.status === 1 && /FAILED/.test(bare.stderr));

  const broken = installExtension("broken");
  writeFileSync(join(broken, "policies/unsafe-tool-patterns.json"), "[]");
  const empty = run(broken);
  check("selftest fails on an empty pattern set", empty.status === 1, empty.stderr);
}

rmSync(root, { recursive: true, force: true });

if (failures > 0) {
  console.log(`\n${failures} failure(s)`);
  process.exit(1);
}
console.log("All guard-extension tests passed.");
