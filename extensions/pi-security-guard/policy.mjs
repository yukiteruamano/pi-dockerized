// pi-dockerized security guard — pure policy logic.
//
// Dependency-free (only node:fs for realpath) so it can be unit-tested with
// plain Node (`node tests/security-guard.test.mjs`) without Pi installed.
// The Pi extension in index.ts loads the pattern files and wires this into
// Pi's `tool_call` handler.

import { realpathSync } from "node:fs";

// Rules dropped in "balanced" mode: shared multi-tenant cloud sandbox rules,
// upstream `admin_bypass` rules, and patterns that fire on ordinary local
// development. `strict` keeps them all.
export const BALANCED_EXCLUDED_IDS = new Set([
  "env-var-ref",
  "shell-var-expansion",
  "bypass-var-substring",
  "bypass-var-replace",
  "bypass-ifs-1",
  "bypass-brace-cmd",
  "env-direct-1",
  "var-access-1",
  "var-access-2",
  "var-access-3",
  "dotenv-1",
  "dotenv-2",
  "node-dotenv",
  "python-env-1",
  "python-env-2",
  "python-import-environ",
  "python-subprocess-env",
  "node-env",
  "pythonpath",
  "node-path",
  "npx-test-json",
  "npx-env",
  "npx-dump",
  "npx-leak",
  "npx-secret",
  "npx-config",
  "npx-diag",
  "npx-debug",
  "npm-run-env",
  "node-p-process",
  "node-print-process",
  "kill-9",
  "kill-system-1",
  "kill-system-2",
  "sed-exec",
  "eval-cmd",
  "git-hooks",
  "time-exfil-sleep",
  "bypass-nohup",
  "bypass-disown",
  "bypass-setsid",
  "stress-1",
  "stress-2",
  "stress-test",
  "cpu-stress",
  "thermal-test",
  "urandom-bzip",
  "sysbench",
  "rustup",
  "go-install",
  "haskell",
  "pip-tensorflow",
  "pip-transformers",
  "pip-cuda",
  "pip-opencv",
  "npm-tensorflow",
  "base64-pipe-2",
  "xxd-tool",
  "hexdump-tool",
  "od-tool",
  "cd-parent-workspace",
  "cd-dotdot-in-script",
  "workspace-root-direct",
  "workspace-root-ls",
  "shared-dir-access",
  "find-workspace",
  "history-1",
  "dns-exfil-3",
  "exec-builtin",
  "fork-bomb-2",
  "env-direct-2",
  "at-schedule",
  "base64-exfil-1",
  "dos-yes",
  "dos-yes-pipe",
]);

