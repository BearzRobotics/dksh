# The dksh language

dksh is a Unix shell whose scripting language reads like C. At the prompt it
behaves like any shell: pipelines, redirection, globs, job control, tab
completion. In scripts you get declared variables, real types, braces,
functions, classes and errors that stop the script instead of being ignored.

This guide is the user-facing reference. `SPEC.md` has the design rationale,
`docs/grammar.ebnf` the exact syntax, and `man dksh` a condensed version of
this page.

Every example below is checked with `dksh -n`, and the ones that print
something show their output as comments.

- [A quick tour](#a-quick-tour)
- [Running dksh](#running-dksh)
- [Source text](#source-text)
- [Commands and expressions](#commands-and-expressions)
- [Values and types](#values-and-types)
- [Variables and scope](#variables-and-scope)
- [Strings](#strings)
- [Operators](#operators)
- [Arrays and maps](#arrays-and-maps)
- [Control flow](#control-flow)
- [Functions](#functions)
- [Running commands](#running-commands)
- [Errors](#errors)
- [Signals, cleanup and subshells](#signals-cleanup-and-subshells)
- [Classes](#classes)
- [Modules](#modules)
- [Regular expressions](#regular-expressions)
- [Formatted output](#formatted-output)
- [Standard library reference](#standard-library-reference)
- [Interactive use](#interactive-use)
- [Using dksh as your login shell](#using-dksh-as-your-login-shell)
- [Debugging a script](#debugging-a-script)
- [Coming from bash](#coming-from-bash)
- [A complete example](#a-complete-example)
- [Known limits](#known-limits)

---

## A quick tour

```dksh
#!/usr/bin/dksh

const backupRoot = "/mnt/backup"

fn backup(src, dest = backupRoot) {
    if (!isDir(src)) {
        error("not a directory: ${src}")
    }
    mkdir -p $dest
    tar -czf "${dest}/${baseName(src)}.tar.gz" $src
}

var dirs = @(ls -d /etc /home/*)        # command output, one line per element
for (d in dirs) {
    backup(d)
}

if grep -q dakota /etc/passwd {         # a command as the condition
    print("user exists")
}

if (len(dirs) > 3) {                    # an expression as the condition
    print("backed up ${len(dirs)} directories")
}
```

Things to notice:

- `mkdir -p $dest` is a **command**: words separated by spaces, no commas,
  no parentheses. `print("...")` and `backup(d)` are **function calls**.
- `$dest` is always exactly one argument, even if it contains spaces.
- If `tar` fails, the script **stops** with an error pointing at that line.
- `if (...)` takes an expression, `if grep ... {` takes a command.

---

## Running dksh

| Invocation | Meaning |
|---|---|
| `dksh` | interactive shell (when stdin is a terminal) |
| `dksh script.dksh a b` | run a script; `args` is `["a", "b"]` |
| `dksh -c 'source' a b` | run a string; `args` is `["a", "b"]` |

| Option | Meaning |
|---|---|
| `-c source` | run the string |
| `-l` | login shell: read `profile.dksh` first (also when argv[0] starts with `-`) |
| `-i` | interactive even if standard input is not a terminal |
| `-n` | parse and resolve only; report errors and warnings (including shadowed variables), run nothing |
| `-x` | trace: print each command to stderr as `+ cmd arg ...` after expansion, before it runs; arguments are quoted so word boundaries are visible |
| `-e` / `+e` | failed commands stop the script (the default) / do not |
| `--dump-ast` | parse and resolve, then print the syntax tree (S-expressions with `line:col`) instead of running |
| `--tree` | like `--dump-ast`, but drawn as an ASCII tree (`\|--`, `` `-- ``), with `[line:col]` on statements |
| `-v`, `--version` | print the version and Unicode data version |
| `-h`, `--help` | print usage |
| `--` | end of options |

Short flags combine: `-nx`, `-xc 'echo hi'`, `+e`.

```sh
dksh -c 'print("sum:", 1 + 2)'            # sum: 3
dksh -c 'print(args)' one two             # ["one", "two"]
dksh -n deploy.dksh && echo "syntax ok"   # check without running
dksh -x deploy.dksh 2> trace.log          # record exactly what ran
```

**Exit status of dksh itself:** `0` success, `1` a runtime error or failed
command, `2` a syntax or name error or a bad option, `127` script not found.
`exit(n)` or `exit n` ends a script with status `n`.

### Shebang

The first line of an executable script names the interpreter. dksh needs no
special handling: the kernel reads the `#!` line and starts dksh, and dksh
treats that line as an ordinary comment.

```sh
#!/usr/bin/dksh
print("hello from", args)
```

```sh
chmod +x deploy.dksh
./deploy.dksh staging          # args == ["staging"]
```

- `#!/usr/bin/env dksh` also works if `dksh` is on `PATH`.
- Options may follow on the same line, e.g. `#!/usr/bin/dksh -x` to trace the
  script (Linux passes everything after the interpreter as a single argument,
  so use at most one option group such as `-xe`).
- The line is only special as line 1; later `#!` lines are plain comments.

**Scripts for other interpreters.** dksh never tries to run `sh` or bash
syntax. If a file's `#!` line names something other than dksh, then
`dksh file` hands the file to that interpreter (like the kernel would), with
the same arguments, instead of trying to parse it:

```sh
$ cat backup.sh
#!/usr/bin/bash
files=(a b c); echo "${#files[@]} files"
$ dksh backup.sh          # runs under bash
3 files
$ dksh -n backup.sh       # checking is refused, never executed
dksh: backup.sh is a bash script, not a dksh script; not checked
```

This works for `/usr/bin/bash`, `#!/bin/sh -e`, `#!/usr/bin/env python3`, and
so on. Executing such a script as a command (`./backup.sh`, or
`backup.sh` from `PATH`) works the same way, because dksh asks the kernel to
run it. Options like `-x` apply to dksh scripts only. If the interpreter does
not exist you get `cannot run /no/such/interp` and status 127.

---

## Source text

```dksh
# A comment runs from # to the end of the line.
var a = 1; var b = 2        # ';' or a newline ends a statement
var long = 1 + \
           2                # a backslash continues the line

var total = (                # newlines are ignored inside (), [] and {}
    a +
    b
)

if (a < b) { print("block") } print("no separator needed after }")
```

- Statements end at a newline or `;`. A statement that ends in `}` (`if`,
  `while`, `for`, `fn`, `class`, `try`) needs no separator before the next.
- Names are letters, digits and `_`, not starting with a digit.
- Reserved words: `var const if else while for in fn class extends return
  break continue try catch finally import as subshell true false null`.
- Source is UTF-8. A NUL byte in a script is an error.

---

## Commands and expressions

A shell has to keep commands terse (`ls -la > out.txt`) while a programming
language needs `>` and `<` as operators. dksh uses two modes with fixed rules,
so there is never any guessing.

**Expression mode** is used:

- inside the parentheses of `if (...)`, `while (...)`, `for (...)`
- after `=` in `var`, `const` and assignments, and after `return`
- inside `${...}` in a string or command word
- inside the parentheses of a function call: `name(...)`
- inside `[...]` array literals and `{...}` map literals

**Command mode** is used everywhere else.

A statement is classified by how it starts:

| It starts with | It is |
|---|---|
| `var const if while for fn class return break continue try import subshell` | that construct |
| a declared name followed by `=`, `+=`, `-=`, `*=`, `/=`, `++` or `--` (or `.` / `[` right after the name) | an assignment |
| a name immediately followed by `(` | a function call |
| anything else | a command |

```dksh
var x = 5               # declaration (expression after '=')
x = x + 1               # assignment
x += 1
print(x)                # function call: print(7)  -> 7
echo $x                 # command; the word $x is replaced by 7
ls -l > /dev/null       # '>' here is a redirection, not "greater than"
if (x > 3) { echo big } # '>' here is "greater than"
```

Because scoping is lexical, dksh knows which names are variables. Assigning
to a name that was never declared is an error, never a command named `x`:

```
error: `total` is not declared; use `var total = 5`
 --> script.dksh:2:1
  |
2 | total = 5
  | ^
```

A function call must have **no space** before the `(`. `print (x)` is a
command named `print` with the argument `(x)`.

---

## Values and types

| Type | Literals | Notes |
|---|---|---|
| `null` | `null` | |
| `bool` | `true`, `false` | |
| `int` | `42`, `0x1f`, `0o755`, `0b101`, `1_000` | 64-bit signed. Overflow is an error, not wraparound |
| `float` | `3.14`, `1e-3`, `2.5E10` | 64-bit |
| `string` | `"..."`, `'...'`, `"""..."""` | bytes, expected UTF-8, immutable |
| `array` | `[1, 2, 3]` | ordered, growable |
| `map` | `{"key": 1, name: 2}` | insertion ordered; bare keys are strings |
| `fn` | `fn(x) { return x }` | first class; closures capture by reference |
| `regex` | `regex('^\d+$')` | compiled regular expression |
| object | `Point(1, 2)` | instance of a class |

```dksh
print(type(42), type(3.0), type("s"), type([1]), type({}), type(null))
# int float string array map null
print(0x1f, 0o755, 0b101, 1_000_000)       # 31 493 5 1000000
print(7 / 2, 7.0 / 2, 7 % 3)               # 3 3.5 1
print(0.1 + 0.2)                           # 0.30000000000000004
print(3.0, 1e21)                           # 3.0 1000000000000000000000.0
```

**Floats print as the shortest text that reads back as the same value**, and
a float with no fractional part keeps `.0` so its type stays visible.

**There is no implicit conversion** except into strings (interpolation and
command arguments). Mixing types is an error:

```dksh
print(int("5") + 1)            # 6
print(float("1.5") * 2)        # 3.0
print(str(42) + "!")           # 42!
print(bool(""), bool("x"), bool(0), bool([]))   # false true false false
# print("5" + 1)               # error: cannot apply `+` to string and int
```

**Conditions need real bools.** `if (1)`, `!"x"` and `1 && 2` are errors; use
`bool(v)` or a comparison:

```
error: condition must be a bool, got int
 --> script.dksh:1:5
  |
1 | if (1) { print("yes") }
  |     ^
```

**Equality:** `==` compares numbers by value (`1 == 1.0`), strings by
content, arrays and maps structurally, and objects and functions by identity.

```dksh
print(1 == 1.0, "a" == "a", [1, 2] == [1, 2], {a: 1} == {a: 1})   # true true true true
```

Arrays, maps and objects are **reference values**: assigning one makes
another name for the same thing.

```dksh
var a = [1, 2]
var b = a
push(b, 3)
print(a)             # [1, 2, 3]
```

---

## Variables and scope

`var` declares a mutable variable, `const` an immutable one. Both need an
initial value.

```dksh
var count = 0
const limit = 10
count += 1
# limit = 11             # error: cannot assign to constant `limit`
```

Scope is **lexical and block-based**: a variable declared inside `{ }` is gone
after the closing brace. Shadowing an outer variable is allowed (and `dksh -n`
warns about it).

```dksh
var x = "outer"
if (true) {
    var x = "inner"      # a new variable
    print(x)             # inner
}
print(x)                 # outer
```

### Shell variables are not environment variables

The environment is the `env` map. Assigning to `env.NAME` exports it to
commands started afterwards:

```dksh
env.GREETING = "hello"
sh -c 'echo $GREETING'        # hello (the child sees it)
print(env.HOME, env["PATH"])
var local = "shell only"
sh -c 'echo [$local]'         # [] (not exported)
```

In **command mode**, `$name` looks up a variable first, then `env`. In
strings, `$name` and `${expr}` are interpolation (see below).

`args` is the array of script arguments. `dksh script.dksh a b` gives
`args == ["a", "b"]`.

---

## Strings

| Form | Interpolates? | Escapes? |
|---|---|---|
| `"double"` | yes | yes |
| `'single'` | no | no (a `'` cannot appear inside) |
| `"""triple"""` | yes | yes; multi-line, common indentation removed |

Escapes in double quotes: `\n \t \r \0 \e \\ \" \$ \u{263A}`.

```dksh
var name = "world"
var n = 3
print("hello ${name}! ${n * 2} $name")      # hello world! 6 world
print('literal $name ${n}')                  # literal $name ${n}
print("tab:\t|  quote:\"  dollar:\$  smile:\u{263A}")
print("a" + "b", "abc"[1], len("héllo"))     # ab b 6   (len counts bytes)
print("list: ${[1, 2]}  map: ${{k: "v"}}  null: ${null}")
```

`${...}` takes any expression. The short form `$name` takes just a name:

```dksh
var file = "report"
print("$file.txt")          # report.txt   ('.' ends the name)
print("${file}_final")      # report_final
```

Triple-quoted strings drop the newline after the opening quotes, the final
line if it holds only the closing quotes, and the **common leading
indentation**:

```dksh
var who = "dksh"
print("""
    Dear ${who},
      this line stays indented by two.
    Bye.
    """)
# Dear dksh,
#   this line stays indented by two.
# Bye.
```

Strings are indexed by **byte**, and `len` counts bytes. Use `split(s, "")` to
get characters:

```dksh
print(split("héé", ""))        # ["h", "é", "é"]
```

---

## Operators

From highest to lowest precedence:

| Operators | Associativity |
|---|---|
| `()` call, `[]` index, `.` member | left |
| `!`, unary `-` | right |
| `*` `/` `%` | left |
| `+` `-` | left |
| `<` `<=` `>` `>=` `in` | left |
| `==` `!=` `=~` `!~` | left |
| `&&` | left |
| `\|\|` | left |
| `? :` | right |

```dksh
print(1 + 2 * 3, (1 + 2) * 3, 10 - 4 - 3, 2 * 3 % 4)    # 7 9 3 2
print(true && false || true, !true, !(1 == 2))            # true false true
print(1 < 2 ? "yes" : "no")                                # yes
print("a" + "b", [1] + [2])                                # ab [1, 2]
print(7 / 2, -7 / 2, -7 % 3, 7.5 / 2)                      # 3 -3 -1 3.75
print("x" in ["x", "y"], "k" in {k: 1}, "ell" in "hello")  # true true true
```

- `+` joins strings and arrays, and adds numbers.
- `/` on two ints is integer division (truncating); dividing by zero is an
  error. `%` is the remainder with the sign of the left side.
- `&&` and `||` short-circuit and need bools.
- `in` tests membership in an array, a key in a map, a substring in a string.
- `=~` matches a string against a regex: `line =~ '^\s*#'`. The right side
  may be a `regex` value or a string (compiled once and cached). `!~` negates.
- Assignment operators: `=  +=  -=  *=  /=  ++  --`.

```dksh
var line = "  # a comment"
if (line =~ '^\s*#') { print("comment line") }
var i = 0
i++
i += 10
print(i)           # 11
```

---

## Arrays and maps

```dksh
var a = [3, 1, 2]
push(a, 4)                         # append
print(a, len(a), pop(a))           # [3, 1, 2] 4 4  (pop removes and returns the last)
a[0] = 10                          # assign by index
print(a[0], a[-1])                 # 10 2           (negative counts from the end)
print(sort(a))                     # [1, 2, 10]     (returns a new array)
print(sort(a, fn(x, y) { return y - x }))   # [10, 2, 1]  (comparator returns an int)
print(map([1, 2, 3], fn(x) { return x * x }))                # [1, 4, 9]
print(filter([1, 2, 3, 4], fn(x) { return x % 2 == 0 }))     # [2, 4]
print([1, 2] + [3], 2 in [1, 2])                             # [1, 2, 3] true
```

Maps keep insertion order. Bare keys are strings; any string expression works
in `[ ]`:

```dksh
var m = {name: "dksh", "two words": 2}
m.extra = true                     # add a key
m["k"] = [1, 2]
print(m)                           # {name: "dksh", two words: 2, extra: true, k: [1, 2]}
print(m.name, m["two words"], m.missing)    # dksh 2 null  (a missing key is null)
print(keys(m), values(m), len(m))
print("name" in m, "zzz" in m)     # true false
for (k in m) { printf("%s=%s;", k, str(m[k])) }
print()
```

Iterating a map visits its keys, in order. Iterating an array visits its
elements.

Index errors are loud:

```
error: index 3 out of range (length 3)
 --> script.dksh:2:9
  |
2 | print(a[3])
  |         ^
```

---

## Control flow

### if / else

```dksh
var n = 7
if (n < 5) {
    print("small")
} else if (n < 10) {
    print("medium")
} else {
    print("large")
}
```

The condition is either `( expression )` or **a command**. A command counts
as true when it exits with status 0, and its failure does not stop the
script:

```dksh
if grep -q root /etc/passwd { print("root exists") }
if test -f /etc/hostname && test -s /etc/hostname { print("non-empty") }
if ! ping -c1 -W1 example.invalid >/dev/null 2>&1 { print("offline") }
```

`! cmd` negates a command's status, so `if ! grep -q x file { ... }` runs the
block when `grep` fails. A negated pipeline is a test, not a failure: it never
stops the script. The negation applies to the whole pipeline (`! a | b` negates
the pipeline's status).

A command that cannot be found is an error even as a condition, so a typo is
never silently "false":

```
error: command not found: grpe
 --> script.dksh:1:4
  |
1 | if grpe -q x /etc/passwd { print("x") }
  |    ^^^^
```

Only `status(...)` turns a missing command into the status `127`.

### while

```dksh
var i = 0
while (i < 10) {
    i += 1
    if (i == 3) { continue }       # skip to the next iteration
    if (i == 6) { break }          # leave the loop
    printf("%d ", i)
}
print()                            # 1 2 4 5
```

```dksh
while read_next_job {              # a command as the condition
    process
}
```

### for

```dksh
for (item in ["a", "b", "c"]) { printf("%s ", item) }       # a b c
print()
for (var i = 0; i < 3; i++) { printf("%d ", i) }            # 0 1 2
print()
for (var k = 10; k > 0; k -= 4) { printf("%d ", k) }        # 10 6 2
print()
for (f in glob("/etc/*.conf")) { print(baseName(f)) }
for (line in @(ls /etc)) { echo "entry: $line" }
```

`break` and `continue` work in all loops.

---

## Functions

```dksh
fn greet(name, greeting = "Hello") {
    return "${greeting}, ${name}!"
}
print(greet("Dakota"))              # Hello, Dakota!
print(greet("Dakota", "Howdy"))     # Howdy, Dakota!
```

- Parameters may have defaults; defaults can use earlier parameters.
- Calling with too few or too many arguments is an error:
  `two expects 2 argument(s), got 1`.
- A function without `return` returns `null`.
- Functions are values: store them in variables, arrays and maps, pass them
  around, return them.
- Functions are **hoisted** within their block, so order does not matter:

```dksh
fn later() { return hoisted() }
fn hoisted() { return "ok" }
print(later())                      # ok
```

### Closures

Closures capture variables **by reference**:

```dksh
fn counter() {
    var c = 0
    return fn() { c += 1; return c }
}
var next = counter()
next(); next()
print(next())                       # 3
```

```dksh
var ops = {
    add: fn(a, b) { return a + b },
    mul: fn(a, b) { return a * b },
}
print(ops.add(2, 3), ops.mul(2, 3))   # 5 6
```

### Recursion

```dksh
fn fact(n) {
    if (n <= 1) { return 1 }
    return n * fact(n - 1)
}
print(fact(10))                     # 3628800
```

Calls nested more than 600 deep raise a "stack overflow" error instead of
crashing.

### Functions as commands

A function can be called **as an expression** or **as a command**.

```dksh
fn show(a, b = "dflt") { print("show:", a, b) }

show("x")                  # expression call
show one two               # command call: every argument is a string
show Dakota | tr a-z A-Z   # SHOW: DAKOTA DFLT   -- its output works in pipelines
```

- As an expression it returns the value of `return` (`null` if none).
- As a command every argument arrives as a string, its output is whatever it
  prints, and its exit status is 0 unless it raises an error.
- Inside a pipeline, or with a background `&`, the function runs in a forked
  child, so changes it makes to variables do not persist.

---

## Running commands

### Words, quoting and expansion

A command is words separated by spaces. Each word may contain pieces that
dksh expands. There are three rules that fix bash:

1. **No word splitting.** `$file` is always exactly one argument.
2. **Splicing is explicit.** `@list` expands an array into one argument per
   element. `$list` on an array is an error.
3. **A glob that matches nothing is an error**, not a literal `*.txt` passed
   to the command. Quoted words are never globbed.

```dksh
const f = "a file with spaces.txt"
printf '[%s]\n' $f              # [a file with spaces.txt]    one argument
printf '[%s]\n' "$f"            # same
printf '[%s]\n' '$f'            # [$f]                        single quotes: literal
printf '[%s]\n' pre-$f-post     # [pre-a file with spaces.txt-post]

var words = ["one two", "three"]
printf '[%s]\n' @words          # [one two]  [three]          one argument per element
# echo $words                   # error: an array cannot be used as one argument; use @name to splice it
```

Pieces of a word:

| Piece | Meaning |
|---|---|
| `$name`, `$name.field` | variable (then `env`); `.field` applies only if the value is a map or object |
| `${expr}` | any expression, converted to a string |
| `$(cmd)` | output of `cmd` as a string, one trailing newline removed |
| `@(cmd)` | output of `cmd` as an array of lines, spliced as separate arguments (whole word only) |
| `@name` | splice an array (whole word only) |
| `~`, `~user` | home directory (start of a word only) |
| `*  ?  [abc]  [a-z]  [!x]` | glob characters (unquoted only) |
| `'...'`, `"..."`, `\x` | quoting |

```dksh
var d = $(mktemp -d)
cd $d
touch b.txt a.txt c.log .hidden
echo *.txt             # a.txt b.txt         (sorted; dotfiles need a leading .)
echo "*.txt"           # *.txt               (quoted: not a glob)
echo [ab].txt ?.log    # a.txt b.txt c.log
echo ~/projects        # /home/you/projects
echo $(date +%Y)       # 2026
echo "today: $(date +%F)"
rm -rf $d
```

```
error: no matches for glob pattern: *.zzz
 --> script.dksh:2:6
  |
2 | echo *.zzz
  |      ^^^^^
```

There is no brace expansion (`{a,b}`) and no recursive `**`. Use `glob()` or
`find` for those.

`$obj.field` in command mode is a field access when the value is a map or
object; otherwise `.field` stays literal text, so `cp $f $f.bak` works as you
expect:

```dksh
var cfg = {path: "/etc/hostname"}
cat $cfg.path                    # field access
var f = "notes"
echo $f.bak                      # notes.bak
```

### Pipelines, lists and background

```dksh
printf 'x\ny\nz\n' | grep -v y | tr a-z A-Z    # X  Z
mkdir -p out && echo made || echo failed
cmd1; cmd2                       # sequence ( ; or newline )
sleep 10 &                       # run in the background
```

- `a | b | c` connects standard output to standard input. The pipeline
  **fails if any command in it fails**, not just the last one. (An upstream
  command killed by SIGPIPE, as in `yes | head -n 1`, does not count.)
- `a && b` runs `b` only if `a` succeeded, `a || b` only if it failed.
- `cmd &` runs in the background.
- A standalone `}` word always ends a command; quote it to pass a brace: `echo '}'`.

### Redirection

| Form | Meaning |
|---|---|
| `> file` | stdout to file (truncate) |
| `>> file` | append |
| `< file` | stdin from file |
| `2> file`, `2>> file` | stderr to file |
| `&> file` | stdout and stderr to file |
| `2>&1` | stderr to wherever stdout goes |
| `<<< word` | send a string as stdin (a newline is added) |

```dksh
echo first > out.txt
echo second >> out.txt
cat < out.txt                                    # first second
sh -c 'echo out; echo err 1>&2' > both.txt 2>&1  # both streams into the file
sh -c 'echo x; echo y 1>&2' &> all.txt
cat <<< "here string"                            # here string
var s = "interpolated ${1 + 1}"
cat <<< $s                                       # interpolated 2
sort <<< "b
a"                                               # a  b
```

There are no here-documents (`<<EOF`): use a multi-line string with `<<<`.
Redirection targets are expanded like any word and must produce exactly one
argument. If the file cannot be opened, you get one error pointing at it:

```
error: cannot open /nonexistent/file for writing: No such file or directory
 --> script.dksh:1:9
  |
1 | echo hi > /nonexistent/file
  |         ^^^^^^^^^^^^^^^^^^^
```

### Capturing output and status

```dksh
var host = $(hostname)                       # string, trailing newline removed
var lines = @(printf 'a\nb c\n\nd\n')        # ["a", "b c", "", "d"]
print(len(lines))                            # 4

print(status(true), status(false), status(sh -c 'exit 7'))   # 0 1 7
var rc = status(grep -q nomatch /etc/passwd)
if (status(test -d /tmp) == 0) { print("tmp exists") }
print(status(no-such-command-xyz))           # 127   (status() never raises)
```

`$( )` and `@( )` hold one command list (pipelines with `|`, `&&`, `||`).
If the captured command fails, the failure is an error (except inside
`status()`, an `if`/`while` condition, or the left of `&&`/`||`).

### Built-in commands

| Command | Meaning |
|---|---|
| `cd [dir]` | change directory; no argument = `$HOME`; `cd -` = previous; sets `env.PWD`/`OLDPWD` |
| `exit [n]` | exit with status `n` (default: last status) |
| `source file` | run a file in the current global scope |
| `jobs` `fg [%n]` `bg [%n]` `wait [%n]` `disown [%n]` | job control (see Interactive use) |
| `exec cmd args...` | replace the shell with `cmd` |
| `history` | print the command history |
| `type name...` | say whether a name is a function, builtin or file |
| `umask [mode]` | show or set the file creation mask (octal) |
| `ulimit [-HS] [-a] [-cdflmnstuv] [n\|unlimited]` | show or set resource limits (units as in bash; no flag sets both soft and hard) |

```dksh
cd /tmp
cd -                       # prints and returns to the previous directory
fn greet() { }
type ls cd greet           # ls is /usr/bin/ls ; cd is a builtin ; greet is a function
umask 027
```

Resolution order for the first word: user function, then built-in command,
then an executable found in `PATH` (or the path given if it contains `/`).

---

## Errors

dksh errors are loud and tell you where they happened.

```
error: command failed with status 1: grep -q root /etc/shadow
  --> backup.dksh:14:5
   |
14 |     grep -q root /etc/shadow
   |     ^^^^^^^^^^^^^^^^^^^^^^^^
```

In a script:

- a command that **exits non-zero raises an error**, which stops the script
  unless it is caught;
- except when the command is the condition of `if` or `while`, the left side
  of `&&` or `||`, negated with `!`, or wrapped in `status(...)`;
- a pipeline fails if any command in it fails;
- at the interactive prompt, errors are reported and the prompt returns; the
  shell never exits because a command failed.

### try / catch / finally

```dksh
try {
    mkdir /root/forbidden
} catch (e) {
    print("failed:", e.message)
    print("at ${e.file}:${e.line}:${e.column}, status ${e.status}")
}
```

`e` is a map with `message`, `status` (exit status, or `null` for script
errors), `file`, `line` and `column`.

```dksh
try { error("boom") } catch (e) { print(e.message, e.status) }     # boom null
try { false } catch (e) { print(e.status, e.message) }             # 1 command failed with status 1: false
try { print(1 / 0) } catch (e) { print(e.message) }                # division by zero
try { print([1][5]) } catch (e) { print(e.message) }               # index 5 out of range (length 1)
```

`error("message")` raises an error from your own code:

```dksh
fn check(v) {
    if (v < 0) { error("negative value: ${v}") }
    return v
}
```

`finally` runs however the body ends: success, a caught error, an uncaught
error, `return`, `break` or `continue`. `catch` is optional when there is a
`finally`; a `try` needs at least one of them.

```dksh
fn deploy(target) {
    mount $target /mnt/deploy
    try {
        rsync -a build/ /mnt/deploy/
        print("deployed")
    } finally {
        umount /mnt/deploy          # always runs, even if rsync failed
    }
}

fn early() {
    try { return "value" } finally { print("cleanup runs on return too") }
}
```

Errors propagate up through functions. An error raised inside `finally`
replaces the pending one.

### Exit status

- `exit(3)` or `exit 3` ends the script with status 3.
- An uncaught error ends it with status 1 (syntax and name errors: 2).
- A command that cannot be found is an error with status 127 (`permission denied`
  for a file that cannot be executed: 126), except inside `status(...)`, which
  returns 127 instead of raising.

```dksh
exit(0)                       # explicit success
```

---

## Signals, cleanup and subshells

### trap

`trap(signal, fn)` registers a function that runs **between statements** when
the signal arrives (a long-running foreground command finishes first).
`trap("EXIT", fn)` runs when the shell exits, including after an error.

```dksh
const lock = "/tmp/myscript.lock"
writeFile(lock, str(pid()))
trap("EXIT", fn(sig) { rm -f $lock })              # always remove the lock file
trap("INT", fn(sig) { print("interrupted"); exit(130) })
trap("USR1", fn(sig) { print("got", sig) })

kill(pid(), "USR1")                                # got USR1
trap("USR1")                                       # reset to the default
```

- Signals: `HUP INT QUIT USR1 USR2 PIPE ALRM TERM CHLD CONT TSTP WINCH`, by
  name (with or without `SIG`) or by number. `KILL` and `STOP` cannot be trapped.
- The handler receives the signal name as a string.
- `trap(sig)` or `trap(sig, null)` restores the default.

`kill(pid, sig = "TERM")` sends a signal; a negative `pid` signals a process
group. `sleep(seconds)`, `now()` and `time(fn)` help with timing:

```dksh
var secs = time(fn() { sleep(0.25) })
print(secs >= 0.25)              # true
print(now() > 1700000000)        # true   (seconds since the epoch, a float)
```

### subshell

`subshell { ... }` runs the block in a forked child. `cd`, variable changes,
`env` changes and `exit` stay inside; the parent continues unchanged.

```dksh
var before = cwd()
subshell {
    cd /
    env.TEMP_VAR = "only here"
    print("inside:", cwd())      # inside: /
}
print(cwd() == before)           # true
print(env.TEMP_VAR)              # null
```

A non-zero status from the subshell raises
`subshell exited with status N`.

---

## Classes

Classes are optional: a script that never uses `class` pays nothing for them.

```dksh
class Mount {
    var device = ""
    var point = ""

    fn init(device, point) {
        self.device = device
        self.point = point
    }

    fn isMounted() {
        return status(mountpoint -q $self.point) == 0
    }

    fn mount() {
        if (!self.isMounted()) {
            mount $self.device $self.point
        }
    }

    fn toString() { return "Mount(${self.device})" }
}

var usb = Mount("/dev/sdb1", "/mnt/usb")
usb.mount()
print(str(usb))                      # Mount(/dev/sdb1)
```

- A class has **fields** (`var name = default`) and **methods** (`fn`).
  `self` is the instance inside methods.
- Calling the class name constructs an instance and runs `init` with the
  arguments, if there is one. Field defaults are evaluated for each instance.
- Fields not declared in the class cannot be added later; assigning to or
  reading an unknown field is an error.
- Objects are reference values compared by identity.
- `str(obj)` calls `obj.toString()` if the class defines it.

### Inheritance

Single inheritance with `extends` and `super`:

```dksh
class Base {
    var name = "base"
    fn init(name) { self.name = name }
    fn describe() { return "I am ${self.name}" }
}

class Child extends Base {
    var extra = 0
    fn init(name, extra) {
        super.init(name)            # required when the parent has init
        self.extra = extra
    }
    fn describe() {
        return super.describe() + " (extra ${self.extra})"
    }
}

var c = Child("kid", 7)
print(c.describe())                 # I am kid (extra 7)
print(isInstance(c, Base), isInstance(c, Child), isInstance(Base("x"), Child))
# true true false
```

- A method with the same name as a parent's method overrides it;
  `super.name(...)` calls the parent's version.
- A child that defines `init` must call `super.init(...)` if the parent has
  one. Leaving it out is a compile-time error.
- Redeclaring a parent's field in the child is an error.
- `isInstance(obj, Class)` is true for the class and every class that
  extends it.

---

## Modules

```dksh
# lib/disks.dksh
const version = "1.0"
var private = "not visible outside"
fn listDevices() { return ["sda", "sdb"] }
class Device {
    var name = ""
    fn init(n) { self.name = n }
}
```

```dksh
import "lib/disks.dksh" as disks
print(disks.version, disks.listDevices())       # 1.0 ["sda", "sdb"]
var d = disks.Device("sda")
print(d.name)                                    # sda
```

- `import` runs a file **once** and binds its top-level `const`, `fn` and
  `class` declarations under the given name. `var` declarations stay private.
- A path containing `/` is relative to the importing file's directory.
- A bare name (`import "utils.dksh" as u`) is searched in
  `$XDG_DATA_HOME/dksh/lib` (default `~/.local/share/dksh/lib`) and
  `/usr/share/dksh/lib`.

---

## Regular expressions

dksh has its own regex engine. It is **guaranteed linear time** in the length
of the input, so a bad pattern can never hang the shell on a big file. The
price: no backreferences and no lookaround (they are rejected when the
pattern is compiled).

### Creating and using

```dksh
const kv = regex('^(?<key>\w+)\s*=\s*(?<value>.*)$', "m")

for (line in readLines("/etc/os-release")) {
    var m = kv.match(line)
    if (m != null) {
        print("${m.key} -> ${m.value}")
    }
}

if (env.HOME =~ '^/root') { print("running as root") }
```

Use single quotes for patterns, so backslashes need no doubling.

| Call | Returns |
|---|---|
| `regex(pattern, flags = "")` | a compiled regex; an invalid pattern is an error |
| `re.test(s)` | `bool` |
| `re.match(s)` | `null`, or a map: `0` is the whole match, `1`... the groups, named groups by name, plus `start` and `end` (byte offsets) |
| `re.matchAll(s)` | array of match maps |
| `re.replace(s, replacement, count = 0)` | string; `$1`, `${name}`, `$$` in the replacement refer to groups; a function receives the match map; `count = 0` replaces all |
| `re.split(s, limit = 0)` | array of strings |

```dksh
var m = regex('(\d+)-(\d+)').match("range 10-20 ok")
print(m[0], m[1], m[2], m.start, m.end)                   # 10-20 10 20 6 11
print(regex('\d+').matchAll("a1b22c333"))                 # three match maps
print(regex('(\w)(\d)').replace("a1 b2 c3", '$2$1'))      # 1a 2b 3c
print(regex('(\w)(\d)').replace("a1 b2 c3", '<${1}>', 2)) # <a> <b> c3
print(regex('\d').replace("a1b2", fn(m) { return "[" + m[0] + "]" }))   # a[1]b[2]
print(regex('\s*,\s*').split("a , b,c ,d"))               # ["a", "b", "c", "d"]
print(regex(',').split("a,b,c", 2))                       # ["a", "b,c"]
```

An unmatched optional group is `null` in the match map.

### Syntax

| Feature | Syntax |
|---|---|
| Literals, escapes | `a`  `\.`  `\n \t \r \f \v \a \e`  `\x41`  `\x{41}`  `\u{263A}` |
| Any character | `.` (not newline unless flag `s`) |
| Classes | `[abc]  [^a-z]  [a-c0-9_]`  `\d \D \w \W \s \S`  POSIX `[[:alpha:]] [[:^digit:]]` |
| Anchors | `^ $` (per line with flag `m`), `\A` start of text, `\z` end of text, `\b \B` word boundary |
| Quantifiers | `*  +  ?  {n}  {n,}  {n,m}`, lazy: `*?  +?  ??  {n,m}?` |
| Groups | `( )` capturing, `(?: )` non-capturing, `(?<name> )` named |
| Alternation | `a\|b` (leftmost alternative wins, like Perl) |

| Flag | Meaning |
|---|---|
| `i` | case-insensitive |
| `m` | `^` and `$` match at line boundaries |
| `s` | `.` matches newline |
| `x` | extended: whitespace and `# comments` in the pattern are ignored |
| `u` | Unicode: `\w \d \s \b` follow Unicode, `i` uses Unicode case folding, and `\p{..}` is available |

POSIX classes and escapes are ASCII unless the `u` flag is set. Matching
always works on whole UTF-8 characters: `.` matches `é` as one character.

```dksh
print(regex('^\p{Lu}', "u").test("Ä"), regex('^\p{Lu}', "u").test("ä"))   # true false
print(regex('\p{Greek}+', "u").match("abc αβγ def")[0])                    # αβγ
print(regex('\w+', "u").match("naïve!")[0], regex('\w+').match("naïve!")[0])   # naïve na
print(regex('hello', "i").test("HeLLo"))                                   # true
print(regex('^b', "m").test("a\nb"), regex('a.b', "s").test("a\nb"))       # true true
var phone = regex('(\d{3}) - (\d{4})   # area, number', "x")
print(phone.match("call 555-1234")[2])                                     # 1234
```

`\p{L}`, `\p{Lu}`, `\p{Nd}` match general categories and `\p{Greek}`,
`\p{Cyrillic}`, `\p{Han}` scripts (Unicode 16.0). `\P{..}` negates.

### Errors

Unsupported or invalid patterns fail with a pointer into the pattern:

```
error: invalid regex: backreferences are not supported (patterns must run in linear time)
  pattern: (a)\1
              ^^
```

---

## Formatted output

`print(a, b, ...)` writes its arguments separated by spaces plus a newline.
`printErr` does the same to standard error. `printf(format, ...)` and
`sprintf(format, ...)` (which returns the string) follow C format strings.

```dksh
print("a", 1, true, [1, 2])                           # a 1 true [1, 2]
printf("%d items\n", 3)                               # 3 items
printf("%5d|%-5d|%05d|%+d\n", 42, 42, 42, 42)         #    42|42   |00042|+42
printf("%x %X %#x %o\n", 255, 255, 255, 8)            # ff FF 0xff 10
printf("%.2f|%8.3f|%-8.1f|%e\n", 3.14159, 3.14159, 3.14159, 1234.5)
printf("%s|%10s|%-10s|%.3s\n", "str", "right", "left", "truncate")
printf("%c%c %*d\n", 72, "i", 6, 7)                   # Hi      7
var line = sprintf("%03d-%s", 7, "x")                 # 007-x
```

| Part | Supported |
|---|---|
| flags | `-  +  space  #  0` |
| width, precision | numbers, or `*` taking an int argument |
| conversions | `d i u o x X f F e E g G a A c s %` |
| length modifiers | `l ll h hh z j t L` are accepted and ignored (every int is 64-bit) |

`%n` is not supported. A conversion that does not match the argument's type
(`%d` with a string) is an error, not undefined behavior.

---

## Standard library reference

### Output and input

| Function | Description |
|---|---|
| `print(...)` | write arguments separated by spaces, plus a newline |
| `printErr(...)` | same, to standard error |
| `printf(format, ...)` | formatted output |
| `sprintf(format, ...)` | formatted string |
| `readLine(prompt = "")` | read a line from standard input (`null` at end of input) |
| `readPassword(prompt = "")` | like `readLine` with terminal echo off |
| `readLines(path = "-")` | lines of a file, or of standard input for `"-"` |
| `readStdin()` | all of standard input as a string |

```dksh
var name = readLine("Name? ")
for (line in readLines("/etc/hosts")) { if (line =~ '^127') { print(line) } }
var all = readStdin()                  # e.g. when used in a pipeline: ls | dksh script.dksh
```

### Types and conversion

| Function | Description |
|---|---|
| `type(v)` | `"null" "bool" "int" "float" "string" "array" "map" "fn" "regex" "class"` or the class name |
| `int(v)` | from float (truncates), bool, or string (`"42"`, `"0x1f"`, `"1_000"`); else error |
| `float(v)` | from int or string |
| `str(v)` | text form; calls `toString()` on objects |
| `bool(v)` | `false` for `null`, `false`, `0`, `0.0`, `""`, `[]`, `{}`; otherwise `true` |
| `isInstance(obj, Class)` | true if `obj` is an instance of `Class` or a subclass |

### Collections

| Function | Description |
|---|---|
| `len(v)` | length of a string (bytes), array or map |
| `push(arr, v)` | append (returns `null`) |
| `pop(arr)` | remove and return the last element (error if empty) |
| `keys(map)`, `values(map)` | arrays of keys / values, in order |
| `sort(arr, cmp = null)` | new sorted array; default order for numbers or strings; `cmp(a, b)` returns a negative, zero or positive int |
| `map(arr, fn)` | new array of `fn(x)` for each element |
| `filter(arr, fn)` | elements for which `fn(x)` is `true` |

### Strings

| Function | Description |
|---|---|
| `split(s, sep)` | array of pieces; `sep = ""` splits into characters |
| `join(arr, sep)` | pieces joined with `sep` (elements converted to text) |
| `trim(s)` | strip leading and trailing whitespace |
| `startsWith(s, p)`, `endsWith(s, p)`, `contains(s, sub)` | tests |
| `replace(s, old, new)` | replace every occurrence (`old` must not be empty) |
| `upper(s)`, `lower(s)` | ASCII case conversion |
| `shellQuote(s)` | `s` as one word that `sh` and dksh both read back unchanged |

```dksh
print(split("a,b,c", ","), join(["x", 1, true], "-"), trim("  pad \n"))
# ["a", "b", "c"] x-1-true pad
print(replace("a.b.c", ".", "/"), upper("MiXed"), shellQuote("it's a file"))
# a/b/c MIXED 'it'\''s a file'
```

### Files and paths

| Function | Description |
|---|---|
| `exists(p)`, `isFile(p)`, `isDir(p)` | tests |
| `readFile(p)` | whole file as a string (error if unreadable) |
| `writeFile(p, s)`, `appendFile(p, s)` | write or append |
| `baseName(p)`, `dirName(p)` | `baseName("/usr/lib/libc.so")` is `libc.so`, `dirName` is `/usr/lib` |
| `glob(pattern)` | sorted array of matching paths (empty if none; no error) |
| `shortPath(p)` | replace the home directory prefix with `~` |

### System

| Function | Description |
|---|---|
| `cwd()`, `hostName()`, `pid()` | current directory, host name, process id |
| `date(format = "%Y-%m-%d %H:%M:%S")` | local time via `strftime` conversions; `TZ` and `/etc/localtime` are honored |
| `exit(status = 0)` | end the script |
| `error(message)` | raise an error |
| `kill(pid, sig = "TERM")`, `sleep(seconds)`, `now()`, `time(fn)`, `trap(sig, fn)` | see Signals above |
| `expandPrompt(template)` | what `PS1` would show for a template (see The prompt) |
| `status(cmd)` | (special form) run a command, return its exit status as an int |

`date` accepts `%Y %y %C %m %d %e %H %I %k %l %M %S %p %P %A %a %B %b %h %j
%u %w %U %W %V %G %Z %z %s %F %T %R %D %c %x %X %n %t %%`, plus `%-d` style
flags to drop padding.

```dksh
print(date("%A, %B %-d %Y"))           # Saturday, October 31 2026
print(date("%F %R %Z"))                # 2026-10-31 14:05 EDT
```

### JSON

| Function | Description |
|---|---|
| `jsonParse(s)` | JSON to values: objects become maps (key order kept), integers that fit stay `int`; errors give a byte offset |
| `jsonStringify(v, indent = 0)` | values to JSON; `indent` 1-16 pretty-prints; functions, objects and NaN are errors |

```dksh
var cfg = jsonParse('{"name": "dksh", "tags": ["shell", "zig"], "port": 8080}')
print(cfg.name, cfg.tags[1], cfg.port + 1)         # dksh zig 8081
cfg.debug = true
print(jsonStringify(cfg))
# {"name":"dksh","tags":["shell","zig"],"port":8080,"debug":true}
print(jsonStringify(cfg, 2))
# {
#   "name": "dksh",
#   ...
try { jsonParse('{"a": }') } catch (e) { print(e.message) }
# invalid JSON at byte 6: unexpected character
```

---

## Interactive use

Run `dksh` in a terminal. The prompt, line editor, history and completion
are built in; there is no readline dependency.

### Editing keys

| Keys | Action |
|---|---|
| Ctrl-A / Ctrl-E, Home / End | start / end of line (End at the end accepts the suggestion) |
| Ctrl-B / Ctrl-F, Left / Right | back / forward one character (Right at the end accepts the suggestion) |
| Alt-B / Alt-F, Ctrl-Left / Ctrl-Right | back / forward one word |
| Ctrl-D | delete the character under the cursor; **on an empty line, exit** |
| Backspace, Ctrl-H, Delete | delete backwards / forwards |
| Ctrl-K | kill to end of line |
| Ctrl-U | kill to start of line |
| Ctrl-W, Alt-Backspace | kill the previous word |
| Alt-D | kill the next word |
| Ctrl-Y | paste the last killed text |
| Ctrl-T | swap the characters around the cursor |
| Ctrl-L | clear the screen |
| Ctrl-C | cancel the current line |
| Up / Down, Ctrl-P / Ctrl-N | previous / next history entry; with text already typed, only entries that **start with it** |
| Ctrl-R | incremental history search (Ctrl-R again for older matches, Enter to run, Ctrl-G to cancel) |
| Tab | complete (press twice to list candidates) |
| Enter | run the line; if a brace, quote or parenthesis is unclosed, continue on the next line |

Multi-line input just works:

```
u@host ~ > if (true) {
...   print("multi-line")
... }
multi-line
```

### Tab completion

- **Command position:** keywords, builtins, functions, variables, standard
  library functions and executables in `PATH`.
- **Argument position:** files and directories, quoted correctly when they
  contain spaces; `~/` is understood.
- **After `$` or inside `${`:** variable names.
- **After a dot on a variable:** fields and methods of maps and objects, and
  the methods of regexes.
- **Per-command completion:** define `fn complete_<command>(words, word)` that
  returns an array of candidate strings. `words` holds the command's words
  typed so far and `word` the one being completed. Return `null` to fall back
  to file names. Characters in the command name other than letters, digits
  and `_` become `_`.

```dksh
fn complete_deploy(words, word) {
    if (len(words) == 1) { return ["staging", "production", "preview"] }
    if (words[1] == "staging") { return ["--dry-run", "--force"] }
    return null
}
# Now:  deploy st<Tab>  ->  deploy staging
#       deploy staging -<Tab><Tab>  lists --dry-run --force
```

### Suggestions and colors

A grey **suggestion** from your history follows the cursor; Right, End or
Ctrl-E accepts it. Syntax colors: command words are green when they resolve
to a function, builtin or executable and red when they do not; keywords are
blue, quoted text yellow, `$variables` cyan, comments grey. Set `NO_COLOR`
(or use `TERM=dumb`) to turn both off.

### The prompt

dksh offers two ways to set the prompt, and you can mix them.

**1. `PS1` and `PS2` with bash escapes.** Set `env.PS1` (or `var PS1`) in your
`dkshrc.dksh`. `PS2` is the continuation prompt shown while a brace, quote or
parenthesis is open (default `... `). A `PS1` exported by a parent shell is
honored too.

```dksh
env.PS1 = '\[\e[32m\]\u@\h\[\e[0m\]:\[\e[34m\]\w\[\e[0m\]\$ '
env.PS2 = '> '
env.PROMPT_DIRTRIM = "3"       # show at most the last 3 directories in \w
```

Use **single quotes** so the backslashes and `$` reach the prompt code
unchanged.

| Escape | Expands to |
|---|---|
| `\u` | user name |
| `\h`, `\H` | host name up to the first dot / the full host name |
| `\w` | working directory, with the home directory as `~` (see `PROMPT_DIRTRIM`) |
| `\W` | basename of the working directory (`~` in your home) |
| `\$` | `#` for root, `$` otherwise |
| `\t`, `\T` | time `HH:MM:SS`, 24-hour / 12-hour |
| `\@`, `\A` | time `HH:MM AM/PM` / `HH:MM` |
| `\d` | date, like `Sat Oct 31` |
| `\D{format}` | time with any `date()` format: `\D{%Y-%m-%d %H:%M}` (empty braces: `%H:%M:%S`) |
| `\j` | number of jobs the shell is managing |
| `\!` | history number of this command |
| `\#` | command number of this command in the session |
| `\?` | **dksh extension:** exit status of the previous command |
| `\s`, `\v`, `\V` | `dksh`, version `0.0`, version `0.0.1` |
| `\l` | name of the terminal device |
| `\n`, `\r`, `\a`, `\e` | newline, carriage return, bell, escape character |
| `\nnn` | the character with that octal code |
| `\\` | a backslash |
| `\[`, `\]` | start/end of a run of non-printing characters (colors); they take no width on the line |

After the escapes are expanded, dksh string interpolation runs, so a prompt
can compute anything:

```dksh
env.PS1 = '\w ${status(test -w .) == 0 ? "" : "[ro] "}$(git branch --show-current 2>/dev/null) \$ '
env.PS1 = '[\?] ${env.USER}@\h > '
```

`${expr}` is any dksh expression, `$name` a variable, `$(cmd)` command
output. If the template cannot be evaluated (an undefined name, a syntax
error), dksh prints one error and shows the template as it is, so you always
get a prompt.

**2. A `prompt()` function.** If you define `fn prompt()`, it wins over `PS1`.
It returns the whole prompt string and may use any code. Escape sequences in
the returned string take no width. Use `expandPrompt()` inside it to reuse the
escapes:

```dksh
fn prompt() {
    var branch = $(git branch --show-current 2>/dev/null)
    var tag = branch == "" ? "" : " (${branch})"
    return expandPrompt('\[\e[36m\]\w\[\e[0m\]') + tag + " > "
}
```

`expandPrompt(template)` returns what `PS1` would show for a template, which
also makes a prompt easy to preview:

```dksh
print(expandPrompt('\u@\h:\w\$ '))      # dakota@box:~/src$
```

**`precmd()`.** If you define `fn precmd()`, it runs before every prompt,
like bash's `PROMPT_COMMAND`. Use it to set the window title or refresh data
the prompt shows:

```dksh
fn precmd() {
    printf("\e]0;%s\e\\", shortPath(cwd()))       # terminal title (OSC 0, ST-terminated)
}
```

If no `PS1` or `prompt` is defined, the default is `user@host dir > `
(`#` instead of `>` for root).

### Startup files

| File | Read by |
|---|---|
| `/etc/dksh/profile.dksh` | login shells |
| `$XDG_CONFIG_HOME/dksh/profile.dksh` (default `~/.config/dksh/`) | login shells |
| `/etc/dksh/dkshrc.dksh` | interactive shells |
| `$XDG_CONFIG_HOME/dksh/dkshrc.dksh` | interactive shells |

Scripts read none of these. dksh never reads `/etc/profile` (it is `sh`
syntax); systems that use dksh as a login shell ship `/etc/dksh/profile.dksh`
instead. Example `~/.config/dksh/dkshrc.dksh`:

```dksh
env.EDITOR = "vi"
env.PATH = "${env.HOME}/bin:${env.PATH}"

fn ll(dir = ".") { ls -la $dir }
fn mkcd(dir) { mkdir -p $dir; cd $dir }
fn up(n = 1) {
    var p = ""
    for (var i = 0; i < n; i++) { p = p + "../" }
    cd $p
}

fn prompt() { return "${shortPath(cwd())} > " }
```

There are no aliases; functions do the same job and take arguments:
`ll /etc`, `mkcd a/b/c`, `up 2`.

### History

Every command is appended to `$XDG_STATE_HOME/dksh/history` (default
`~/.local/state/dksh/history`) as it runs, so sessions share it. The
`history` command prints it.

### Job control

- Every pipeline runs in its own process group; the foreground job owns the
  terminal.
- **Ctrl-C** interrupts the foreground job, not the shell. **Ctrl-Z** stops it.
- `jobs` lists jobs; `fg [%n]` and `bg [%n]` resume one in the foreground or
  background; `wait [%n]` waits; `disown [%n]` forgets one.
- When a background job finishes, the shell reports it before the next prompt.
- In scripts job control is off: Ctrl-C ends the script, and `&` just runs the
  command in the background.

```
u@host ~ > sleep 100
^Z
[1]+  Stopped    sleep 100
u@host ~ > bg
[1]+  Running    sleep 100
u@host ~ > jobs
[1]+  Running    sleep 100
u@host ~ > fg
sleep 100
^C
u@host ~ >
```

---

## Using dksh as your login shell

dksh is a single static binary, so it can be a login shell even when
`/usr/lib` is damaged. To try it safely:

```sh
# 1. install the binary and the default startup files
sudo install -m 755 zig-out/bin/dksh /usr/bin/dksh
sudo mkdir -p /etc/dksh
sudo cp zig-out/share/dksh/profile.dksh /etc/dksh/profile.dksh
sudo cp zig-out/share/dksh/dkshrc.dksh  /etc/dksh/dkshrc.dksh   # optional

# 2. register it as a valid login shell
echo /usr/bin/dksh | sudo tee -a /etc/shells

# 3. test BEFORE changing your shell: a login session as a throwaway user
sudo useradd -m -s /usr/bin/dksh dkshtest
sudo su - dkshtest                    # interactive login
sudo su - dkshtest -c 'echo $PATH'    # non-interactive login
ssh dkshtest@localhost 'echo ok'      # remote command

# 4. only then
chsh -s /usr/bin/dksh
```

Keep a second root session (or a root account with bash) open while you test,
and note `chsh -s /bin/bash` is the way back.

**What runs when:**

| How it starts | Reads |
|---|---|
| console login, `su -`, `sudo -i`, `ssh host` (interactive) | profile files, then the rc files |
| `su - user -c cmd`, `sudo -i cmd` (login, non-interactive) | profile files, then runs `cmd` |
| `ssh host cmd`, `scp`, `rsync`, `sftp`, `su user -c cmd` | nothing: runs `$SHELL -c cmd` |
| `dksh script.dksh` | nothing |

dksh never reads `/etc/profile` or `~/.profile` (they are `sh` syntax). Put
what they would set up in `/etc/dksh/profile.dksh` or
`~/.config/dksh/profile.dksh`: `PATH`, `umask`, `ulimit`, `EDITOR`, and so on.
When the terminal hangs up, dksh sends SIGHUP to its jobs and exits.

```dksh
# /etc/dksh/profile.dksh
if (!("PATH" in env)) {
    env.PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
}
umask 022
ulimit -c 0          # no core files
```

**The catch: tools that send POSIX shell syntax to `$SHELL -c`.** `ssh host
'cmd'` hands the string to your login shell. Plain commands, `&&`, `;`, `|`,
`$(...)`, `2>&1`, `~` and `$HOME` all work in dksh. These do not, because
they are `sh`-only syntax:

| Written by a tool or by habit | In dksh |
|---|---|
| `VAR=value cmd` | `env.VAR = "value"` first, or `env VAR=value cmd` |
| `export VAR=value` | `env.VAR = "value"` |
| `cmd >&2` | `cmd 2>&1`, or `printErr(...)` |
| `$((1 + 2))`, `${var:-default}` | expressions: `1 + 2` |
| `[ -f x ]`, `[[ ... ]]` | `test -f x`, or `isFile("x")` in an expression |

Most tools are fine (Ansible, make, git hooks and cron all use `/bin/sh`
explicitly). If one breaks, make it call `sh -c '...'` itself, or run the
command as `ssh host sh -c '...'` / `ssh host bash -c '...'`. Executable
scripts with a `#!/usr/bin/bash` line always run under bash, whatever your
login shell is (see Shebang).

---

## Debugging a script

**Syntax and names:** `dksh -n script.dksh` parses and resolves without
running anything. It catches syntax errors, undefined variables, `super.init`
omissions and warns about shadowed variables.

**What actually ran:** `dksh -x script.dksh` prints each command to stderr
after expansion, with arguments quoted so word boundaries are visible:

```dksh
# trace.dksh
var f = "a b"
echo $f "it's" | tr a-z A-Z
```

```
$ dksh -x trace.dksh
+ echo 'a b' 'it'\''s'
+ tr a-z A-Z
A B IT'S
```

**How it was parsed:** `dksh --tree script.dksh` draws the syntax tree, with
`[line:col]` on statements:

```
$ dksh --tree -c 'var x = 1 + 2'
Program
`-- var x   [1:1]
    `-- +
        |-- 1
        `-- 2
```

`--dump-ast` prints the same thing as compact S-expressions. Neither format is
stable; they are for debugging the language itself.

---

## Coming from bash

| bash | dksh |
|---|---|
| `x=5` | `var x = 5` |
| `readonly x=5` | `const x = 5` |
| `echo "$x"` | `echo $x` (never splits) or `print(x)` |
| `export X=1` | `env.X = "1"` |
| `$((a + b))` | `a + b` in expression mode: `var s = a + b` |
| `${#arr[@]}` | `len(arr)` |
| `"${arr[@]}"` | `@arr` |
| `arr+=(x)` | `push(arr, x)` |
| `for f in *.txt; do ...; done` | `for (f in glob("*.txt")) { ... }` or `for (f in @(ls *.txt)) { ... }` |
| `if [ -f x ]; then ...; fi` | `if (isFile("x")) { ... }` |
| `if [ "$a" = "b" ]` | `if (a == "b")` |
| `[[ $s =~ ^a ]]` | `if (s =~ '^a') { ... }` |
| `x=$(cmd)` | `var x = $(cmd)` |
| `mapfile -t a < <(cmd)` | `var a = @(cmd)` |
| `cmd; echo $?` | `var rc = status(cmd)` |
| `set -e` | the default for scripts (`+e` turns it off) |
| `cmd \|\| true` | `try { cmd } catch (e) { }` or `status(cmd)` |
| `if ! cmd; then` | `if ! cmd { ... }` |
| `f() { echo $1; }` | `fn f(a) { print(a) }` |
| `trap 'rm $f' EXIT` | `trap("EXIT", fn(s) { rm -f $f })` |
| `(cd /tmp; ls)` | `subshell { cd /tmp; ls }` |
| `alias ll='ls -l'` | `fn ll(dir = ".") { ls -l $dir }` |
| `cat <<EOF ... EOF` | `cat <<< "..."` with a multi-line string |
| `echo foo >&2` | `printErr("foo")` |
| `a{1,2}.txt` | not supported; build the list: `["a1.txt", "a2.txt"]` |
| `eval "$s"` | not supported |
| `source f` | `source f` (runs in the global scope) |
| `$RANDOM`, `$$`, `$?` | `env`-less: use `pid()`, `status(...)`; no `$RANDOM` |

Not supported (and not planned): POSIX `sh`/bash syntax of any kind,
here-documents, `eval`, aliases, bitwise operators, brace expansion,
process substitution (`<(cmd)`), `>&2`-style descriptor duplication other than
`2>&1`.

---

## A complete example

A log-rotation script using most of the language:

```dksh
#!/usr/bin/dksh
# rotate.dksh DIR [DAYS] — compress old logs, write a JSON report.

if (len(args) < 1) {
    printErr("usage: rotate.dksh DIR [DAYS]")
    exit(2)
}

const logDir = args[0]
const days = len(args) > 1 ? int(args[1]) : 7
const lock = "/tmp/rotate.lock"

if (exists(lock)) { error("another rotation is running (${lock})") }
writeFile(lock, str(pid()))
trap("EXIT", fn(sig) { rm -f $lock })

class Report {
    var done = []
    var failed = []
    var bytes = 0

    fn add(name, size) {
        push(self.done, name)
        self.bytes += size
    }
    fn fail(name, why) { push(self.failed, {file: name, reason: why}) }
    fn toJson() {
        return jsonStringify({compressed: self.done, failed: self.failed,
                              bytes: self.bytes, finished: date("%F %T")}, 2)
    }
}

var report = Report()
var old = @(find $logDir -name '*.log' -mtime +${days})

for (path in old) {
    var size = int($(stat -c %s $path))
    try {
        gzip -f $path
        report.add(baseName(path), size)
    } catch (e) {
        report.fail(baseName(path), e.message)
    }
}

writeFile("${logDir}/rotation-report.json", report.toJson())
printf("%d compressed, %d failed, %d bytes\n", len(report.done), len(report.failed), report.bytes)
if (len(report.failed) > 0) { exit(1) }
```

Run it with tracing to see every command:

```sh
dksh -x rotate.dksh /var/log/myapp 14
```

---

## Known limits

- A standalone `}` word always ends a command (`echo }` needs quotes).
- Functions used as commands run in-process; inside a pipeline or as a
  background job they run in a forked child, so their variable changes do not
  persist.
- Memory is reclaimed by a conservative tracing collector, not reference
  counting; reference cycles are collected.
- `$( )` and `@( )` hold one command list, not several statements.
- A trap handler runs between statements; it cannot interrupt a command that
  is already running.
- `readLines` reads the whole input first; there is no lazy line iterator.
- There are no aliases and no streaming line iterator; use functions.
- Interactive editing counts every character as one column, so wide
  characters (CJK, emoji) can misalign a wrapped line.
