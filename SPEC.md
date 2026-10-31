# dksh — Specification

Status: **Draft v0.2**. Anything marked **OPEN** is an undecided question.
Resolve it here before writing code that depends on it.

---

## 1. Vision

A classic interactive Unix shell (pipelines, redirection, job control, tab
completion) with a scripting language that reads like C instead of `sh`.

You use it like bash at the prompt. You write scripts in it the way you'd
write a small C or JavaScript program: declared variables, real types,
braces, functions with named parameters, and errors that stop the script
instead of being silently ignored.

```
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

### 1.1 Relationship to the rest of the system

- `/bin/sh` is dash and `/bin/bash` is bash. They run every existing script
  unchanged.
- dksh is a login shell and its own scripting language. dksh scripts start
  with `#!/usr/bin/dksh`.
- dksh never tries to run `sh` or bash syntax.

## 2. Goals and non-goals

### Goals (v1)

- A comfortable interactive shell: line editing, history, history search,
  tab completion, a programmable prompt, and job control.
- A scripting language with C-style control flow and expressions, real
  types, lexical scoping, and functions.
- No word splitting and no surprise glob expansion: a variable is always
  exactly one argument unless you explicitly splice an array.
- Errors are loud by default: a failed command stops a script unless the
  script checks for it.
- Error messages point at the file, line and column, with the source line
  shown.
- A single static binary written in pure Zig, with no libc and no runtime
  dependencies, so it works on dkrescue even when `/usr/lib` is damaged.

### Non-goals (v1)

These are explicitly out of scope. Adding any of them requires changing this
spec first.

- **POSIX `sh` or bash compatibility** of any kind.
- **Here-documents.** Multi-line strings and `<<<` cover the same need.
- **`eval`** of strings as code.
- **Aliases.** Functions do the same job.
- **Multiple inheritance, interfaces or mixins.** Classes have single
  inheritance only (see 5.9).
- **Regex backreferences and lookaround.** They rule out the linear-time
  engine (see 5.12).
- **Bitwise operators.**
- **NSS, locales and DNS.** Users and groups come straight from `/etc/passwd`
  and `/etc/group` (see 4.2).
- **A plugin or extension API.**
- **Windows or macOS.** Linux only. Because no libc is linked, the same
  binary runs on musl and glibc systems alike.

## 3. Stack

| Layer | Choice | Notes |
|---|---|---|
| Language | **Zig**, pure | Same pinned version as dkde. No C code in the repository. |
| libc | **None** | The binary talks to the kernel through Zig's standard library (see 4.2). |
| Dependencies | **None** | No readline, no PCRE. The line editor and regex engine are ours. |
| Linking | **Static**, always | The same binary runs on dkrescue and on any x86_64 Linux. |
| Build | `zig build` | Default target `x86_64-linux-none`; `aarch64-linux-none` should build too. |

## 4. Architecture

dksh is one binary built from these modules:

| Module | Job |
|---|---|
| `lexer` | Turns source into tokens. Mode-aware: command mode and expression mode tokenize differently (see 5.1). |
| `parser` | Recursive descent. Produces an AST where every node carries its source span for error messages. |
| `resolver` | Resolves names to lexical scopes before execution, so typos in variable names are caught early. |
| `interp` | Tree-walking interpreter for statements and expressions. |
| `exec` | Runs external commands: `fork`/`exec`, pipes, redirections, process groups. |
| `jobs` | Job control: process groups, terminal ownership, `SIGCHLD`, stopped jobs. |
| `value` | Runtime values and their memory management (see 5.3). |
| `builtins` | Built-in commands and the standard library functions. |
| `editor` | Interactive line editor on raw termios. |
| `complete` | Tab completion. |
| `config` | Startup files and the history file. |

### 4.1 Running modes

