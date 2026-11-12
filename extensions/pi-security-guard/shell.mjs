// pi-dockerized security guard — shell text normalization.
//
// The deny-lists are regexes over the raw command text, so quoting tricks
// (`cat .e''nv`, `c"a"t`, `ca\t`, `$'\x2eenv'`, `cat {.env,}`) would hide a
// token from them. `shellVariants` returns the command plus the forms a shell
// would actually execute, and every pattern is tested against each one.
// `globForm` keeps the shell's notion of which glob characters are live, for
// the glob-aimed-at-a-secret check.
//
// Nested shells (`bash -c "…"`, `eval "…"`) are peeled by repeated passes and
// by `nestedCommands`, which hands their payload back for a full evaluation.
//
// Out of scope (documented residual): values assembled at run time
// (`a=.e; b=nv; cat $a$b`), non-empty command substitution and `base64 | sh`.
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

/** Replace every `$'...'` string with its decoded literal (bash stops at NUL). */
export function decodeAnsiC(cmd) {
  return cmd.replace(ANSI_C_RE, (_, body) => decodeAnsiCBody(body).split("\0")[0]);
}

/**
 * Drop expansions that are empty in an agent's shell, so they cannot split a
 * token: `$()`, empty backticks, `$@`/`$*` (no positional parameters), and
 * `$""` (a locale string). `.e$()nv` runs as `.env`.
 */
export function stripEmptyExpansions(cmd) {
  return cmd
    .replace(/\$\(\s*\)|`\s*`/g, "")
    .replace(/\$\{?[@*]\}?/g, "")
    .replace(/\$(?="")/g, "");
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

// De-obfuscation passes: each one peels a quoting layer, so a payload nested
// in `bash -c "…"` or `eval "…"` (quoted twice) is exposed by the second.
const MAX_DEQUOTE_PASSES = 4;

/** The command and the de-obfuscated forms to test it in (deduplicated). */
export function shellVariants(cmd) {
  const forms = [cmd];
  let current = cmd;
  for (let pass = 0; pass < MAX_DEQUOTE_PASSES; pass++) {
    const normalized = stripEmptyExpansions(normalizeShell(current));
    const decoded = stripEmptyExpansions(dequote(decodeAnsiC(normalized)));
    forms.push(normalized, decoded, expandBraces(decoded));
    if (decoded === current) break;
    current = decoded;
  }
  return [...new Set(forms)];
}

// `bash -c '…'`, `sh -xc "…"`, `eval "…"`: the payload is a command line of
// its own, with its own quoting and live globs.
const NESTED_SHELL_RE =
  /(?:^|[\s;&|(`{])(?:(?:[\w.-]*\/)*(?:ba|da|z|k|mk)?sh\s+(?:-[a-zA-Z]+\s+)*?-[a-zA-Z]*c[a-zA-Z]*|eval)\s+/g;

/**
 * Commands a shell would parse again: the arguments after `sh -c` or `eval`,
 * up to the next unquoted operator, with one quoting layer removed.
 */
export function nestedCommands(cmd) {
  const out = [];
  for (const match of cmd.matchAll(NESTED_SHELL_RE)) {
    let i = match.index + match[0].length;
    let quote = "";
    for (; i < cmd.length; i++) {
      const c = cmd[i];
      if (quote) {
        if (c === quote) quote = "";
        else if (c === "\\" && quote === '"') i++;
      } else if (c === "'" || c === '"') quote = c;
      else if (c === "\\") i++;
      else if (";&|\n".includes(c)) break;
    }
    out.push(dequote(cmd.slice(match.index + match[0].length, i)).trim());
  }
  return out;
}

/**
 * The de-obfuscated command with only live glob characters left (quoted,
 * escaped and `$'...'` ones are masked), braces expanded.
 */
export function globForm(cmd) {
  const ansi = stripEmptyExpansions(normalizeShell(cmd)).replace(ANSI_C_RE, (_, body) =>
    maskGlobs(decodeAnsiCBody(body).split("\0")[0]),
  );
  return expandBraces(dequote(ansi, { masked: true }));
}