/** Compile a vendored rule array into {id, reason, adminBypass, re}. */
export function compile(rules) {
  return rules
    .map((rule) => {
      if (!rule || typeof rule.pattern !== "string") return undefined;
      try {
        return {
          id: rule.id,
          reason: rule.reason,
          adminBypass: rule.admin_bypass === true,
          re: new RegExp(rule.pattern, rule.flags ?? "i"),
        };
      } catch (e) {
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

/** Normalize shell obfuscation (`${IFS}`, `$'\t'`) back to spaces. */
export function normalizeShell(cmd) {
  return cmd
    .replace(/\$\{IFS[^}]*\}/gi, " ")
    .replace(/\$'\\t'/g, " ")
    .replace(/\$'\\n'/g, " ");
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
  } catch (e) {
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

/** True when an absolute path is inside one of the writable roots. */
export function withinRoots(path, roots) {
  return roots.some((r) => path === r || path.startsWith(r + "/"));
}

// Secret file names/paths referenced from a shell command (any tool).
export const SECRET_PATH_RE =
  /(^|[\/\s'"=:(])auth\.json([\s'"\/):;,]|$)|(^|[\/\s'"=:(])credentials([\s'"\/.=:;,]|$)|(^|[\/\s'"=:(])\.npmrc([\s'"\/):;,]|$)|(^|[\/\s'"=:(])\.mcp-auth([\/\s'"=:;,]|$)|(^|[\/\s'"=:(])\.gitconfig([\s'"\/):;,]|$)|(^|[\/\s'"=:(])\.composio([\/\s'"=:;,]|$)|(^|[\/\s'"=:(])id_(rsa|dsa|ecdsa|ed25519|ed25519_sk|ecdsa_sk|eddsa)([\s'"\/):;,]|$)/i;

const LEAK_VERB =
  "cat|tac|less|more|head|tail|grep|egrep|fgrep|rg|sed|awk|cut|strings|xxd|od|" +
  "hexdump|base64|base32|cp|mv|install|scp|rsync|tar|zip|gzip|bzip2|xz|curl|wget|" +
  "nc|ncat|socat|telnet|python[0-9.]*|node|deno|bun|perl|ruby|php|" +
  "sort|nl|rev|tr|split|comm|join|paste|pr|fmt|expand|unexpand|fold|csplit|" +
  "diff|cmp|xargs|dd";

const leakOf = (token) =>
  new RegExp(`\\b(?:${LEAK_VERB})\\b[^\\n|;&]*${token}`, "i");

const READ_VERB =
  "cat|tac|less|more|head|tail|cp|mv|install|scp|rsync|tar|zip|gzip|bzip2|xz|" +
  "base64|base32|xxd|od|hexdump|strings|dd|python[0-9.]*|node|deno|bun|perl|ruby|php";

const leakReadOf = (token) =>
  new RegExp(`\\b(?:${READ_VERB})\\b[^\\n|;&]*${token}`, "i");

export const DENY_SECRET_PATH = [/(^|[\s'"=:(/@,<>\-])\.env(?!\.example\b)/i];

const KEY_FILE =
  "(?:[\\w.-]*(?:_key|-key|_priv)|id_(?:rsa|dsa|ecdsa|ed25519|eddsa))(?![A-Za-z0-9])(?!\\.pub\\b)";
const BARE_KEY = "(?:[\\w.-]*key)(?![A-Za-z0-9])(?!\\.pub\\b)";
const KEY_TOKEN = `(?:\\.pem\\b(?!\\.pub\\b)|\\.key\\b(?!\\.pub\\b)|${KEY_FILE}|${BARE_KEY})`;

export const DENY_BASH = [
  /\bsudo\b/,
  /\brm\s+(-[a-zA-Z]+\s+)*-[a-zA-Z]*[rf][a-zA-Z]*\s+\/(\s|$)/,
  /\brm\s+.*\s+\/\s*$/,
  /\brm\s+[^\n|;&]*\s\/\*([\s;|&]|$)/,
  /\brm\s+[^\n|;&]*\/\.\.(\/|$)/,
  /\bmkfs(\.\w+)?\b/,
  /\bdd\b[^|;&]*\bof=\/(dev\/)?[a-z]/,
  /\b(shutdown|reboot|halt|poweroff)\b/,
  /\bchmod\s+(-[a-zA-Z]+\s+)*0?777\s+\/(\s|$)/,
  /\bchmod\s+[^\n|;&]*\s\/\*([\s;|&]|$)/,
  /\bchmod\s+[^\n|;&]*\/\.\.(\/|$)/,
  /\bchown\s+[^\n|;&]*\s\/([\s;|&*]|$)/,
  /\bchown\s+[^\n|;&]*\/\.\.(\/|$)/,
  />\s*\/dev\/(sd|nvme|hd)/,
  /\/proc\/[^/\s]*\/environ\b/,
  /169\.254\.169\.254/,
  /\b2852039166\b|\b0x[aA]9[fF][eE][aA]9[fF][eE]\b|0x[aA]9\s*\.\s*0x[fF][eE]\s*\.\s*0x[aA]9\s*\.\s*0x[fF][eE]\b|\b0251\.0376\.0251\.0376\b|::ffff:(a9fe:a9fe|169\.254\.169\.254)/i,
  /\bdocker\b[^\n|;&]*-v\s+\/:/,
  /\bdocker\b[^\n|;&]*--privileged\b/,
  /\bdocker\b[^\n|;&]*--volume\s+\/:\//,
  /\bdocker\b[^\n|;&]*--mount\b[^\n|;&]*\bsource\s*=\s*\/([\s,]|$)/,
  SECRET_PATH_RE,
  leakOf("\\.pem\\b(?!\\.pub\\b)"),
  leakOf("\\.key\\b(?!\\.pub\\b)"),
  leakOf(KEY_FILE),
  leakReadOf(BARE_KEY),
  /(^|[;&|]\s*)(?:source|\.)\s+[^\s'"|;&<>]*\.(?:pem|key)\b(?!\.pub\b)/i,
  /<\s*[^\s'"|;&]*\.(?:pem|key)\b(?!\.pub\b)/i,
  /\bopenssl\s+(?:rsa|pkey|ec|dsa|pkcs8|pkcs12|asn1parse)\b[^\n|;&]*(?:-inkey\b|-in\b|-text\b)/i,
  /\bssh-keygen\b[^\n|;&]*-y\b[^\n|;&]*-f\b/,
  new RegExp(`\\bgit\\b\\s+(?:show|cat-file)\\b[^\\n|;&]*:[^\\s;|&]*${KEY_TOKEN}`),
  new RegExp(`\\bgit\\b\\s+grep\\b[^\\n|;&]*${KEY_TOKEN}`),
  new RegExp(`\\bgit\\b\\s+archive\\b[^\\n|;&]*${KEY_TOKEN}`),
  new RegExp(`\\bgit\\b\\s+log\\b[^\\n|;&]*(?:-p\\b|--patch\\b)[^\\n|;&]*${KEY_TOKEN}`),
  new RegExp(`\\bgit\\b\\s+diff\\b(?![^\\n|;&]*--stat\\b)[^\\n|;&]*${KEY_TOKEN}`),
  new RegExp(
    `(?:^|[;|&\\s])(?:\\bssh-keygen\\b|[^\\s;|&]+\\/[\\w.-]+)[^\\n|;&]*-y\\b[^\\n|;&]*-f\\b[^\\n|;&]*${KEY_TOKEN}`,
  ),
  new RegExp(
    `(?:^|[;|&\\s])(?:\\bopenssl\\b|[^\\s;|&]+\\/[\\w.-]+)\\s+(?:rsa|pkey|ec|dsa|pkcs8|pkcs12|asn1parse)\\b[^\\n|;&]*(?:-inkey\\b|-in\\b|-text\\b)[^\\n|;&]*${KEY_TOKEN}`,
    "i",
  ),
  /\bprivate-keys-v1\.d\b/,
  /\bgpg\b[^\n|;&]*--export-secret(-keys|-subkeys)?\b/i,
  /(^|[;|&(`\n])\s*\b(env|printenv|set|export|declare|typeset)\b\s*([;|&\n]|$)/i,
  /\bexport\s+-p\b/i,
  /\bdeclare\s+-p\b/i,
  /\btypeset\s+-p\b/i,
  /\bcompgen\s+-e\b/i,
  /\bcompgen\s+-v\b/i,
  /\bdeclare\s+-x\b/i,
  /\btypeset\s+-x\b/i,
  /\bprintenv\b\s+[^\n|;&]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|AUTH|API[_-]?KEY)\b/i,
  /\bconsole\s*\.\s*(?:log|dir|debug|info)\s*\(\s*process\s*\.\s*env\s*\)/,
  /\bnode\b[^\n|;&]*-(?:p\b|print\b)[^\n|;&]*\bprocess\s*\.\s*env\b(?!\s*(\.\s*[A-Za-z_$][\w$]*|\[\s*["']))/,
  /\bprint\s*\(\s*os\s*\.\s*environ(?:\s*\.\s*(?:copy|items|keys|values)\s*\(\s*\))?\s*\)/,
  /\bpprint\s*\(\s*os\s*\.\s*environ\s*\)/,
  /\bputs\s+ENV\b(?!\s*(\[|\.\s*(?:fetch|key\?|slice|dig|values_at)\s*\())|\bp\s+ENV\b(?!\s*(\[|\.\s*(?:fetch|key\?|slice|dig|values_at)\s*\())|\bENV\s*\.\s*(?:inspect|to_h|to_hash)\b/,
  /(?:\bprint\b|\bsay\b|\bwarn\b|\bprintf\b)[^\n;&]*%ENV\b/,
  /(?:\bprint_r\b|\bvar_dump\b|\bvar_export\b)\s*\(\s*(?:getenv\s*\(\s*\)|\$_ENV\b(?!\s*\[)|\$_SERVER\b(?!\s*\[))/,
  /\bconsole\s*\.\s*(?:log|dir)\s*\(\s*Deno\s*\.\s*env\s*\.\s*toObject\s*\(\s*\)\s*\)/,
  /\bssh-add\b[^\n|;&]*-[DdxXe]\b/,
  /\bgpgconf\b[^\n|;&]*--(?:kill|reload)\b/i,
  // Pi self-management: extensions, MCP servers and Pi itself are fixed at
  // image build time and must not be changed from inside a session.
  /\bpi\s+update\b/,
  /\bpi\s+install\b/,
  /\bpi\s+uninstall\b/,
  /\bpi\s+remove\b/,
  /\bpi\s+mcp\s+(?:add|remove|rm)\b/,
];

// Denied read paths: secrets, keys, host credential/config files.
export const DENY_READ =
  /(^|\/)\.env(\.(?!example$)|$)|\.pem$|\.key$|(^|\/)auth\.json$|(^|\/)mcp-auth\.json$|(^|\/)trust\.json$|(^|\/)id_(rsa|dsa|ecdsa|ed25519|ed25519_sk|ecdsa_sk|eddsa)$|(^|\/)\.ssh(\/|$)|(^|\/)\.npmrc$|(^|\/)\.mcp-auth(\/|$)|(^|\/)credentials(\.|$)|(^|\/)private-keys-v1\.d(\/|$)|(^|\/)\.gitconfig$|(^|\/)\.composio(\/|$)|(^|\/)[\w.-]*(?:_key|-key|_priv)$|(^|\/)[\w.-]*key$/;

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
// Extra writable locations beyond the project root.
export const EXTRA_WRITE_ROOTS = ["/tmp/pi"];

/**
 * Evaluate one Pi tool call against the security policy.
 * Returns `{ block: true, reason }` to block, or `undefined` to allow.
 * Pure: the caller supplies the compiled rule sets and the working directory.
 * @param {{
 *   tool: string, input: unknown, cwd: string,
 *   unsafePatterns: any[], injectionPatterns: any[], allowPatterns: any[],
 * }} args
 */
export function evaluateToolCall({
  tool,
  input,
  cwd,
  unsafePatterns,
  injectionPatterns,
  allowPatterns,
}) {
  const obj = (input ?? {});
  const strings = collectStrings(obj);
  const joined = strings.join(" ");
  const deny = (reason) => ({ block: true, reason });

  // Writable roots: the session working directory plus the scratch dir. Never
  // treat "/" as a writable root (a session whose directory is "/" must not
  // become a global write allow).
  const roots = [typeof cwd === "string" ? cwd : undefined, ...EXTRA_WRITE_ROOTS].filter(
    (r) => typeof r === "string" && r.startsWith("/") && r !== "/",
  );

  // Vendored unsafe patterns (first match wins) over the tool's values.
  if (TOOL_ACTIONS.has(tool) && unsafePatterns.length > 0) {
    for (const value of strings) {
      if (typeof value !== "string" || value === "") continue;
      if (isAllowed(allowPatterns, value)) continue;
      const rule = matchRule(unsafePatterns, value);
      if (rule) {
        return deny(
          `Blocked by workspace policy (opencode-policy/${rule.id}): ${rule.reason}`,
        );
      }
    }
  }

  // Prompt-injection patterns only for free-text (shell) inputs.
  if (INJECTION_ACTIONS.has(tool) && injectionPatterns.length > 0) {
    const command = typeof obj.command === "string" ? obj.command : joined;
    if (!isAllowed(allowPatterns, command)) {
      const rule = matchRule(injectionPatterns, command);
      if (rule) {
        return deny(
          `Blocked by workspace policy (opencode-policy/${rule.id}): ${rule.reason}`,
        );
      }
    }
  }

  // Built-in backstops, covering gaps the pattern sets may miss.
  if (SHELL_TOOLS.has(tool)) {
    const command = typeof obj.command === "string" ? obj.command : joined;
    const normalized = normalizeShell(command);
    for (const pattern of DENY_BASH) {
      if (pattern.test(command) || pattern.test(normalized)) {
        return deny("Blocked by pi-dockerized security policy: " + command);
      }
    }
    for (const pattern of DENY_SECRET_PATH) {
      if (pattern.test(command) || pattern.test(normalized)) {
        return deny("Blocked by pi-dockerized security policy: " + command);
      }
    }
  }

  if (READ_TOOLS.has(tool)) {
    const path = joined;
    const real = strings.map(tryRealpath).filter(Boolean).join(" ");
    if (DENY_READ.test(path) || (real !== "" && DENY_READ.test(real))) {
      return deny(
        "Blocked by pi-dockerized security policy: refusing to read " + path,
      );
    }
  }

  if (WRITE_TOOLS.has(tool) && roots.length > 0) {
    for (const path of strings) {
      if (typeof path !== "string" || path === "") continue;
      // Resolve relative targets against the working directory. Resolve
      // symlinks so a link inside the project cannot be used to write outside
      // it; check the literal path, its real target, and the real parent (the
      // target may not exist yet).
      const absolute = path.startsWith("/")
        ? normalizeLexical(path)
        : normalizeLexical(roots[0] + "/" + path);
      const candidates = [absolute];
      const real = tryRealpath(absolute);
      if (real) candidates.push(real);
      const parent = tryRealpath(absolute.replace(/\/[^/]*$/, "") || "/");
      if (parent) candidates.push(parent + "/" + absolute.replace(/.*\//, ""));
      if (candidates.some((c) => !withinRoots(c, roots))) {
        return deny(
          "Blocked by pi-dockerized security policy: write outside project directory: " +
            path,
        );
      }
    }
  }

  return undefined;
}
