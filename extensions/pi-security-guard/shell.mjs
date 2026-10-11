// pi-dockerized security guard — shell text normalization.
//
// The deny-lists are regexes over the raw command text, so quoting tricks
// (`cat .e''nv`, `c"a"t`, `ca\t`, `$'\x2eenv'`) would hide a token from them.
// `shellVariants` returns the command plus the forms a shell would actually
// execute, and every pattern is tested against each one.
//
// Out of scope (documented residual): values assembled at run time
// (`a=.e; b=nv; cat $a$b`), command substitution and `base64 | sh` stagers.
// A regex cannot resolve those; the container boundary has to.

/** Normalize `${IFS}` and tab/newline ANSI-C escapes back to spaces. */
export function normalizeShell(cmd) {
  return cmd
    .replace(/\$\{IFS[^}]*\}/gi, " ")
    .replace(/\$'\\t'/g, " ")
    .replace(/\$'\\n'/g, " ");
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

/** Replace every `$'...'` string with its decoded literal. */
export function decodeAnsiC(cmd) {
  return cmd.replace(/\$'((?:[^'\\]|\\.)*)'/gs, (_, body) => decodeAnsiCBody(body));
}

/**
 * Remove quoting the way a shell does when it builds a word: `''`/`""` pairs
 * vanish, quoted text loses its quotes, and `\x` becomes `x`. Whitespace and
 * operators are left alone, so segment boundaries stay where they were.
 */
export function dequote(cmd) {
  let out = "";
  let quote = "";
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd[i];
    if (quote === "'") {
      if (c === "'") quote = "";
      else out += c;
    } else if (quote === '"') {
      if (c === '"') quote = "";
      else if (c === "\\" && i + 1 < cmd.length && '"\\$`'.includes(cmd[i + 1])) {
        out += cmd[++i];
      } else out += c;
    } else if (c === "'" || c === '"') {
      quote = c;
    } else if (c === "\\" && i + 1 < cmd.length) {
      const next = cmd[++i];
      if (next !== "\n") out += next; // backslash-newline is a line continuation
    } else {
      out += c;
    }
  }
  return out;
}

/** The command and the de-obfuscated forms to test it in (deduplicated). */
export function shellVariants(cmd) {
  const normalized = normalizeShell(cmd);
  return [...new Set([cmd, normalized, dequote(decodeAnsiC(normalized))])];
}