| Invocation | Behaviour |
|---|---|
| `dksh` on a terminal | Interactive. |
| `dksh -l` or `argv[0]` starting with `-` | Interactive login shell (see 6.4). |
| `dksh script.dksh args...` | Runs the script. `args` is available as the `args` array. |
| `dksh -c 'source'` | Runs the string. |
| `dksh -n script.dksh` | Parses and resolves only; reports errors without running anything. |
| `dksh -x ...` | Traces each command to standard error before it runs. |
| `dksh -i` | Interactive even when standard input is not a terminal. |
| `dksh -e` / `+e` | Failed commands stop the script (default) / do not. |
| `dksh --dump-ast ...` | Prints the syntax tree instead of running. |
| `dksh --tree ...` | Same, drawn as an ASCII tree. |
| `dksh -v` / `--version`, `-h` / `--help` | Version and usage. |

### 4.2 No libc

dksh never links a C library. Everything libc would normally provide comes
from Zig's standard library or from dksh's own code:

| Need | Provided by |
|---|---|
| System calls (`fork`, `execve`, `pipe`, `dup2`, `setpgid`, `waitpid`, signals) | `std.os.linux` / `std.posix` |
| Terminal control (`tcgetattr`, `tcsetpgrp`, window size) | termios ioctls through `std.posix` |
| `~user` expansion, `type`, prompt user name | parsing `/etc/passwd` and `/etc/group` directly |
| Host name | the `uname` system call |
| Local time (prompt, `date()`) | parsing `/etc/localtime` (TZif) with `std.tz`; `TZ` overrides it |
| Globbing and `fnmatch` | dksh's own `glob` module |
| Number formatting | `std.fmt` (see 7.3) |

This is also why NSS (LDAP or network user databases) and locales are
non-goals: there's no libc to provide them. On dkrescue that costs nothing.

## 5. Language

### 5.1 Command mode and expression mode

A shell has to keep commands terse (`ls -la > out.txt`) while a programming
language needs operators like `>` and `<`. dksh solves this with two modes and
fixed rules for which one applies. There is no guessing.

**Expression mode** is used:

- inside the parentheses of `if (...)`, `while (...)` and `for (...)`
- after `=` in `var`, `const` and assignments, and after `return`
- inside `${...}` in a string
- inside the parentheses of a function call: `name(...)`
- inside `[...]` array literals and `{...}` map literals

**Command mode** is used everywhere else.

A statement is classified by how it starts:

| Statement starts with | It is |
|---|---|
| a keyword (`var`, `const`, `if`, `while`, `for`, `fn`, `class`, `return`, `break`, `continue`, `try`, `import`) | that construct |
| a name declared in scope, followed by `=`, `+=`, `-=`, `*=`, `/=`, `++` or `--` | an assignment |
| a name immediately followed by `(` with no space | a function call |
| anything else | a command |

Because scoping is lexical (5.4), the parser knows which names are declared,
so `x = 5` is an assignment when `x` is a variable and the error
"`x` is not declared; use `var x = 5`" when it isn't. It is never silently
run as a command named `x`.

### 5.2 Grammar summary

The full grammar lives in `docs/grammar.ebnf` and is the source of truth.
In outline:

```
program     = { statement terminator } ;
terminator  = newline | ";" ;

statement   = varDecl | assignment | ifStmt | whileStmt | forStmt
            | fnDecl | classDecl | returnStmt | tryStmt | importStmt
            | "break" | "continue" | callStmt | commandList ;

varDecl     = ( "var" | "const" ) name "=" expr ;
ifStmt      = "if" condition block { "else" "if" condition block } [ "else" block ] ;
whileStmt   = "while" condition block ;
condition   = "(" expr ")" | commandList ;       (* expression or command status *)
forStmt     = "for" "(" ( name "in" expr
                        | [ varDecl ] ";" [ expr ] ";" [ expr ] ) ")" block ;
fnDecl      = "fn" name "(" [ params ] ")" block ;
params      = param { "," param } ;
param       = name [ "=" expr ] ;
tryStmt     = "try" block "catch" "(" name ")" block ;

commandList = pipeline { ( "&&" | "||" ) pipeline } [ "&" ] ;
pipeline    = command { "|" command } ;
command     = word { word | redirect } ;
redirect    = ( ">" | ">>" | "<" | "2>" | "2>>" | "&>" | "2>&1" | "<<<" ) word ;
```

