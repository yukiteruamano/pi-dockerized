#!/bin/bash
set -e

# Refresh the vendored policy pattern sets (policies/*.json) from the
# upstream opencode-policy npm package: fetch a release, show exactly what changed, and only
# with --apply copy the files, bump policies/VERSION and run the guard tests.
#
# Usage: scripts/refresh-policies.sh [--version X] [--from DIR|TARBALL] [--apply] [--no-verify]
#   --version X   upstream release to fetch (default: latest)
#   --from PATH   use an unpacked directory or .tgz instead of fetching
#   --apply       write the changes (default: report only)
#   --no-verify   skip the registry integrity check (not recommended)
#
# After --apply, bump GUARD_VERSION in extensions/pi-security-guard/policy.mjs
# (behavior changed) and update policies/README.md if the upstream version moved.

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
POLICIES_DIR="$REPO_ROOT/policies"
# allow-patterns.json is this project's own allowlist, not part of the upstream package.
FILES=(unsafe-tool-patterns.json prompt-injection-patterns.json)

version="latest"
source_path=""
apply=false
verify=true

usage() {
    sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
    --version)
        version="${2:?--version needs a value}"
        shift
        ;;
    --from)
        source_path="${2:?--from needs a path}"
        shift
        ;;
    --apply) apply=true ;;
    --verify) verify=true ;;
    --no-verify) verify=false ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "error: unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
done

if ! [[ "$version" =~ ^(latest|[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?)$ ]]; then
    echo "error: invalid --version '$version' (use latest or x.y.z)" >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# Unpack the upstream release (or take the directory given) into $work/src.
mkdir -p "$work/src"
if [ -z "$source_path" ]; then
    command -v npm >/dev/null 2>&1 || {
        echo "error: npm is required to fetch the package (or pass --from)" >&2
        exit 1
    }
    (cd "$work" && npm pack "opencode-policy@$version" --silent >/dev/null)
    tgz=$(echo "$work"/opencode-policy-*.tgz)
    resolved=$(npm view "opencode-policy@$version" version 2>/dev/null) || resolved=""
    if [ -n "$resolved" ]; then
        pinned="$(cat "$POLICIES_DIR/.upstream-version" 2>/dev/null || true)"
        if [ -n "$pinned" ] && [ "$pinned" != "$resolved" ]; then
            echo "Upstream moved since the last refresh: $pinned -> $resolved"
        elif [ -z "$pinned" ]; then
            echo "Upstream version: $resolved"
        fi
    fi
    if [ "$verify" = true ]; then
        want=$(npm view "opencode-policy@$version" dist.integrity 2>/dev/null) || want=""
        if [ -z "$want" ]; then
            echo "error: cannot read dist.integrity for opencode-policy@$version; refusing unverified fetch (use --no-verify to override)" >&2
            exit 1
        fi
        got=$(node --input-type=module -e '
            import { createHash } from "node:crypto";
            import { readFileSync } from "node:fs";
            const b64 = createHash("sha512").update(readFileSync(process.argv[1])).digest("base64");
            process.stdout.write("sha512-" + b64);
        ' "$tgz") || {
            echo "error: cannot hash the fetched tarball" >&2
            exit 1
        }
        if [ "$got" != "$want" ]; then
            echo "error: integrity mismatch for $tgz (registry says $want)" >&2
            exit 1
        fi
        echo "Verified $tgz against the registry."
    fi
    tar -xzf "$work"/opencode-policy-*.tgz -C "$work/src"
elif [ -d "$source_path" ]; then
    cp -R "$source_path"/. "$work/src/"
elif [ -f "$source_path" ]; then
    tar -xzf "$source_path" -C "$work/src"
else
    echo "error: --from path not found: $source_path" >&2
    exit 1
fi

# Locate each file wherever the package keeps it, and validate its shape.
changed=0
for name in "${FILES[@]}"; do
    found="$(find "$work/src" -name "$name" -type f | head -n 1)"
    if [ -z "$found" ]; then
        echo "error: $name not found in the upstream package" >&2
        exit 1
    fi
    node --input-type=module -e '
        import { readFileSync } from "node:fs";
        const rules = JSON.parse(readFileSync(process.argv[1], "utf8"));
        if (!Array.isArray(rules)) throw new Error("not a JSON array");
        for (const r of rules) {
            if (typeof r.id !== "string" || typeof r.pattern !== "string") throw new Error("rule without id/pattern");
            new RegExp(r.pattern, r.flags ?? "i");
        }
    ' "$found" || {
        echo "error: $name is not a valid rule set" >&2
        exit 1
    }

    if cmp -s "$found" "$POLICIES_DIR/$name"; then
        echo "= $name: unchanged"
        continue
    fi
    changed=$((changed + 1))
    echo "~ $name: CHANGED"
    node --input-type=module -e '
        import { readFileSync } from "node:fs";
        const ids = (f) => new Map(JSON.parse(readFileSync(f, "utf8")).map((r) => [r.id, r.pattern]));
        const [oldRules, newRules] = [ids(process.argv[1]), ids(process.argv[2])];
        const added = [...newRules.keys()].filter((i) => !oldRules.has(i));
        const removed = [...oldRules.keys()].filter((i) => !newRules.has(i));
        const edited = [...newRules.keys()].filter((i) => oldRules.has(i) && oldRules.get(i) !== newRules.get(i));
        console.log(`    rules: ${oldRules.size} -> ${newRules.size}`);
        if (added.length) console.log("    added:   " + added.join(", "));
        if (removed.length) console.log("    removed: " + removed.join(", "));
        if (edited.length) console.log("    edited:  " + edited.join(", "));
    ' "$POLICIES_DIR/$name" "$found"
    if [ "$apply" = true ]; then
        cp "$found" "$POLICIES_DIR/$name"
    fi
done

if [ "$changed" -eq 0 ]; then
    echo "Policies are up to date."
    exit 0
fi

if [ "$apply" != true ]; then
    echo
    echo "Review the changes above, then re-run with --apply."
    exit 0
fi

current="$(tr -d '[:space:]' <"$POLICIES_DIR/VERSION")"
echo "$((current + 1))" >"$POLICIES_DIR/VERSION"
if [ -n "${resolved:-}" ]; then
    echo "$resolved" >"$POLICIES_DIR/.upstream-version"
fi
echo
echo "Applied. policies/VERSION: $current -> $((current + 1))"

# Renamed or removed IDs would leave stale entries in balanced-excluded.json;
# the test checks exactly that, along with the rest of the guard behavior.
node "$REPO_ROOT/tests/security-guard.test.mjs"
echo "Next: bump GUARD_VERSION in extensions/pi-security-guard/policy.mjs and update policies/README.md."
