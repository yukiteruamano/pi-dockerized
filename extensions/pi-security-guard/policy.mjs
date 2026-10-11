// pi-dockerized security guard — pure policy logic.
//
// Dependency-free (only node:fs) so it can be unit-tested with plain Node
// (`node tests/security-guard.test.mjs`) without Pi installed. The Pi extension
// in index.ts loads the pattern files and wires this into Pi's `tool_call`
// handler; selftest.mjs runs the same logic as a fail-closed boot check.
//
// Layout: backstops.mjs (built-in deny-lists), shell.mjs (de-obfuscation),
// balanced-excluded.json (what the "balanced" mode drops).

import { readFileSync, realpathSync } from "node:fs";
import {
  DENY_BASH,
  DENY_READ,
  DENY_SECRET_PATH,
  SECRET_PATH_RE,
} from "./backstops.mjs";
import { normalizeShell, shellVariants } from "./shell.mjs";

export { DENY_BASH, DENY_READ, DENY_SECRET_PATH, SECRET_PATH_RE, normalizeShell };

// Bump when guard behavior changes. Single source of truth: the wrapper's
// `version`/`doctor` read it from the image through selftest.mjs.
export const GUARD_VERSION = 4;

// Longest value evaluated. Several vendored and backstop patterns scan with
// `[^\n|;&]*`, which is quadratic on long lines: 100 KiB takes ~50 s. Beyond the
// cap the call is refused (fail closed); file contents belong in the write tool.
export const MAX_EVAL_LENGTH = 16 * 1024;

const loadBalancedExcluded = () => {
  try {
    const url = new URL("./balanced-excluded.json", import.meta.url);
    const data = JSON.parse(readFileSync(url, "utf8"));
    return new Set(data.groups.flatMap((group) => group.ids));
  } catch (error) {
    // An empty set keeps every rule: stricter, never weaker.
    console.error(
      `[pi-security-guard] WARNING: cannot load balanced-excluded.json (${error.message}); "balanced" enforces every rule`,
    );
    return new Set();
  }
};

// Rules dropped in "balanced" mode (plus upstream `admin_bypass` rules).
// `strict` keeps them all. Grouped with reasons in balanced-excluded.json.
export const BALANCED_EXCLUDED_IDS = loadBalancedExcluded();

/** Read one JSON rule array from a file URL; `warn(message)` reports problems. */
export function loadRuleFile(url, warn = () => {}) {
  const name = url.pathname.replace(/.*\//, "");
  try {
    const parsed = JSON.parse(readFileSync(url, "utf8"));
    if (Array.isArray(parsed)) return parsed;
    warn(`${name} is not a JSON array; its rules are disabled`);
  } catch (error) {
    warn(`cannot load ${name} (${error.message}); its rules are disabled`);
  }
  return [];
}

/**
 * Turn a vendored rule array into {id, reason, adminBypass, re}.
 * Rules that cannot be built are dropped; `onSkip(rule)` lets the caller
 * report them instead of silently weakening the policy.
 */
export function compile(rules, onSkip = () => {}) {
  return rules
    .map((rule) => {
      if (!rule || typeof rule.pattern !== "string") {
        onSkip(rule);
        return undefined;
      }
      try {
        return {
          id: rule.id,
          reason: rule.reason,
          adminBypass: rule.admin_bypass === true,
          re: new RegExp(rule.pattern, rule.flags ?? "i"),
        };
      } catch {
        onSkip(rule);
        return undefined;
      }
    })
    .filter(Boolean);
}

/** Apply the policy mode to a rule array. */
export function selectRules(rules, mode) {
  if (mode === "off") return [];
  if (mode === "strict") return rules;
  return rules.filter(
    (rule) => !rule.adminBypass && !BALANCED_EXCLUDED_IDS.has(rule.id),
  );
}

/** First matching rule for a value, or undefined. */
export function matchRule(rules, value) {
  for (const rule of rules) {
    if (rule.re.test(value)) return rule;
  }
  return undefined;
}

/** True when an allow rule applies (never for chained/multi-line values). */
export function isAllowed(allowRules, value) {
  if (/[;&|\n\r]/.test(value)) return false;
  for (const rule of allowRules) {
    if (rule.re.test(value)) return true;
  }
  return false;
}

/** Lexically normalize a path (resolve `.`/`..`/duplicate slashes). */
export function normalizeLexical(p) {
  const absolute = p.startsWith("/");
  const parts = p.split("/");
  const stack = [];
  for (const part of parts) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (stack.length > 0) stack.pop();
      continue;
    }
    stack.push(part);
  }
  return (absolute ? "/" : "") + stack.join("/");
}

/** Resolve a path to its real location, or undefined if it cannot be resolved. */
export function tryRealpath(p) {
  if (typeof p !== "string" || p === "") return undefined;
  try {
    return realpathSync.native(p);
  } catch {
    return undefined;
  }
}

