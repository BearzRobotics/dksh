#!/bin/bash
# Command-line option tests (SPEC 4.1).
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
d="$(readlink -f "${1:-$root/zig-out/bin/dksh}")"
fail=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi
}
check "--version" "dksh 0.0.1 (Unicode 16.0.0)" "$("$d" --version)"
check "-v" "$("$d" --version)" "$("$d" -v)"
check "-c with args" '["one", "two"]' "$("$d" -c 'print(args)' one two)"
check "-x traces expanded argv" "+ echo 'a b' 'it'\\''s'" "$("$d" -x -c 'var f = "a b"
echo $f "it'"'"'s"' 2>&1 >/dev/null)"
check "-x does not change stdout" "a b" "$("$d" -x -c 'var f = "a b"
echo $f' 2>/dev/null)"
check "clustered -xc" "+ echo hi" "$("$d" -xc 'echo hi' 2>&1 >/dev/null)"
check "+e continues after failure" "survived" "$("$d" +e -c 'false
echo survived')"
"$d" -e -c 'false' >/dev/null 2>&1; check "-e stops on failure (status)" "1" "$?"
"$d" -n -c 'x = 1' >/dev/null 2>&1; check "-n reports errors (status)" "2" "$?"
check "-n runs nothing" "" "$("$d" -n -c 'echo ran')"
check "--dump-ast prints the tree" '(var x 1)  ; 1:1' "$("$d" --dump-ast -c 'var x = 1')"
check "--dump-ast runs nothing" "" "$("$d" --dump-ast -c 'echo ran' | grep -c '^ran$' | sed 's/^0$//')"
check "--tree draws an ASCII tree" "$(printf 'Program\n`-- var x   [1:1]\n    `-- +\n        |-- 1\n        `-- 2')" "$("$d" --tree -c 'var x = 1 + 2')"
"$d" --tree -c 'x = 1' >/dev/null 2>&1; check "--tree reports errors (status)" "2" "$?"
"$d" -z >/dev/null 2>&1; check "unknown option (status)" "2" "$?"
"$d" -c >/dev/null 2>&1; check "-c without argument (status)" "2" "$?"
check "-i reads commands from a pipe" "piped" "$(printf 'echo piped\nexit\n' | "$d" -i 2>&1 | grep -o piped | head -1)"
"$d" /nonexistent.dksh >/dev/null 2>&1; check "missing script (status)" "127" "$?"
exit $fail
