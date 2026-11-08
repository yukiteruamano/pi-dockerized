// pi-dockerized security guard — built-in backstops.
//
// Regex deny-lists that stay active in every policy mode (including "off"):
// secret paths, destructive commands, Git host-execution vectors and Pi
// self-management. They back up the vendored pattern sets, which are
// replaceable data. Plus two parsers a regex cannot express (`git config`
// writes, globs aimed at secret names). Pure, no I/O.

// Secret file names/paths referenced from a shell command (any tool).
export const SECRET_PATH_RE =
  /(^|[\/\s'"=:(])[\w.-]*auth\.json([\s'"\/):;,]|$)|(^|[\/\s'"=:(])trust\.json([\s'"\/):;,]|$)|(^|[\/\s'"=:(])credentials([\s'"\/.=:;,]|$)|(^|[\/\s'"=:(])\.npmrc([\s'"\/):;,]|$)|(^|[\/\s'"=:(])\.mcp-auth([\/\s'"=:;,]|$)|(^|[\/\s'"=:(])\.gitconfig([\s'"\/):;,]|$)|(^|[\/\s'"=:(])\.composio([\/\s'"=:;,]|$)|(^|[\/\s'"=:(])\.(?:git-credentials|netrc|aws|kube)([\s'"\/):;,]|$)|(^|[\/\s'"=:(])\.docker\/config\.json([\s'"):;,]|$)|(^|[\/\s'"=:(])id_(rsa|dsa|ecdsa|ed25519|ed25519_sk|ecdsa_sk|eddsa)([\s'"\/):;,]|$)/i;

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

// The lookbehind anchors each name scan to a token start: unanchored, the
// `[\w.-]*` is retried at every offset and long tokens make it quadratic.
const KEY_FILE =
  "(?<![\\w.-])(?:[\\w.-]*(?:_key|-key|_priv)|id_(?:rsa|dsa|ecdsa|ed25519|eddsa))(?![A-Za-z0-9])(?!\\.pub\\b)";
const BARE_KEY = "(?<![\\w.-])(?:[\\w.-]*key)(?![A-Za-z0-9])(?!\\.pub\\b)";
// Each part somewhere later in the same command segment, in any order. One
// lookahead per part keeps the scan linear; chained `[^\n|;&]*a[^\n|;&]*b`
// is cubic on a long line of repeated flags.
const allOf = (...parts) => parts.map((part) => `(?=[^\\n|;&]*${part})`).join("");

// Start of a simple command, past common wrappers and assignments.
const COMMAND_START =
  "(?:^|[;|&(`\\n{]\\s*)\\s*(?:(?:env|exec|nohup|time|command|xargs|(?:ba|z|da)?sh\\s+-c|[A-Za-z_]\\w*=\\S*)\\s+)*";

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
  // Any process environment, including /proc/<pid>/task/<tid>/environ.
  /\/proc\/\S*environ/,
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
  new RegExp(`\\bssh-keygen\\b${allOf("-y\\b", "-f\\b")}`),
  new RegExp(`\\bgit\\b\\s+(?:show|cat-file)\\b[^\\n|;&]*:[^\\s;|&]*${KEY_TOKEN}`),
  new RegExp(`\\bgit\\b\\s+grep\\b[^\\n|;&]*${KEY_TOKEN}`),
  new RegExp(`\\bgit\\b\\s+archive\\b[^\\n|;&]*${KEY_TOKEN}`),
  new RegExp(`\\bgit\\b\\s+log\\b${allOf("(?:-p\\b|--patch\\b)", KEY_TOKEN)}`),
  new RegExp(`\\bgit\\b\\s+diff\\b(?![^\\n|;&]*--stat\\b)[^\\n|;&]*${KEY_TOKEN}`),
  // Renamed binaries (`./k -y -f key`), in command position (optionally after
  // a wrapper such as `env X=1` or `bash -c`): checking every path-like word
  // made long argument lists quadratic. `(?=(x))\1` makes the path match
  // atomic, so it does not backtrack over every `/` of a long word.
  new RegExp(
    `${COMMAND_START}(?:\\bssh-keygen\\b|(?=([^\\s;|&]+\\/[\\w.-]+))\\1)${allOf("-y\\b", "-f\\b", KEY_TOKEN)}`,
  ),
  new RegExp(
    `${COMMAND_START}(?:\\bopenssl\\b|(?=([^\\s;|&]+\\/[\\w.-]+))\\1)\\s+(?:rsa|pkey|ec|dsa|pkcs8|pkcs12|asn1parse)\\b${allOf("(?:-inkey\\b|-in\\b|-text\\b)", KEY_TOKEN)}`,
    "i",
  ),
  /\bprivate-keys-v1\.d\b/,
  /\bgpg\b[^\n|;&]*--export-secret(-keys|-subkeys)?\b/i,
  /(^|[;|&(`\n])\s*\b(env|printenv|set|export|declare|typeset)\b\s*([;|&\n)`]|$)/i,
  // env/printenv with only flags or assignments and no command still dumps
  // the environment: `env -0`, `printenv --null`, `env -u X`, `$(env FOO=1)`.
  /(^|[;|&(`\n{])\s*(?:env|printenv)\b(?:\s+(?:-u\s*\S+|--unset[= ]\S+|-[-\w]+|[A-Za-z_]\w*=\S*))*\s*(?:[;|&\n)`}]|$)/,
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
  // Whole-environment serialization: json.dumps(dict(os.environ)),
  // JSON.stringify(process.env), Object.entries(process.env), ...
  /\b(?:dict|list|str|repr|sorted|json\s*\.\s*dumps)\s*\(\s*(?:dict\s*\(\s*)?os\s*\.\s*environ\b(?!\s*(?:\.\s*get\b|\[))/,
  /\b(?:JSON\s*\.\s*stringify|Object\s*\.\s*(?:entries|values|assign)|util\s*\.\s*inspect)\s*\(\s*(?:\{\s*\.\.\.\s*)?process\s*\.\s*env\b(?!\s*(?:\.\s*[A-Za-z_$]|\[))/,
  /\bputs\s+ENV\b(?!\s*(\[|\.\s*(?:fetch|key\?|slice|dig|values_at)\s*\())|\bp\s+ENV\b(?!\s*(\[|\.\s*(?:fetch|key\?|slice|dig|values_at)\s*\())|\bENV\s*\.\s*(?:inspect|to_h|to_hash)\b/,
  /(?:\bprint\b|\bsay\b|\bwarn\b|\bprintf\b)[^\n;&]*%ENV\b/,
  /(?:\bprint_r\b|\bvar_dump\b|\bvar_export\b)\s*\(\s*(?:getenv\s*\(\s*\)|\$_ENV\b(?!\s*\[)|\$_SERVER\b(?!\s*\[))/,
  /\bconsole\s*\.\s*(?:log|dir)\s*\(\s*Deno\s*\.\s*env\s*\.\s*toObject\s*\(\s*\)\s*\)/,
  /\bssh-add\b[^\n|;&]*-[DdxXe]\b/,
  /\bgpgconf\b[^\n|;&]*--(?:kill|reload)\b/i,
  // Git runs files from the shared project's git dir on the host (hooks,
  // config, commondir, modules/*/config, config.worktree, gitfiles), so no
  // shell write may name a `.git` path component. Git's own porcelain
  // (commit, add, ...) names no .git path and is unaffected. `git config`
  // writes are checked separately (gitConfigWrite).
  />{1,2}\|?\s*['"]?(?:[^\s'"|;&<>]*\/)?\.git(?:\/|['"\s;|&)]|$)/i,
  /\b(?:cp|mv|tee|ln|install|chmod|chown|sed|perl|truncate|dd|touch|rm|mkdir|rmdir|patch|unzip)\b[^\n|;&]*(?:^|[\s'"=\/])\.git(?:\/|['"\s]|$)/i,
  /\b(?:python[0-9.]*|node|deno|bun|ruby|php)\b[^\n|;&]*(?:^|[\s'"=(\/])\.git\//i,
  // Entering the git dir would let relative paths (`hooks/x`) reach it.
  /\b(?:cd|pushd)\s+['"]?(?:[^\s'"|;&]*\/)?\.git(?:[\/\s'";&|)]|$)/i,
  /\bgit\b[^\n|;&]*\s-C\s*['"]?(?:[^\s'"|;&]*\/)?\.git(?:[\/\s'";&|)]|$)/i,
  /(?:>|>>)\s*['"]?[^\s'"|;&]*\.gitmodules\b/i,
  /\b(?:cp|mv|tee|ln|install|sed|truncate|dd|touch)\b[^\n|;&]*\.gitmodules\b/i,
  // Config-defined programs, also through `git -c` (inline config).
  /\bgit\b[^\n|;&]*\b(?:core\.(?:hookspath|fsmonitor|sshcommand|editor|pager|askpass)|credential\.helper|gpg\.(?:ssh\.)?program|include(?:if)?\.|diff\.external|filter\.[^\s=]*\.(?:clean|smudge|process))/i,
  // Pi self-management: extensions, MCP servers and Pi itself are fixed at
  // image build time and must not be changed from inside a session.
  /\bpi\s+update\b/,
  /\bpi\s+install\b/,
  /\bpi\s+uninstall\b/,
  /\bpi\s+remove\b/,
  /\bpi\s+mcp\s+(?:add|remove|rm)\b/,
];

// --- git config -------------------------------------------------------------
// The project's .git/config is read by git on the host, and most keys can make
// it run a program (include.path, diff.external, filter.*, core.*, alias.*,
// gpg.*, credential.*, ...). A session may set only identity and cosmetic or
// line-ending preferences; reads are always fine.
const GIT_CONFIG_SAFE_KEY =
  /^(?:user\.(?:name|email)|init\.defaultbranch|pull\.(?:rebase|ff)|push\.(?:default|autosetupremote)|core\.(?:autocrlf|eol)|color\.[\w.-]+)$/i;
// git's global options that take a separate argument (`git -C dir config`).
const GIT_OPT_WITH_ARG = new Set(["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"]);
// `git config` options that take a separate argument.
const CONFIG_OPT_WITH_ARG = new Set(["--type", "--default", "--comment", "--value", "-t"]);
const CONFIG_FILE_OPT = new Set(["-f", "--file", "--blob"]);
const CONFIG_WRITE_OPT = new Set(["--add", "--replace-all", "--unset", "--unset-all"]);
const CONFIG_STRUCTURAL_OPT = new Set(["-e", "--edit", "--rename-section", "--remove-section"]);
const CONFIG_READ_OPT = /^(?:--get(?:-all|-regexp|-urlmatch|-color|-colorbool)?|-l|--list)$/;
const CONFIG_SUBCOMMANDS = {
  get: "read",
  list: "read",
  set: "write",
  unset: "write",
  edit: "structural",
  "rename-section": "structural",
  "remove-section": "structural",
};

/** Why one `git ... config ...` word list is a forbidden write, or undefined. */
function gitConfigVerdict(words) {
  let i = words.findIndex((w) => w === "git" || w.endsWith("/git"));
  if (i < 0) return undefined;
  for (i++; i < words.length && words[i].startsWith("-"); i++) {
    if (GIT_OPT_WITH_ARG.has(words[i])) i++;
  }
  if (words[i] !== "config") return undefined;
  let kind = "read";
  let explicitRead = false;
  let file = false;
  const positional = [];
  const rest = words.slice(i + 1);
  for (let k = 0; k < rest.length; k++) {
    const w = rest[k];
    const flag = w.replace(/=.*/, "");
    if (CONFIG_STRUCTURAL_OPT.has(flag)) kind = "structural";
    else if (CONFIG_WRITE_OPT.has(flag)) kind = kind === "structural" ? kind : "write";
    else if (CONFIG_FILE_OPT.has(flag)) {
      file = true;
      if (!w.includes("=")) k++;
    } else if (CONFIG_OPT_WITH_ARG.has(w)) k++;
    else if (CONFIG_READ_OPT.test(flag)) explicitRead = true;
    else if (!w.startsWith("-")) positional.push(w);
  }
  if (positional.length > 0 && CONFIG_SUBCOMMANDS[positional[0]]) {
    const sub = CONFIG_SUBCOMMANDS[positional.shift()];
    if (sub === "read") explicitRead = true;
    else if (kind !== "structural") kind = sub;
  }
  if (kind === "read" && !explicitRead && positional.length >= 2) kind = "write";
  if (kind === "read") return undefined;
  if (kind === "structural") return "git config --edit/--rename-section/--remove-section";
  if (file) return "git config writes to an explicit file";
  if (!GIT_CONFIG_SAFE_KEY.test(positional[0] ?? "")) {
    return `git config ${positional[0] ?? "(no key)"}`;
  }
  return undefined;
}

/**
 * Reason when a (de-obfuscated) command writes a git config key that could
 * run a program on the host, else undefined. Commands are split at shell
 * operators so `x && git config ...` and `$(git config ...)` are seen.
 */
export function gitConfigWrite(command) {
  for (const segment of command.split(/[;&|\n`(){}]+/)) {
    const words = segment.trim().split(/\s+/).filter(Boolean);
    const verdict = gitConfigVerdict(words);
    if (verdict) return verdict;
  }
  return undefined;
}

// --- globs aimed at secrets -------------------------------------------------
// `cat .en[v]` or `cat auth.jso?` expand to a secret name at run time, so the
// literal-name regexes never see it. A glob word counts when it can match a
// secret name AND keeps literal text from that name's distinctive part
// (`*.json` matches auth.json but is not aimed at it; `au?h.json` is).
const GLOB_SECRETS = [
  [".env", ".env"],
  ["auth.json", "auth"],
  ["mcp-auth.json", "mcp-auth"],
  ["trust.json", "trust"],
  [".npmrc", ".npmrc"],
  [".netrc", ".netrc"],
  [".git-credentials", ".git-credentials"],
  ["credentials", "credentials"],
  ["id_rsa", "id_rsa"],
  ["id_dsa", "id_dsa"],
  ["id_ecdsa", "id_ecdsa"],
  ["id_ed25519", "id_ed25519"],
];
const GLOB_CHAR = /[*?[]/;

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");

/** Regex for one glob path component, or undefined if it is not a glob. */
function globComponentRe(component) {
  let re = "";
  for (let i = 0; i < component.length; i++) {
    const c = component[i];
    if (c === "*") re += ".*";
    else if (c === "?") re += ".";
    else if (c === "[") {
      const end = component.indexOf("]", i + 2);
      if (end < 0) {
        re += "\\[";
        continue;
      }
      let body = component.slice(i + 1, end);
      const negate = body[0] === "!" || body[0] === "^";
      if (negate) body = body.slice(1);
      re += `[${negate ? "^" : ""}${body.replace(/[\\\]^]/g, "\\$&")}]`;
      i = end;
    } else re += escapeRe(c);
  }
  try {
    return new RegExp(`^${re}$`, "i");
  } catch {
    return /^/; // unparsable glob: assume it can match (fail closed)
  }
}

// Literal characters of a glob component (bracket expressions removed).
const globLiterals = (component) =>
  component.replace(/\[[^\]]*\]?/g, "\0").split(/[*?\0]/).filter((run) => run.length > 0);

const sharesBigram = (runs, core) =>
  runs.some((run) => {
    const lower = run.toLowerCase();
    for (let i = 0; i + 2 <= lower.length; i++) {
      if (core.includes(lower.slice(i, i + 2))) return true;
    }
    return false;
  });

/** The secret name a glob word in `command` is aimed at, else undefined. */
export function globTargetsSecret(command) {
  for (const word of command.split(/[\s;&|<>()`=,{}]+/)) {
    if (!GLOB_CHAR.test(word)) continue;
    for (const component of word.split("/")) {
      if (!GLOB_CHAR.test(component)) continue;
      const re = globComponentRe(component);
      const runs = globLiterals(component);
      for (const [name, core] of GLOB_SECRETS) {
        // Like the shell, a leading wildcard never matches a leading dot.
        if (name.startsWith(".") && !component.startsWith(".")) continue;
        if (re.test(name) && sharesBigram(runs, core)) return name;
      }
    }
  }
  return undefined;
}

// Denied read paths: secrets, keys, host credential/config files, process
// environments. Case-insensitive: host bind mounts can be (macOS), so
// `.ENV` may well open `.env`.
export const DENY_READ =
  /^\/proc\/(?:[^/]+\/)+environ$|(^|\/)\.env(\.(?!example$)|$)|\.pem$|\.key$|(^|\/)auth\.json$|(^|\/)mcp-auth\.json$|(^|\/)trust\.json$|(^|\/)id_(rsa|dsa|ecdsa|ed25519|ed25519_sk|ecdsa_sk|eddsa)$|(^|\/)\.ssh(\/|$)|(^|\/)\.npmrc$|(^|\/)\.mcp-auth(\/|$)|(^|\/)credentials(\.|$)|(^|\/)private-keys-v1\.d(\/|$)|(^|\/)\.gitconfig$|(^|\/)\.composio(\/|$)|(^|\/)\.(?:git-credentials|netrc)$|(^|\/)\.(?:aws|kube)(\/|$)|(^|\/)\.docker\/config\.json$|(^|\/)[\w.-]*(?:_key|-key|_priv)$|(^|\/)[\w.-]*key$/i;