/** Recursively collect every string value in a tool input object. */
export function collectStrings(obj, out = []) {
  if (obj == null) return out;
  if (typeof obj === "string") {
    out.push(obj);
  } else if (Array.isArray(obj)) {
    for (const v of obj) collectStrings(v, out);
  } else if (typeof obj === "object") {
    for (const v of Object.values(obj)) collectStrings(v, out);
  }
  return out;
}

// Tools whose values are scanned against the vendored pattern sets.
export const TOOL_ACTIONS = new Set(["bash", "read", "edit", "write", "grep", "find"]);
// Prompt-injection patterns only make sense for free-text inputs, not paths.
export const INJECTION_ACTIONS = new Set(["bash"]);
// Shell-capable tools.
export const SHELL_TOOLS = new Set(["bash", "powershell"]);
// Read-oriented tools (their path/pattern values are scanned for secrets).
export const READ_TOOLS = new Set(["read", "grep", "find", "ls"]);
// Tools that mutate files (confinement to the project + scratch dir).
export const WRITE_TOOLS = new Set(["write", "edit"]);
// Every tool this policy understands; anything else is an "unknown tool".
export const KNOWN_TOOLS = new Set([
  ...TOOL_ACTIONS,
  ...SHELL_TOOLS,
  ...READ_TOOLS,
  ...WRITE_TOOLS,
]);
// Extra writable locations beyond the project root.
export const EXTRA_WRITE_ROOTS = ["/tmp/pi"];

// Files inside the project that Git executes on the host: the project
// directory is shared with the host, so planting one is a sandbox escape.
export const PROTECTED_WRITE_RE =
  /(^|\/)\.git\/(?:hooks(?:\/|$)|config$|info\/attributes$)|(^|\/)\.gitmodules$/;

// Input fields that carry file paths. For write/edit the other strings are file
// contents (`content`, `oldText`, `newText`, ...): they are data, not targets,
// and must be neither path-checked nor pattern-scanned.
const PATH_KEYS = ["path", "file_path", "filePath", "file", "paths"];

/** Strings the policy should evaluate for a tool call. */
export function inputStrings(tool, obj) {
  if (!WRITE_TOOLS.has(tool)) return collectStrings(obj);
  const paths = PATH_KEYS.flatMap((key) => collectStrings(obj[key]));
  // Unknown schema: fail closed by evaluating every string.
  return paths.length > 0 ? paths : collectStrings(obj);
}

/** True when an absolute path is inside one of the writable roots. */
export function withinRoots(path, roots) {
  return roots.some((r) => path === r || path.startsWith(r + "/"));
}

/** Mask credential-looking values and truncate, for the audit log. */
export function redact(value, max = 200) {
  // Schemes first: `Authorization: Bearer x` must lose `x`, not just `Bearer`.
  const masked = String(value)
    .replace(/\b(Bearer|Basic)\s+\S+/gi, "$1 [redacted]")
    .replace(
      /(\b[\w-]*(?:key|token|secret|passw(?:or)?d|credential|auth)[\w-]*\s*[=:]\s*)(?:"[^"]*"|'[^']*'|\S+)/gi,
      "$1[redacted]",
    )
    .replace(/\bsk-[A-Za-z0-9_-]{8,}/g, "sk-[redacted]");
  return masked.length > max ? masked.slice(0, max) + "…" : masked;
}

const blocked = (reason, rule) => ({ block: true, reason, rule });

const vendoredBlock = (rule) =>
  blocked(
    `Blocked by workspace policy (opencode-policy/${rule.id}): ${rule.reason}`,
    `opencode-policy/${rule.id}`,
  );

// Vendored unsafe patterns (first match wins) over every value of the call.
// Shell commands are also tested in their de-obfuscated forms.
function scanVendored({ tool, strings, unsafePatterns, allowPatterns }) {
  for (const value of strings) {
    if (typeof value !== "string" || value === "") continue;
    if (isAllowed(allowPatterns, value)) continue;
    const forms = tool === "bash" ? shellVariants(value) : [value];
    for (const form of forms) {
      const rule = matchRule(unsafePatterns, form);
      if (rule) return vendoredBlock(rule);
    }
  }
  return undefined;
}

// Built-in backstops for shell commands, covering gaps the pattern sets miss.
function scanShellBackstops(command) {
  for (const form of shellVariants(command)) {
    for (const pattern of DENY_BASH) {
      if (pattern.test(form)) {
        return blocked(
          "Blocked by pi-dockerized security policy: " + command,
          "backstop/bash",
        );
      }
    }
    for (const pattern of DENY_SECRET_PATH) {
      if (pattern.test(form)) {
        return blocked(
          "Blocked by pi-dockerized security policy: " + command,
          "backstop/secret-path",
        );
      }
    }
  }
  return undefined;
}

