// pi-dockerized security guard extension
//
// pi-dockerized security layer for Pi. Baked read-only into the image at build
// time (extensions/pi-security-guard/), so it cannot be altered from within a
// session. Edit from the host in the repo and rebuild the image.
//
// The guard version lives in policy.mjs (GUARD_VERSION).
//
// Policy modes (env PI_DOCKERIZED_POLICY, set by the wrapper from
// `setting.security_policy`; default "balanced"):
//   strict   — every vendored pattern is enforced as-is, and tools this policy
//              does not model (MCP, other extensions) are refused unless listed
//              in PI_DOCKERIZED_ALLOWED_TOOLS (`setting.allowed_tools`).
//   balanced — cloud-tenant-specific rules, upstream `admin_bypass` rules and
//              patterns that fire on ordinary local development are dropped,
//              while the genuinely dangerous ones stay. (recommended)
//   off      — vendored patterns are disabled entirely; the built-in backstops
//              in backstops.mjs stay active.
//
// The vendored unsafe/injection pattern sets in ./policies/*.json (ported from
// opencode-policy, MIT — see policies/README.md) are evaluated with the same
// first-match semantics as upstream (new RegExp(pattern, flags ?? "i")).
//
// Host-managed, read-only inputs (mounted by the wrapper, absent otherwise):
//   PI_DOCKERIZED_ALLOW_FILE — extra allow rules (same shape as
//                              policies/allow-patterns.json).
// Output:
//   PI_DOCKERIZED_AUDIT_FILE — JSON lines, one per blocked call. The session
//                              can write it, so it is a review aid, not
//                              tamper-proof evidence.
//
// Enforcement: Pi has no native permission system, so this extension registers
// a `tool_call` handler and blocks disallowed calls with `{ block, reason }`.
// The policy logic lives in ./policy.mjs so it can be unit-tested with Node.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  appendFileSync,
  existsSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";
import {
  compile,
  evaluateToolCall,
  inputStrings,
  loadRuleFile,
  redact,
  selectRules,
} from "./policy.mjs";
import { pathToFileURL } from "node:url";

const KNOWN_MODES = ["strict", "balanced", "off"];
const POLICY_MODE = (
  process.env.PI_DOCKERIZED_POLICY || "balanced"
).toLowerCase();
const ALLOW_FILE =
  process.env.PI_DOCKERIZED_ALLOW_FILE || "/home/coder/.pi/agent/allow.json";
const AUDIT_FILE =
  process.env.PI_DOCKERIZED_AUDIT_FILE || "/home/coder/.pi/agent/audit.log";
const MAX_AUDIT_BYTES = 1024 * 1024;
const KEEP_AUDIT_BYTES = 256 * 1024;

// Never degrade silently: a missing or broken pattern file leaves only the
// built-in backstops active, so say so on stderr.
const warn = (message: string) =>
  console.error(`[pi-security-guard] WARNING: ${message}`);

if (!KNOWN_MODES.includes(POLICY_MODE)) {
  warn(`unknown policy "${POLICY_MODE}", using "balanced"`);
}

const loadCompiled = (url: URL) =>
  compile(loadRuleFile(url, warn), (rule: any) =>
    warn(`${url.pathname}: skipped invalid rule ${rule?.id ?? "(no id)"}`),
  );

const loadVendored = (name: string) =>
  loadCompiled(new URL(`./policies/${name}`, import.meta.url));

// Optional host-side allow rules: a read-only mount the session cannot edit.
const loadHostAllowRules = (): any[] =>
  existsSync(ALLOW_FILE) ? loadCompiled(pathToFileURL(ALLOW_FILE)) : [];

const UNSAFE_PATTERNS = selectRules(
  loadVendored("unsafe-tool-patterns.json"),
  POLICY_MODE,
);
const INJECTION_PATTERNS = selectRules(
  loadVendored("prompt-injection-patterns.json"),
  POLICY_MODE,
);
const ALLOW_PATTERNS = [...loadVendored("allow-patterns.json"), ...loadHostAllowRules()];
const ALLOWED_TOOLS = (process.env.PI_DOCKERIZED_ALLOWED_TOOLS || "")
  .split(",")
  .map((name) => name.trim())
  .filter(Boolean);

if (POLICY_MODE !== "off" && UNSAFE_PATTERNS.length === 0) {
  warn("no vendored unsafe-tool patterns loaded; only built-in backstops are active");
}

// Keep the log bounded: past the cap, retain only the newest entries. The file
// is a bind-mounted single file, so it is rewritten in place, never renamed.
const trimAudit = () => {
  if (statSync(AUDIT_FILE).size <= MAX_AUDIT_BYTES) return;
  const tail = readFileSync(AUDIT_FILE).subarray(-KEEP_AUDIT_BYTES).toString("utf8");
  writeFileSync(AUDIT_FILE, tail.slice(tail.indexOf("\n") + 1));
};

// Best effort and silent: auditing must never break or block a tool call.
const audit = (tool: string, input: unknown, rule: string | undefined) => {
  if (!existsSync(AUDIT_FILE)) return;
  try {
    trimAudit();
    const target = inputStrings(tool, (input ?? {}) as Record<string, unknown>)[0] ?? "";
    const line = JSON.stringify({
      ts: new Date().toISOString(),
      tool,
      rule: rule ?? "unknown",
      target: redact(target),
    });
    appendFileSync(AUDIT_FILE, line + "\n");
  } catch {
    // ignore
  }
};

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    try {
      const result = evaluateToolCall({
        tool: event.toolName,
        input: event.input,
        cwd: ctx?.cwd,
        unsafePatterns: UNSAFE_PATTERNS,
        injectionPatterns: INJECTION_PATTERNS,
        allowPatterns: ALLOW_PATTERNS,
        unknownTools: POLICY_MODE === "strict" ? "deny" : "scan",
        allowedTools: ALLOWED_TOOLS,
      });
      if (!result) return undefined;
      audit(event.toolName, event.input, result.rule);
      return { block: true, reason: result.reason };
    } catch (error) {
      // Fail closed: a policy bug must not turn into an open door.
      audit(event.toolName, event.input, "guard/error");
      return {
        block: true,
        reason: `Blocked by pi-dockerized security policy: guard error (${(error as Error).message})`,
      };
    }
  });
}