### 5.3 Values and types

| Type | Literal | Notes |
|---|---|---|
| `null` | `null` | |
| `bool` | `true`, `false` | |
| `int` | `42`, `0x1f`, `0o755`, `1_000` | 64-bit signed. Overflow is an error, not wraparound. |
| `float` | `3.14`, `1e-3` | 64-bit. |
| `string` | `"…"`, `'…'`, `"""…"""` | Byte strings, expected to be UTF-8. Immutable. |
| `array` | `[1, 2, 3]` | Ordered, growable. |
| `map` | `{"key": 1, name: 2}` | Insertion-ordered. Bare keys are strings. |
| `fn` | `fn(x) { … }` | First-class, closures capture by reference. |
| `regex` | `regex('^\d+$')` | A compiled regular expression (5.12). |
| object | `Point(1, 2)` | An instance of a class (5.9). |

- There is no implicit conversion between types except into strings for
  interpolation and command arguments. `"5" + 1` is an error; use
  `int("5") + 1`.
- Arrays, maps and objects are reference values. Strings, numbers, booleans
  and `null` are plain values.
- Memory is managed by a conservative mark-and-sweep collector (`src/gc.zig`)
  behind the normal allocator interface, not by reference counting. This is
  invisible to scripts, and it also collects reference cycles.

### 5.4 Variables and scope

- `var` declares a mutable variable, `const` an immutable one. Both require
  an initial value.
- Scope is lexical and block-based: a variable declared inside `{ }` is gone
  after the closing brace.
- Shadowing an outer variable in an inner block is allowed and produces a
  warning with `dksh -n`.
- Shell variables are **not** environment variables. The environment is the
  `env` map: `env.PATH`, `env["HOME"]`. Assigning to `env.NAME` exports it
  to commands started afterwards.
- In command mode, `$name` looks up a variable first, then `env`.

### 5.5 Strings and expansion

- `"double quotes"` interpolate: `"${expr}"` and the short form `"$name"`.
- `'single quotes'` are literal.
- `"""triple quotes"""` are multi-line and interpolate. The common leading
  indentation is removed.
- Escapes in double quotes: `\n \t \\ \" \$ \u{…}`.

**In command mode, the three rules that fix bash:**

1. **No word splitting.** `$file` is always exactly one argument, even if it
   contains spaces.
2. **Splicing is explicit.** `@list` expands an array into one argument per
   element. `$list` on an array is an error.
3. **Globs that match nothing are an error**, not a literal `*.txt` passed
   to the command. Quoted words are never globbed.

### 5.6 Commands, pipelines and capture

- Pipelines `|`, sequencing `;` and newline, `&&`, `||`, background `&`.
- Redirections as in 5.2. `<<< expr` sends a string as standard input.
- `$(command)` runs a command and evaluates to its standard output as a
  string, with one trailing newline removed.
- `@(command)` evaluates to an array of its output lines.
- In expression mode, `status(command)` runs a command and evaluates to its
  exit status as an `int` without raising an error.

### 5.7 Functions

```
fn greet(name, greeting = "Hello") {
    return "${greeting}, ${name}!"
}

var msg = greet("Dakota")                 # called as an expression
greet Dakota Howdy | tr a-z A-Z           # called as a command
```

- Parameters can have defaults. Calling with too few or too many arguments
  is an error.
- Called **as an expression**, a function returns the value of `return`
  (`null` if none).
- Called **as a command**, every argument arrives as a string, its output is
  whatever it prints, and its exit status is 0 unless it raises an error.
  This is what lets functions sit in pipelines.
- Functions are closures and can be stored in variables, arrays and maps.

### 5.8 Errors

- In a script, a command that exits non-zero **raises an error**, which stops
  the script unless it's caught.
- Except, as in any sane shell:
  - the command is the condition of `if` or `while`
  - it's on the left of `&&` or `||`
  - it's wrapped in `status(...)`
- A pipeline fails if any command in it fails, not just the last one.
- `try { … } catch (e) { … } finally { … }` catches errors; `finally` runs
  however the body ends, and either clause may be left out (not both).
