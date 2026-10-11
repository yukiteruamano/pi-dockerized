# Security pattern data (ported)

The `*.json` files in this directory are the rule sets from
**[opencode-policy](https://github.com/tjvjk/opencode-policy)** (`opencode-policy@0.1.4`
on npm), vendored verbatim:

- `unsafe-tool-patterns.json` — unsafe shell/tool patterns (denies secret exposure,
  exfiltration, reverse shells, destructive commands, cross-workspace access, …)
- `prompt-injection-patterns.json` — instruction-override / prompt-injection patterns
- `allow-patterns.json` — local allowlist (e.g. `.env.example`)

Upstream ships them for the OpenCode **V1** plugin API. Instead of depending on
that package, the Pi security extension in
`extensions/pi-security-guard/policy.mjs` evaluates them with the same
first-match semantics (`new RegExp(pattern, flags ?? "i")`).

At image build time the Dockerfile copies `unsafe-tool-patterns.json`,
`prompt-injection-patterns.json` and `allow-patterns.json` into
`extensions/pi-security-guard/policies/` inside the image, next to the extension
that loads them read-only.

To refresh the rules, run `scripts/refresh-policies.sh [--version X]`: it fetches
the upstream package, validates every rule, and shows what was added, removed
or edited per file. Re-run with `--apply` to write the files and bump `VERSION`
(a plain integer, shown by `pi-dockerized version`); it then runs the guard
tests, which also fail when `extensions/pi-security-guard/balanced-excluded.json`
lists an ID that no longer exists. Bump `GUARD_VERSION` in
`extensions/pi-security-guard/policy.mjs` (CI requires it), update the upstream
version above if it moved, and rebuild the image (`pi-dockerized build`).
`allow-patterns.json` is this project's own allowlist, not part of upstream, and
is never touched by the script.

## License / attribution

See `LICENSE.opencode-policy` (MIT License, Copyright (c) 2026, tjvjk). Pattern
research adapted in part from `vakovalskii/topsha` (per upstream README).
