#!/bin/bash
# Golden tests (SPEC 10): each tests/spec/NAME.dksh runs with its stdout,
# stderr and exit status compared byte for byte against NAME.out, NAME.err
# and NAME.status. Every test is also run through `dksh -n` to make sure
# parse-only mode agrees with execution.
#
# usage: tests/run_spec.sh [path/to/dksh] [--bless]
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
dksh="$(readlink -f "${1:-$root/zig-out/bin/dksh}")"
bless=0
[ "${2:-}" = "--bless" ] && bless=1
cd "$root/tests/spec" || exit 1
export HOME=/nonexistent PATH=/usr/bin:/bin TZ=UTC LC_ALL=C
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
for t in *.dksh; do
    n="${t%.dksh}"
    "$dksh" "$t" >"$tmp/out" 2>"$tmp/err"
    echo $? >"$tmp/status"
    if [ $bless = 1 ]; then
        cp "$tmp/out" "$n.out"; cp "$tmp/err" "$n.err"; cp "$tmp/status" "$n.status"
        continue
    fi
    ok=1
    for k in out err status; do
        if ! cmp -s "$tmp/$k" "$n.$k"; then
            ok=0
            echo "FAIL $n: $k differs"
            diff "$tmp/$k" "$n.$k" | head -6
        fi
    done
    # Parse-only mode must agree with the real run on syntax and name errors.
    "$dksh" -n "$t" >/dev/null 2>&1; nstat=$?
    status="$(cat "$tmp/status")"
    if [ "$status" = "2" ] && [ "$nstat" = "0" ]; then
        ok=0; echo "FAIL $n: dksh -n accepted a script the run rejected"
    fi
    if [ "$status" != "2" ] && [ "$nstat" != "0" ]; then
        ok=0; echo "FAIL $n: dksh -n reported errors but the run did not"
    fi
    if [ $ok = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
[ $bless = 1 ] && { echo "blessed"; exit 0; }
echo "spec tests: $pass passed, $fail failed"
[ $fail = 0 ]