- `try { … } catch (e) { … }` catches errors. `e` is a map with `message`,
  `status` (exit status or `null`), `file`, `line` and `column`.
- `error("message")` raises an error from script code.
- At the interactive prompt, errors are reported and the prompt returns. The
  shell never exits because a command failed.

Error output always shows where the problem is:

```
error: command failed with status 1: grep -q root /etc/shadow
  --> backup.dksh:14:5
   |
14 |     grep -q root /etc/shadow
   |     ^^^^^^^^^^^^^^^^^^^^^^^^
```

### 5.9 Classes (optional)

Classes are part of the language but entirely opt-in: a script that never
uses `class` pays nothing for it.

```
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
}

var usb = Mount("/dev/sdb1", "/mnt/usb")
usb.mount()
```

- A class has fields (declared with `var` and a default value) and methods
  (`fn`). `self` refers to the instance inside methods.
- Calling the class name constructs an instance and runs `init` with the
  arguments, if `init` exists.
- Fields not declared in the class can't be added later; assigning to an
  undeclared field is an error.
- Objects are reference values, compared by identity.
- `str(obj)` calls `obj.toString()` if the class defines it.

**Inheritance** is single, which is enough to share setup and checks
between related types without the complications of multiple inheritance:

```
class UsbMount extends Mount {
    var label = ""

    fn init(device, point, label) {
        super.init(device, point)
        self.label = label
    }

    fn mount() {
        print("mounting ${self.label}")
        super.mount()
    }
}
```

- `extends` names one parent class. The child has all the parent's fields
  and methods, and can add its own.
- A method with the same name as a parent method overrides it.
  `super.name(...)` calls the parent's version.
- A child that defines `init` must call `super.init(...)` if the parent has
  one; leaving it out is an error caught by the resolver.
- Redeclaring a parent's field in the child is an error.
- `isInstance(obj, Class)` is true for the class and every class that
  extends it.

### 5.10 Modules

```
import "lib/disks.dksh" as disks
disks.listDevices()
```

- `import` runs a file once and binds its top-level `const`, `fn` and
  `class` declarations under the given name.
- Relative paths resolve from the importing file's directory. Bare names
  search `$XDG_DATA_HOME/dksh/lib` and `/usr/share/dksh/lib`.

### 5.11 Operators

From highest to lowest precedence:

| Operators | Associativity |
|---|---|
| `()` call, `[]` index, `.` member | left |
| `!`, unary `-` | right |
| `*`, `/`, `%` | left |
| `+`, `-` | left |
| `<`, `<=`, `>`, `>=` | left |
| `==`, `!=`, `=~`, `!~` | left |
| `&&` | left |
| `\|\|` | left |
| `? :` | right |

- `+` concatenates strings and arrays, and adds numbers.
- `/` on two ints is integer division; dividing by zero is an error.
- `=~` matches a string against a regex: `line =~ '^\s*#'`. The right side
  may be a `regex` value or a string, which is compiled once and cached.
  `!~` is its negation. Both sit with `==` and `!=` in the precedence table.
- `&&` and `||` short-circuit, and mean the same thing as they do between
  commands: "only if this succeeded" and "only if this failed".
- `in` tests membership: `"x" in list`, `"key" in map`.

### 5.12 Regular expressions

