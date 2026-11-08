// pi-dockerized security guard — shell text normalization.
//
// The deny-lists are regexes over the raw command text, so quoting tricks
// (`cat .e''nv`, `c"a"t`, `ca\t`, `$'\x2eenv'`, `cat {.env,}`) would hide a
// token from them. `shellVariants` returns the command plus the forms a shell
// would actually execute, and every pattern is tested against each one.
// `globForm` keeps the shell's notion of which glob characters are live, for
// the glob-aimed-at-a-secret check.
//
// Out of scope (documented residual): values assembled at run time
// (`a=.e; b=nv; cat $a$b`), command substitution and `base64 | sh` stagers.
// A regex cannot resolve those; the container boundary has to.

/** Normalize `${IFS}`/`$IFS` and tab/newline ANSI-C escapes back to spaces. */
export function normalizeShell(cmd) {
  return cmd
    .replace(/\$\{IFS[^}]*\}/gi, " ")
    .replace(/\$IFS(?![A-Za-z0-9_])/g, " ")
    .replace(/\$'\\t'/g, " ")
    .replace(/\$'\\n'/g, " ");
}

/** Collapse runs of blanks: the quadratic matchers scale with line length. */
export function compactBlanks(cmd) {
  return cmd.replace(/[ \t\f\v]{2,}/g, " ");
}

const SIMPLE_ESCAPES = {
  n: "\n",
  t: "\t",
  r: "\r",
  a: "\x07",
  b: "\b",
  f: "\f",
  v: "\v",
  e: "\x1b",
  E: "\x1b",
  "\\": "\\",
  "'": "'",
  '"': '"',
};

// Decode the body of one `$'...'` string (bash ANSI-C quoting).
function decodeAnsiCBody(body) {
  return body.replace(
    /\\(?:x([0-9a-fA-F]{1,2})|u([0-9a-fA-F]{1,4})|([0-7]{1,3})|(.))/gs,
    (_, hex, uni, oct, ch) => {
      if (hex !== undefined) return String.fromCharCode(parseInt(hex, 16));
      if (uni !== undefined) return String.fromCharCode(parseInt(uni, 16));
      if (oct !== undefined) return String.fromCharCode(parseInt(oct, 8) & 0xff);
      return SIMPLE_ESCAPES[ch] ?? "\\" + ch;
    },
  );
}

const ANSI_C_RE = /\$'((?:[^'\\]|\\.)*)'/gs;

/** Replace every `$'...'` string with its decoded literal. */
export function decodeAnsiC(cmd) {
  return cmd.replace(ANSI_C_RE, (_, body) => decodeAnsiCBody(body));
}

// Stand-in for a glob character the shell treats literally (quoted/escaped).
const GLOB_MASK = "\x01";
const maskGlobs = (s) => s.replace(/[*?[]/g, GLOB_MASK);

/**
 * Remove quoting the way a shell does when it builds a word: `''`/`""` pairs
 * vanish, quoted text loses its quotes, and `\x` becomes `x`. Whitespace and
 * operators are left alone, so segment boundaries stay where they were.
 * With `masked`, quoted or escaped glob characters become GLOB_MASK, so only
 * the live ones remain.
 */
export function dequote(cmd, { masked = false } = {}) {
  const lit = masked ? maskGlobs : (s) => s;
  let out = "";
  let quote = "";
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd[i];
    if (quote === "'") {
      if (c === "'") quote = "";
      else out += lit(c);
    } else if (quote === '"') {
      if (c === '"') quote = "";
      else if (c === "\\" && i + 1 < cmd.length && '"\\$`'.includes(cmd[i + 1])) {
        out += cmd[++i];
      } else out += lit(c);
    } else if (c === "'" || c === '"') {
      quote = c;
    } else if (c === "\\" && i + 1 < cmd.length) {
      const next = cmd[++i];
      if (next !== "\n") out += lit(next); // backslash-newline is a line continuation
    } else {
      out += c;
    }
  }
  return out;
}

// The lookbehind starts the prefix at a word start only (else quadratic).
const BRACE_RE = /(?<![^\s{}])([^\s{}]*)\{([^{}\s]*,[^{}\s]*)\}([^\s{}]*)/;
const MAX_BRACE_PASSES = 8;

/**
 * Expand simple brace lists the way the shell does (`{.env,}` -> `.env`,
 * `a{b,c}d` -> `abd acd`). Nested braces expand across passes; growth is
 * bounded so a crafted command cannot blow up the evaluation.
 */
export function expandBraces(cmd) {
  let out = cmd;
  const limit = cmd.length * 4 + 1024;
  for (let pass = 0; pass < MAX_BRACE_PASSES; pass++) {
    const next = out.replace(BRACE_RE, (_, pre, list, post) =>
      list
        .split(",")
        .map((alt) => pre + alt + post)
        .join(" "),
    );
    if (next === out || next.length > limit) break;
    out = next;
  }
  return out;
}

/** The command and the de-obfuscated forms to test it in (deduplicated). */
export function shellVariants(cmd) {
  const normalized = normalizeShell(cmd);
  const decoded = dequote(decodeAnsiC(normalized));
  return [...new Set([cmd, normalized, decoded, expandBraces(decoded)])];
}

/**
 * The de-obfuscated command with only live glob characters left (quoted,
 * escaped and `$'...'` ones are masked), braces expanded.
 */
export function globForm(cmd) {
  const ansi = normalizeShell(cmd).replace(ANSI_C_RE, (_, body) =>
    maskGlobs(decodeAnsiCBody(body)),
  );
  return expandBraces(dequote(ansi, { masked: true }));
}
