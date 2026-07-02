#!/usr/bin/env bash
# json5-tests driver — builds the checker once, sweeps the suite.
# Convention (the suite's README): *.json5 and *.json MUST parse as JSON5;
# *.js (ES5-legal, JSON5-illegal) and *.txt MUST be rejected. `todo/` is
# skipped, as upstream marks it unresolved. Exit 0 iff zero failures.
set -u
cd "$(dirname "$0")/.."

if [[ ! -d references/json5-tests ]]; then
    echo "json5-tests corpus missing — clone it first:" >&2
    echo "  git clone https://github.com/json5/json5-tests references/json5-tests" >&2
    exit 1
fi

mkdir -p .build
pixi run mojo build -I . tests/json5_checker.mojo -o .build/json5_checker || exit 1

pass=0
fail=0
failures=()

for f in references/json5-tests/*/*; do
    case "$f" in
        */todo/*) continue ;;
    esac
    base=$(basename "$f")
    out=$(.build/json5_checker "$PWD/$f" 2>/dev/null)
    case "$base" in
        *.json5|*.json)
            if [[ "$out" == "ACCEPT" ]]; then ((pass++)); else
                ((fail++)); failures+=("MUST-ACCEPT $base -> $out")
            fi ;;
        *.js|*.txt)
            if [[ "$out" == "REJECT" ]]; then ((pass++)); else
                ((fail++)); failures+=("MUST-REJECT $base -> $out")
            fi ;;
    esac
done

echo "RESULT pass=$pass fail=$fail"
if ((fail > 0)); then
    printf '%s\n' "${failures[@]}" | head -40
    exit 1
fi