dksh has its own regex engine, written in Zig. It is **guaranteed linear
time** in the length of the input (a Pike VM over a compiled NFA, the same
approach as RE2 and Go's `regexp`). A badly written pattern can be slow to
compile but can never hang the shell on a large file, which matters when
the shell is what you're using to recover a system.

**Syntax** (single-quoted strings are literal, so backslashes don't need
doubling):

| Feature | Syntax |
|---|---|
| Literals and escapes | `a`, `\.`, `\n`, `\t`, `\x41`, `\u{263A}` |
| Any character | `.` (not newline unless the `s` flag is set) |
| Classes | `[abc]`, `[^a-z]`, `\d \D \w \W \s \S`, POSIX `[[:alpha:]]` etc. |
| Anchors | `^ $` (line-based with the `m` flag), `\A \z`, `\b \B` |
| Quantifiers | `* + ? {n} {n,} {n,m}`, lazy forms `*? +? ?? {n,m}?` |
| Groups | `( )` capturing, `(?: )` non-capturing, `(?<name> )` named |
| Alternation | `a\|b` |
| Flags | `i` case-insensitive, `m` multi-line, `s` dot matches newline, `x` extended (whitespace and `#` comments ignored) |

Matching works on UTF-8: `.` and classes match whole code points, and
`\w`/`\d` are ASCII unless the `u` flag selects Unicode properties.

With `u`, `\w`, `\d`, `\s` and `\b` follow Unicode, `i` uses Unicode case
folding, and `\p{…}`/`\P{…}` match general categories (`\p{L}`, `\p{Lu}`)
and scripts (`\p{Greek}`).

The tables come from the Unicode Character Database. The UCD files are
vendored under `data/ucd/` with their Unicode version recorded, and a Zig
generator run by `build.zig` turns them into compact range tables at build
time. Nothing is downloaded during a build, and updating Unicode is a
deliberate change to the vendored files.

**Not supported** (see non-goals): backreferences (`\1`) and lookaround
(`(?=…)`, `(?<=…)`). Patterns that use them are rejected when compiled, with
an error pointing at the offending part of the pattern.

**API:**

```
const kv = regex('^(?<key>\w+)\s*=\s*(?<value>.*)$', "m")

for (line in split(readFile("/etc/dksh/settings"), "\n")) {
    var m = kv.match(line)
    if (m != null) {
        print("${m.key} -> ${m.value}")
    }
}

if (env.HOME =~ '^/root') { print("running as root") }
```

| Method | Returns |
|---|---|
| `regex(pattern, flags = "")` | a compiled `regex`; an invalid pattern is an error |
| `re.test(s)` | `bool` |
| `re.match(s)` | `null`, or a map: `0` is the whole match, `1`… are groups, named groups by name, plus `start` and `end` |
| `re.matchAll(s)` | an array of match maps |
| `re.replace(s, replacement, count = 0)` | a string. `$1`, `${name}` in `replacement` refer to groups; a function receives the match map. `count = 0` means all. |
| `re.split(s, limit = 0)` | an array of strings |


## 6. Interactive shell

### 6.1 Line editor

- Emacs-style keys by default (Ctrl-A, Ctrl-E, Ctrl-W, Alt-B, Alt-F, …).
- Multi-line editing: an unclosed brace, quote or parenthesis continues on
  the next line.
- History stored in `$XDG_STATE_HOME/dksh/history`, shared between sessions
  by appending each command as it's run.
- Ctrl-R incremental history search.
- Up/Down with a partly typed line search history by prefix.

### 6.2 Completion

- Command position: builtins, functions, and executables in `PATH`.
- Argument position: files and directories, quoted correctly when they
  contain spaces.
- After `$` or inside `${`: variable names.
- After `.` on an object or map: field and method names, where known.
- Per-command completion is post-v1.

### 6.3 Prompt

The prompt is whatever the `prompt` function returns, so it can show
anything a script can compute:

```
fn prompt() {
    return "${env.USER}@${hostName()} ${shortPath(cwd())} > "
}
```

If no `prompt` function is defined, the default is `user@host dir > `,
with `#` instead of `>` for root.

### 6.4 Startup files

| File | Read by |
|---|---|
| `/etc/dksh/profile.dksh` | login shells |
| `$XDG_CONFIG_HOME/dksh/profile.dksh` | login shells |
| `/etc/dksh/dkshrc.dksh` | interactive shells |
| `$XDG_CONFIG_HOME/dksh/dkshrc.dksh` | interactive shells |

Scripts read none of these.

**dksh has its own login profile.** `/etc/profile` is `sh` syntax and dksh
never reads it. Systems that use dksh as a login shell ship
`/etc/dksh/profile.dksh` with the equivalent settings (`PATH`, `umask`,
locale-independent defaults). dksh installs a default one from
`data/profile.dksh`, and dkrescue's build installs its own.

### 6.5 Job control

- Every pipeline runs in its own process group. The foreground job owns the
  terminal (`tcsetpgrp`).
- Ctrl-C interrupts the foreground job, not the shell. Ctrl-Z stops it.
- `jobs`, `fg [%n]`, `bg [%n]`, `wait [%n]`, and `disown [%n]`.
- When a background job finishes, the shell reports it before the next
  prompt.
- In scripts job control is off: Ctrl-C ends the script, and `&` just runs
  in the background.

## 7. Built-ins and standard library

### 7.1 Built-in commands

These run inside the shell process, because they change its state:

`cd`, `exit`, `source`, `jobs`, `fg`, `bg`, `wait`, `disown`, `exec`,
`history`, `type` (shows whether a name is a function, builtin or file).

### 7.2 Standard library

Functions callable from expressions. Names are `camelCase`, matching the
rest of the language.

| Area | Functions |
|---|---|
| Output | `print(...)`, `printErr(...)`, `printf(format, ...)`, `sprintf(format, ...)` |
| Regex | `regex(pattern, flags)` and its methods (5.12) |
| Input | `readLine(prompt = "")`, `readPassword(prompt = "")` |
| Types | `type(v)`, `int(v)`, `float(v)`, `str(v)`, `bool(v)`, `isInstance(v, Class)` |
| Collections | `len(v)`, `push(arr, v)`, `pop(arr)`, `keys(map)`, `values(map)`, `sort(arr, cmp = null)`, `map(arr, fn)`, `filter(arr, fn)` |
| Strings | `split(s, sep)`, `join(arr, sep)`, `trim(s)`, `startsWith(s, p)`, `endsWith(s, p)`, `contains(s, sub)`, `replace(s, old, new)`, `upper(s)`, `lower(s)` |
| Files | `exists(p)`, `isFile(p)`, `isDir(p)`, `readFile(p)`, `writeFile(p, s)`, `appendFile(p, s)`, `baseName(p)`, `dirName(p)`, `glob(pattern)` |
| System | `cwd()`, `hostName()`, `pid()`, `shortPath(p)`, `date(format = "%Y-%m-%d %H:%M:%S")`, `exit(status = 0)`, `error(message)`, `status(cmd)` |
| Processes and time | `kill(pid, sig = "TERM")`, `sleep(seconds)`, `now()`, `time(fn)`, `trap(sig, fn)` |
| Input and data | `readLines(path = "-")`, `readStdin()`, `shellQuote(s)`, `jsonParse(s)`, `jsonStringify(v, indent = 0)` |

### 7.3 Number formatting

- **Interpolation and `str()`** print floats as the **shortest string that
  reads back as the same value** (`0.1` prints as `0.1`, not
  `0.1000000000000000055`). Integers print in decimal. A float with no
  fractional part keeps a `.0` (`3.0`), so the type stays visible.
- **`printf` and `sprintf` follow C's format strings**:
  - flags `-`, `+`, space, `#`, `0`; width and precision, including `*`
  - conversions `d i u o x X f F e E g G a A c s %`
  - length modifiers (`l`, `ll`, `h`, `z`, …) are accepted and ignored,
    since every dksh int is 64-bit
  - `%n` is **not** supported, because it writes to memory in C
  - a conversion that doesn't match the argument's type (`%d` with a
    string) is an error, not undefined behaviour

## 8. Shared conventions

- Code conventions and the documentation standard are the same as dkde's
  (sections 6.4 and 6.5 of the dkde spec): `zig fmt`, Zig's official naming,
  `//!` module comments, `///` on every public declaration, comments that
  explain *why*.
- `docs/grammar.ebnf` is the source of truth for syntax. A change to the
  parser that isn't reflected there is a bug.
- `docs/language.md` is the user-facing language guide and is updated in
  the same change as any language feature.

## 9. Repository layout

```
build.zig
build.zig.zon
SPEC.md
docs/
  grammar.ebnf
  language.md
src/
  main.zig
  lexer.zig
  parser.zig
  resolver.zig
  interp.zig
  value.zig
  exec.zig
  jobs.zig
  builtins/
  editor/
  regex/            parser, compiler and Pike VM
  sys/              passwd/group parsing, local time, host name (4.2)
  glob.zig
  format.zig        printf and float formatting (7.3)
  complete.zig
  config.zig
tests/
  spec/             golden tests: name.dksh with name.out / name.err / name.status
  interactive/      line editor and job control tests run through a pty
data/
  dkshrc.dksh       default startup file
  profile.dksh
  ucd/              vendored Unicode Character Database files (5.12)
build/
  gen_unicode.zig   generates regex Unicode tables at build time
```

## 10. Testing

- **Golden tests** (`tests/spec/`): each `.dksh` file runs with its expected
  stdout, stderr and exit status checked byte for byte. Every language
  feature and every error message has at least one.
- **Interactive tests** run the shell under a pseudo-terminal and drive it
  with keystrokes: line editing, completion, Ctrl-C, Ctrl-Z, `fg`.
- **Unit tests** for the lexer, parser and value types.
- **Parser fuzzing** with Zig's built-in fuzzer: the parser must never crash
  or hang, whatever the input.
- `dksh -n` is run over every golden test to make sure parse-only mode
  agrees with execution.

## 11. Milestones

Each milestone is merged only when all its acceptance criteria pass.

### S0 — Commands
- Lexer and parser for command mode. Simple commands, pipelines,
  redirections, `&&`, `||`, `;`, `&`. `-c` and script files.
- **Done when:** `ls -la | grep conf > out.txt && echo ok` works as a script
  and with `-c`.

### S1 — Values and variables
- `var`, `const`, all types and literals, interpolation, `$name`, `@list`,
  `$(...)`, `@(...)`, `env`, the no-splitting and glob rules.
- **Done when:** a filename with spaces passes through `$file` as one
  argument, and an unmatched glob is an error.

### S2 — Control flow and functions
- `if`/`else`, `while`, both `for` forms, `break`, `continue`, `fn`,
  `return`, closures, functions called as commands.
- **Done when:** a function can be used in a pipeline, and both kinds of
  `if` condition work.

### S3 — Errors
- Failed-command semantics, pipeline failure, `try`/`catch`, `error()`,
  `status()`, and source-located error messages. `dksh -n`.
- **Done when:** every error in the golden tests shows the right file, line,
  column and source line.

### S4 — Interactive shell
- Line editor, history, Ctrl-R, completion, `prompt`, startup files.
- **Done when:** it's comfortable to use dksh as your daily interactive
  shell (job control aside).

### S5 — Job control
- Everything in 6.5.
- **Done when:** `vim`, Ctrl-Z, `bg`, `fg`, and Ctrl-C on a long-running
  pipeline all behave correctly.

### S6 — Standard library
- Everything in 7.2.
- **Done when:** a real dkrescue maintenance script (mounting, backup, log
  checking) can be written without calling out to `awk` or `sed` for basic
  string handling.

### S7 — Classes
- Everything in 5.9, including single inheritance and `super`.
- **Done when:** a child class can override a method, call the parent's
  version with `super`, and `isInstance` works across the hierarchy.

### S8 — Regular expressions
- Everything in 5.12.
- Unicode support with the `u` flag, including `\p{…}`, generated from the
  vendored UCD.
- **Done when:** the engine passes a test suite adapted from RE2's, rejects
  backreferences and lookaround with a clear error, a pathological pattern
  like `(a*)*b` against 100,000 `a`s finishes in linear time, and
  `regex('^\p{Lu}', "u")` matches `Ä` but not `ä`.

### S9 — Modules
- Everything in 5.10.

### S10 — dkrescue integration
- Static `x86_64-linux-none` build, `/etc/dksh/profile.dksh` and
  `dkshrc.dksh`, `/etc/shells` entry, man page.
- **Done when:** a dkrescue image can use dksh as root's login shell, and
  `file /usr/bin/dksh` reports a static binary with no interpreter.

## 12. Implementation notes

Where the implementation made a choice the spec leaves open, or differs:

- **Memory.** A tracing collector replaces reference counting (see 5.3). It
  scans the stack, callee-saved registers and writable data segments, so
  `-fomit-frame-pointer` is disabled. `DKSH_GC_STRESS=N` collects every N
  allocations and is used to test the roots.
- **Pipelines and SIGPIPE.** A non-final stage killed by SIGPIPE (status 141)
  does not fail the pipeline, so `yes | head` works (extends 5.8).
- **`$( )` / `@( )`** contain one command list, not several statements.
- **Command words.** A standalone `}` always ends a command. `$obj.field` in
  command mode is a field access only when the value is a map or object;
  otherwise `.field` stays literal text (so `cp $f $f.bak` works).
- **Functions as commands** run in-process, except inside a pipeline or as a
  background job, where they run in a forked child.
- **Conditions** (`if`, `while`, `?:`, `!`, `&&`, `||`) require real bools.
- **`sort`** returns a new array; its comparator returns an int.
- **Regex errors** show the pattern with a caret under the offending part.
- **`umask`** is also built in, because the default login profile uses it.
- **Additions beyond the original spec:** `finally`, `subshell { }`, `trap()`
  (signal handlers run between statements; `EXIT` runs at shell exit),
  the process, input and JSON functions in 7.2, history suggestions, syntax
  colors and `complete_<command>` functions for per-command completion.
- **Missing commands.** A command that cannot be found is always an error
  (status 127), including as an `if`/`while` condition, so a typo is never a
  silent false. Only `status(...)` turns it into the status `127`.
- **`!` negation.** `! cmd` (or `! a | b`) swaps success and failure and is
  exempt from the raise-on-failure rule, like a condition.
- **Foreign shebangs.** `dksh file` where the first line is `#!interp` for an
  interpreter other than dksh (also `#!/usr/bin/env interp`) executes that
  interpreter on the file with the same arguments, keeping the rule that dksh
  never parses sh or bash syntax. `-n`, `--dump-ast` and `--tree` refuse such
  files (status 2) instead of running them.
- **Prompts.** Besides `fn prompt()` (6.3), `PS1` and `PS2` (a global variable
  or `env`) are expanded with bash's backslash escapes (`\u \h \w \W \$ \t \d
  \D{fmt} \j \! \# \[ \] \e \nnn` ...) plus `\?` (previous status), then with
  dksh string interpolation (`${expr}`, `$name`, `$(cmd)`). Order: `prompt()`,
  then `PS1`, then the default. `PS2` is the continuation prompt, `PROMPT_DIRTRIM`
  trims `\w`, `fn precmd()` runs before each prompt, `fn preexec(cmd)` runs after Enter and before
  the command (errors reported, command still runs), and `expandPrompt(t)`
  renders a template. A template that fails to evaluate is shown unexpanded after
  one error message.
- **Login shells.** `-l` (or an argv[0] starting with `-`) reads the profile
  files in every mode: interactive, `-c` and scripts, as `su - user -c cmd` and
  `sudo -i cmd` need. Checks (`-n`, `--tree`) never execute it. A hangup
  (SIGHUP) from the terminal sends SIGHUP to every job and ends the shell.
  Background jobs and subshells keep their children in the job's own process
  group.
- **`ulimit`** is also built in (`-c -d -f -l -m -n -s -t -u -v`, `-H`, `-S`,
  `-a`), because login profiles use it.
- **Closing braces.** A standalone `}` also ends a command when it is followed
  by `)`, `,`, `]` or `}`, so `fn(s) { rm -f $f }` works as an argument.
- **Parse-only mode** (`dksh -n`) also reports shadowed variables as warnings.

## 13. Open questions

None at the moment.

### Resolved

- Memory management: tracing collector instead of reference counting (12).

- Unicode regex classes: the `u` flag ships in S8 (5.12).
- Login environment: dksh has its own `/etc/dksh/profile.dksh` (6.4).
- Inheritance: single, with `extends` and `super` (5.9).
- Regular expressions: built-in linear-time engine (5.12).
- Float formatting: shortest round-trip (7.3).
- `printf`: C format strings, minus `%n` (7.3).
- Implementation: pure Zig, no libc, always static (3, 4.2).
