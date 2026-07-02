#!/usr/bin/env bash
# JSONTestSuite driver — builds the checker once, sweeps the corpus.
# y_ files MUST parse AND round-trip (`dumps ∘ loads` idempotence — the
# 95/95 gate), n_ files MUST be rejected, i_ files may do either (their
# verdicts are reported for the record). Exit 0 iff zero failures.
set -u
cd "$(dirname "$0")/.."

if [[ ! -d references/JSONTestSuite/test_parsing ]]; then
    echo "JSONTestSuite corpus missing — clone it first:" >&2
    echo "  git clone https://github.com/nst/JSONTestSuite references/JSONTestSuite" >&2
    exit 1
fi

mkdir -p .build
pixi run mojo build -I . tests/suite_checker.mojo -o .build/suite_checker || exit 1

pass=0
fail=0
roundtrip=0
impl_accept=0
impl_reject=0
failures=()

for f in references/JSONTestSuite/test_parsing/*.json; do
    base=$(basename "$f")
    out=$(.build/suite_checker "$PWD/$f" 2>/dev/null)
    case "$base" in
        y_*)
            if [[ "$out" == "ACCEPT" ]]; then
                ((pass++))
                rt=$(.build/suite_checker "$PWD/$f" roundtrip 2>/dev/null)
                if [[ "$rt" == "ACCEPT" ]]; then ((roundtrip++)); else
                    ((fail++)); failures+=("ROUNDTRIP $base -> $rt")
                fi
            else
                ((fail++)); failures+=("MUST-ACCEPT $base -> $out")
            fi ;;
        n_*)
            if [[ "$out" == "REJECT" ]]; then ((pass++)); else
                ((fail++)); failures+=("MUST-REJECT $base -> $out")
            fi ;;
        i_*)
            if [[ "$out" == "ACCEPT" ]]; then ((impl_accept++)); else ((impl_reject++)); fi ;;
    esac
done

echo "RESULT pass=$pass fail=$fail roundtrip=$roundtrip impl_accept=$impl_accept impl_reject=$impl_reject"
if ((fail > 0)); then
    printf '%s\n' "${failures[@]}" | head -40
    exit 1
fi
