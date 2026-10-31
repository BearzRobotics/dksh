#!/bin/bash
# Command-line option tests (SPEC 4.1).
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
d="$(readlink -f "${1:-$root/zig-out/bin/dksh}")"
fail=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi
}
want_version="$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' "$root/build.zig.zon")"
check "--version matches build.zig.zon" "dksh $want_version (Unicode 16.0.0)" "$("$d" --version)"
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
# Shebang handling: a script naming another interpreter belongs to that interpreter.
tmp="$(mktemp -d)"
printf '#!/usr/bin/bash\narr=(1 2 3)\necho "bash ${#arr[@]} $1"\n' > "$tmp/b.sh"
check "bash shebang runs under bash" "bash 3 x" "$("$d" "$tmp/b.sh" x)"
printf '#!/usr/bin/env bash\nexit 7\n' > "$tmp/e.sh"
"$d" "$tmp/e.sh"; check "env bash shebang passes the exit status" "7" "$?"
chmod +x "$tmp/b.sh"
check "executable bash script runs as a command" "bash 3 y" "$("$d" -c "$tmp/b.sh y")"
printf '#!/usr/bin/env dksh\nprint("dksh", args)\n' > "$tmp/d.dksh"
check "env dksh shebang stays dksh" 'dksh ["z"]' "$(PATH="$(dirname "$d"):$PATH" "$d" "$tmp/d.dksh" z)"
"$d" -n "$tmp/b.sh" >/dev/null 2>&1; check "-n refuses to check a bash script (status)" "2" "$?"
printf '#!/no/such/interp\n' > "$tmp/m.sh"; "$d" "$tmp/m.sh" >/dev/null 2>&1; check "missing interpreter (status)" "127" "$?"
# Login shell: the profile is read in every mode, but not for plain -c or checks.
lh="$tmp/home"; mkdir -p "$lh/.config/dksh"
printf 'env.FROM_PROFILE = "yes"\n' > "$lh/.config/dksh/profile.dksh"
lenv() { HOME="$lh" XDG_CONFIG_HOME="$lh/.config" "$@"; }
check "-l -c reads profile.dksh" "yes" "$(lenv "$d" -l -c 'print(env.FROM_PROFILE)')"
check "argv[0] starting with - is a login shell" "yes" "$(lenv bash -c "exec -a -dksh '$d' -c 'print(env.FROM_PROFILE)'")"
check "-l runs a script after the profile" "yes" "$(printf 'print(env.FROM_PROFILE)\n' > "$tmp/ls.dksh"; lenv "$d" -l "$tmp/ls.dksh")"
check "plain -c does not read the profile" "null" "$(lenv "$d" -c 'print(env.FROM_PROFILE)')"
check "-l -n does not execute the profile" "" "$(printf 'echo PROFILE-RAN\n' > "$lh/.config/dksh/profile.dksh"; lenv "$d" -l -n -c 'print(1)')"
check "ulimit sets and shows a soft limit" "256" "$("$d" -c 'ulimit -Sn 256
ulimit -Sn')"
"$d" -c 'ulimit -z' >/dev/null 2>&1; check "ulimit rejects unknown options (status)" "1" "$?"
rm -rf "$tmp"
exit $fail
