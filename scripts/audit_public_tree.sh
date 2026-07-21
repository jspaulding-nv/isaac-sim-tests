#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

pattern='(/home/[^/[:space:]]+|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}|(token|password|secret)[[:space:]]*[:=][[:space:]]*[^[:space:]]+)'

scan_tree() {
    local search_pattern="$1"

    if command -v rg >/dev/null 2>&1; then
        rg -n -i --hidden \
            --glob '!.git/**' \
            --glob '!output/**' \
            --glob '!scripts/audit_public_tree.sh' \
            "$search_pattern" .
    else
        grep -R -I -n -i -E \
            --exclude-dir=.git \
            --exclude-dir=output \
            --exclude=audit_public_tree.sh \
            -- "$search_pattern" .
    fi
}

set +e
scan_tree "$pattern"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
    printf 'Potential private identifier or credential found. Review the matches above.\n' >&2
    exit 1
fi
if [[ "$status" -gt 1 ]]; then
    exit "$status"
fi

if [[ -n "${EXTRA_DENY_REGEX:-}" ]] && scan_tree "$EXTRA_DENY_REGEX"; then
    printf 'A caller-supplied deny term was found.\n' >&2
    exit 1
fi

printf 'Public-tree privacy scan: PASS\n'
