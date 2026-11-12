// pi-dockerized security guard — strict-mode tool scopes.
//
// `setting.allowed_tools` entries (`name:scope+scope`) restrict a tool this
// policy does not model to URLs (by host and path) and absolute paths (by
// prefix). Pure, no I/O; policy.mjs re-exports the public functions.

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

/**
 * Scope entries in `allowedTools` for one unknown tool. Entries are `name`
 * (or `name:*`, same thing: the tool is allowed, its values still scanned)
 * or `name:scope1+scope2` (allowed only inside a scope, see inScope).
 * Plain names keep working exactly as before. Returns null when the
 * tool is not listed, "*" for unrestricted, or the scope array (last scoped
 * entry wins, but a later unrestricted entry still overrides it).
 */
export function allowedScope(allowedTools, tool) {
  let scoped = null;
  for (const raw of allowedTools) {
    const entry = String(raw).trim();
    if (entry === tool) return "*";
    if (entry.startsWith(tool + ":")) {
      const scopes = entry
        .slice(tool.length + 1)
        .split("+")
        .map((s) => s.trim())
        .filter(Boolean);
      if (scopes.length === 0 || scopes.includes("*")) return "*";
      scoped = scopes;
    }
  }
  return scoped;
}

const parseUrl = (value) => {
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(value)) return undefined;
  try {
    return new URL(value);
  } catch {
    return undefined;
  }
};

// Path prefix on a segment boundary: /data covers /data and /data/x, never
// /database.
const underPath = (path, prefix) => {
  const base = prefix.replace(/\/+$/, "");
  return path === base || path.startsWith(base + "/") || base === "";
};

/**
 * True when a URL value lies inside one scope. A scope is `host[/path]`
 * (`github.com/myorg`; subdomains of the host count), a full URL, or an
 * absolute path (matches nothing here). Only host and path are compared, so
 * the scope text in a query string or fragment does not count.
 */
function urlInScope(url, scope) {
  const parsed = parseUrl(scope) ?? parseUrl("https://" + scope);
  if (!parsed || scope.startsWith("/")) return false;
  const host = url.hostname.toLowerCase();
  const scopeHost = parsed.hostname.toLowerCase();
  if (host !== scopeHost && !host.endsWith("." + scopeHost)) return false;
  if (parseUrl(scope) && parsed.protocol !== url.protocol) return false;
  return underPath(normalizeLexical(url.pathname), normalizeLexical(parsed.pathname));
}

/**
 * Whether a tool call stays inside its scopes: every URL and every absolute
 * path among its values must be inside one scope, and at least one value must
 * be (URLs and paths by the rules above, other values by equality or a
 * `scope/` prefix). Free text (queries, messages) is otherwise unconstrained.
 */
// `evil.example/x` or `github.com`: a tool may well fetch a bare host.
const HOST_LIKE = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+(?::\d+)?(?:[/?#]\S*)?$/i;
const EMBEDDED_URL = /[a-z][a-z0-9+.-]*:\/\/[^\s'"<>]*/gi;

/**
 * The URLs a value points at: itself (also schemeless, host-shaped) or, for
 * free text, every `scheme://` inside it. null when one cannot be parsed.
 */
function valueUrls(value) {
  const url = parseUrl(value) ?? (HOST_LIKE.test(value) ? parseUrl("https://" + value) : undefined);
  if (url) return [url];
  if (!value.includes("://")) return [];
  const urls = (value.match(EMBEDDED_URL) ?? []).map(parseUrl);
  return urls.length > 0 && urls.every(Boolean) ? urls : null;
}

export function inScope(scopes, strings) {
  let matched = false;
  for (const raw of strings) {
    if (typeof raw !== "string") continue;
    const value = raw.trim();
    if (value === "") continue;
    const urls = valueUrls(value);
    if (urls === null) return false; // an unparsable URL: fail closed
    if (urls.length > 0) {
      if (!urls.every((url) => scopes.some((s) => urlInScope(url, s)))) return false;
      matched = true;
    } else if (value.startsWith("/")) {
      const path = normalizeLexical(value);
      if (!scopes.some((s) => s.startsWith("/") && underPath(path, normalizeLexical(s)))) {
        return false;
      }
      matched = true;
    } else if (scopes.some((s) => value === s || value.startsWith(s + "/"))) {
      matched = true;
    }
  }
  return matched;
}
