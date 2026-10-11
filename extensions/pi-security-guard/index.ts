// pi-dockerized security guard extension
//
// pi-dockerized security layer for Pi. Baked read-only into the image at build
// time (extensions/pi-security-guard/), so it cannot be altered from within a
// session. Edit from the host in the repo and rebuild the image.
//
// PI_DOCKERIZED_GUARD_VERSION=2
//
// Policy modes (env PI_DOCKERIZED_POLICY, set by the wrapper from
// `setting.security_policy`; default "balanced"):
//   strict   — every vendored pattern is enforced as-is.
//   balanced — cloud-tenant-specific rules, upstream `admin_bypass` rules and
//              patterns that fire on ordinary local development are dropped,
//              while the genuinely dangerous ones stay. (recommended)
//   off      — vendored patterns are disabled entirely; the built-in backstops
//              in policy.mjs stay active.
//
// The vendored unsafe/injection pattern sets in ./policies/*.json (ported from
// opencode-policy, MIT — see policies/README.md) are evaluated with the same
// first-match semantics as upstream (new RegExp(pattern, flags ?? "i")).
//
// Enforcement: Pi has no native permission system, so this extension registers
// a `tool_call` handler and blocks disallowed calls with `{ block, reason }`.
// The policy logic lives in ./policy.mjs so it can be unit-tested with Node.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { compile, selectRules, evaluateToolCall } from "./policy.mjs";

const POLICY_MODE = (
  process.env.PI_DOCKERIZED_POLICY || "balanced"
).toLowerCase();

const loadRules = (name: string): any[] => {
  try {
    const url = new URL(`./policies/${name}`, import.meta.url);
    const parsed = JSON.parse(readFileSync(url, "utf8"));
    return Array.isArray(parsed) ? parsed : [];
  } catch (e) {
    return [];
  }
};

const UNSAFE_PATTERNS = selectRules(
  compile(loadRules("unsafe-tool-patterns.json")),
  POLICY_MODE,
);
const INJECTION_PATTERNS = selectRules(
  compile(loadRules("prompt-injection-patterns.json")),
  POLICY_MODE,
);
const ALLOW_PATTERNS = compile(loadRules("allow-patterns.json"));

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) =>
    evaluateToolCall({
      tool: event.toolName,
      input: event.input,
      cwd: ctx?.cwd,
      unsafePatterns: UNSAFE_PATTERNS,
      injectionPatterns: INJECTION_PATTERNS,
      allowPatterns: ALLOW_PATTERNS,
    }),
  );
}
