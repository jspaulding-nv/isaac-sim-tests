#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

pattern="(/(home|localhome)/[^/[:space:]]+"
pattern+="|10\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}"
pattern+="|192\\.168\\.[0-9]{1,3}\\.[0-9]{1,3}"
pattern+="|172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9]{1,3}\\.[0-9]{1,3}"
pattern+="|[[:alnum:]._%+-]+@[[:alnum:].-]+\\.[[:alpha:]]{2,}"
pattern+="|([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}"
pattern+="|GPU-[[:xdigit:]-]{16,}"
pattern+="|[[:xdigit:]]{8}-[[:xdigit:]]{4}-[1-5][[:xdigit:]]{3}-[89ab][[:xdigit:]]{3}-[[:xdigit:]]{12}"
pattern+="|[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\\.[0-7]"
pattern+="|(f[cd][[:xdigit:]]{0,2}|fe[89ab][[:xdigit:]]):[[:xdigit:]:]+"
pattern+="|-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"
pattern+="|authorization[\"']?[[:space:]]*:[[:space:]]*[\"']?bearer[[:space:]]+[^\"'[:space:]]+"
pattern+="|(token|password|secret|api[_-]?key)[\"']?[[:space:]]*[:=][[:space:]]*[^[:space:]]+)"

forbidden_tracked="$(git ls-files -ci --exclude-standard)"

if [[ -n "$forbidden_tracked" ]]; then
    printf 'Ignored private or generated paths are tracked:\n%s\n' \
        "$forbidden_tracked" >&2
    exit 1
fi

scan_tree() {
    local search_pattern="$1"

    if command -v rg >/dev/null 2>&1; then
        rg -n -i --hidden \
            --glob '!.git/**' \
            --glob '!scripts/audit_public_tree.sh' \
            "$search_pattern" .
        return
    fi

    local -a public_files=()
    mapfile -d '' -t public_files < <(
        git ls-files -z --cached --others --exclude-standard -- \
            . ':(exclude)scripts/audit_public_tree.sh'
    )

    if [[ "${#public_files[@]}" -eq 0 ]]; then
        return 1
    fi

    grep -n -I -i -E -- "$search_pattern" "${public_files[@]}"
}

scan_index() {
    local search_pattern="$1"

    git grep --cached -n -I -i -E \
        "$search_pattern" \
        -- . ':(exclude)scripts/audit_public_tree.sh'
}

set +e
scan_tree "$pattern"
tree_status=$?
scan_index "$pattern"
index_status=$?
set -e

if [[ "$tree_status" -eq 0 || "$index_status" -eq 0 ]]; then
    printf 'Potential private identifier or credential found. Review the matches above.\n' >&2
    exit 1
fi
if [[ "$tree_status" -gt 1 ]]; then
    exit "$tree_status"
fi
if [[ "$index_status" -gt 1 ]]; then
    exit "$index_status"
fi

if [[ -n "${EXTRA_DENY_REGEX:-}" ]]; then
    set +e
    scan_tree "$EXTRA_DENY_REGEX"
    tree_status=$?
    scan_index "$EXTRA_DENY_REGEX"
    index_status=$?
    set -e

    if [[ "$tree_status" -eq 0 || "$index_status" -eq 0 ]]; then
        printf 'A caller-supplied deny term was found.\n' >&2
        exit 1
    fi
    if [[ "$tree_status" -gt 1 ]]; then
        exit "$tree_status"
    fi
    if [[ "$index_status" -gt 1 ]]; then
        exit "$index_status"
    fi
fi

printf 'Public-tree privacy scan: PASS\n'
