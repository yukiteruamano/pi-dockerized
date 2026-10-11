// pi-dockerized security guard — built-in backstops.
//
// Regex deny-lists that stay active in every policy mode (including "off"):
// secret paths, destructive commands, Git host-execution vectors and Pi
// self-management. They back up the vendored pattern sets, which are
// replaceable data. Pure data, no I/O.

// Secret file names/paths referenced from a shell command (any tool).
export const SECRET_PATH_RE =
  /(^|[\/\s'"=:(])auth\.json([\s'"\/):;,]|$)|(^|[\/\s'"=:(])credentials([\s'"\/.=:;,]|$)|(^|[\/\s'"=:(])\.npmrc([\s'"\/):;,]|$)|(^|[\/\s'"=:(])\.mcp-auth([\/\s'"=:;,]|$)|(^|[\/\s'"=:(])\.gitconfig([\s'"\/):;,]|$)|(^|[\/\s'"=:(])\.composio([\/\s'"=:;,]|$)|(^|[\/\s'"=:(])\.(?:git-credentials|netrc|aws|kube)([\s'"\/):;,]|$)|(^|[\/\s'"=:(])\.docker\/config\.json([\s'"):;,]|$)|(^|[\/\s'"=:(])id_(rsa|dsa|ecdsa|ed25519|ed25519_sk|ecdsa_sk|eddsa)([\s'"\/):;,]|$)/i;

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
  // Git hooks/config and config-defined programs run on the host.
  /(?:>|>>)\s*['"]?[^\s'"|;&]*\.git\/(?:hooks\b|config\b)/,
  /\b(?:cp|mv|tee|ln|install|chmod|sed|truncate|dd|touch)\b[^\n|;&]*\.git\/(?:hooks\b|config\b)/,
  /(?:>|>>)\s*['"]?[^\s'"|;&]*\.gitmodules\b/,
  /\bgit\b[^\n|;&]*\b(?:core\.(?:hookspath|fsmonitor|sshcommand|editor|pager|askpass)|credential\.helper|gpg\.program)\b/i,
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
  /(^|\/)\.env(\.(?!example$)|$)|\.pem$|\.key$|(^|\/)auth\.json$|(^|\/)mcp-auth\.json$|(^|\/)trust\.json$|(^|\/)id_(rsa|dsa|ecdsa|ed25519|ed25519_sk|ecdsa_sk|eddsa)$|(^|\/)\.ssh(\/|$)|(^|\/)\.npmrc$|(^|\/)\.mcp-auth(\/|$)|(^|\/)credentials(\.|$)|(^|\/)private-keys-v1\.d(\/|$)|(^|\/)\.gitconfig$|(^|\/)\.composio(\/|$)|(^|\/)\.(?:git-credentials|netrc)$|(^|\/)\.(?:aws|kube)(\/|$)|(^|\/)\.docker\/config\.json$|(^|\/)[\w.-]*(?:_key|-key|_priv)$|(^|\/)[\w.-]*key$/;