// Each value is tested alone so the `$`/`^` anchors in DENY_READ apply to a
// path, not to a space-joined list of every input string.
function scanReadTargets(strings) {
  for (const path of strings) {
    const real = tryRealpath(path);
    if (DENY_READ.test(path) || (real && DENY_READ.test(real))) {
      return blocked(
        "Blocked by pi-dockerized security policy: refusing to read " + path,
        "backstop/read",
      );
    }
  }
  return undefined;
}

// Writes stay inside the project (or scratch dir) and never touch the files
// Git runs on the host. Symlinks are resolved so a link cannot escape: the
// literal path, its real target and the real parent are all checked (the
// target may not exist yet).
function scanWriteTargets(strings, roots) {
  for (const path of strings) {
    if (typeof path !== "string" || path === "") continue;
    const absolute = path.startsWith("/")
      ? normalizeLexical(path)
      : normalizeLexical(roots[0] + "/" + path);
    const candidates = [absolute];
    const real = tryRealpath(absolute);
    if (real) candidates.push(real);
    const parent = tryRealpath(absolute.replace(/\/[^/]*$/, "") || "/");
    if (parent) candidates.push(parent + "/" + absolute.replace(/.*\//, ""));
    if (candidates.some((c) => PROTECTED_WRITE_RE.test(c))) {
      return blocked(
        "Blocked by pi-dockerized security policy: Git hooks/config run on the host: " +
          path,
        "backstop/protected-write",
      );
    }
    if (candidates.some((c) => !withinRoots(c, roots))) {
      return blocked(
        "Blocked by pi-dockerized security policy: write outside project directory: " +
          path,
        "backstop/write-confinement",
      );
    }
  }
  return undefined;
}

/**
 * Evaluate one Pi tool call against the security policy.
 * Returns `{ block: true, reason, rule }` to block, or `undefined` to allow.
 * Pure: the caller supplies the compiled rule sets and the working directory.
 * `unknownTools` decides what happens to tools this policy does not model
 * (MCP tools, other extensions): "scan" runs the vendored patterns over their
 * values, "deny" also refuses any tool not listed in `allowedTools`.
 * @param {{
 *   tool: string, input: unknown, cwd: string,
 *   unsafePatterns: any[], injectionPatterns: any[], allowPatterns: any[],
 *   unknownTools?: "scan" | "deny", allowedTools?: Iterable<string>,
 * }} args
 */
export function evaluateToolCall({
  tool,
  input,
  cwd,
  unsafePatterns,
  injectionPatterns,
  allowPatterns,
  unknownTools = "scan",
  allowedTools = [],
}) {
  const obj = input ?? {};
  const strings = inputStrings(tool, obj);
  const joined = strings.join(" ");
  const known = KNOWN_TOOLS.has(tool);

  if (!known && unknownTools === "deny" && !new Set(allowedTools).has(tool)) {
    return blocked(
      `Blocked by pi-dockerized security policy: tool "${tool}" is not allowed in strict mode (list it in setting.allowed_tools)`,
      "backstop/unknown-tool",
    );
  }

  if (joined.length > MAX_EVAL_LENGTH) {
    return blocked(
      `Blocked by pi-dockerized security policy: input too long to evaluate safely (${joined.length} > ${MAX_EVAL_LENGTH} chars); write file contents with the write tool`,
      "backstop/too-long",
    );
  }

  // Writable roots: the session working directory plus the scratch dir. Never
  // treat "/" as a writable root (a session whose directory is "/" must not
  // become a global write allow).
  const roots = [typeof cwd === "string" ? cwd : undefined, ...EXTRA_WRITE_ROOTS].filter(
    (r) => typeof r === "string" && r.startsWith("/") && r !== "/",
  );

  if ((TOOL_ACTIONS.has(tool) || !known) && unsafePatterns.length > 0) {
    const hit = scanVendored({ tool, strings, unsafePatterns, allowPatterns });
    if (hit) return hit;
  }

  // Prompt-injection patterns only for free-text (shell) inputs.
  if (INJECTION_ACTIONS.has(tool) && injectionPatterns.length > 0) {
    const command = typeof obj.command === "string" ? obj.command : joined;
    if (!isAllowed(allowPatterns, command)) {
      const rule = matchRule(injectionPatterns, command);
      if (rule) return vendoredBlock(rule);
    }
  }

  if (SHELL_TOOLS.has(tool)) {
    const hit = scanShellBackstops(typeof obj.command === "string" ? obj.command : joined);
    if (hit) return hit;
  }

  if (READ_TOOLS.has(tool)) {
    const hit = scanReadTargets(strings);
    if (hit) return hit;
  }

  if (WRITE_TOOLS.has(tool) && roots.length > 0) {
    const hit = scanWriteTargets(strings, roots);
    if (hit) return hit;
  }

  return undefined;
}
