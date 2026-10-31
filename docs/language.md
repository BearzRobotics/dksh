# The dksh language

dksh is a Unix shell whose scripting language reads like C. This guide is
the user-facing reference; `SPEC.md` has the design rationale and
`docs/grammar.ebnf` the exact syntax.

## Running

| Command | Meaning |
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
| `--tree` | like `--dump-ast`, but drawn as an ASCII tree (`|--`, `` `-- ``), with `[line:col]` on statements |
| `-v`, `--version` | print the version and Unicode data version |
| `-h`, `--help` | print usage |
| `--` | end of options |

Short flags combine: `-nx`, `-xc 'echo hi'`, `+e`.

Exit status: `0` success, `1` a runtime error or failed command, `2` a syntax or name error or bad option, `127` script not found.

## Commands and expressions

Statements starting with a keyword are that construct; `name = ...` (when
`name` is declared) is an assignment; `name(` with no space is a function
call; anything else is a command. `if (...)`, `while (...)` and `for (...)`
take expressions; `if grep -q x file { ... }` takes a command. Expression
mode also applies after `=`, after `return`, inside `${...}`, call
parentheses, and `[...]` / `{...}` literals.

```
var dirs = @(ls -d /etc /home/*)     # command output, one element per line
for (d in dirs) { print(d) }
if (len(dirs) > 3) { print("many") }
```

## Values

`null`, `bool`, `int` (64-bit, overflow is an error), `float`, `string`
(bytes, immutable), `array`, `map` (insertion ordered), `fn`, `regex`,
objects. There are no implicit conversions: `"5" + 1` is an error, use
`int("5") + 1`. Conditions and `!`/`&&`/`||` need real bools.

Floats print as the shortest text that reads back identically and keep `.0`
(`3.0`). `map[1]` indexes with the key `"1"`, which is how regex groups work.

## Variables and scope

`var` is mutable, `const` immutable; both need an initial value. Scope is
lexical and block-based. Shell variables are not environment variables: use
`env.NAME`. In command mode `$name` looks at variables first, then `env`.
Assigning an undeclared name is an error: ``x = 5`` says
``use `var x = 5` ``.

## Strings and arguments

`"..."` interpolates `$name` and `${expr}`; `'...'` is literal; `"""..."""`
is multi-line, interpolates, and removes common indentation. In commands:

1. `$file` is always exactly one argument, even with spaces.
2. `@list` splices an array into one argument per element; `$list` on an array is an error.
3. A glob that matches nothing is an error. Quoted words are never globbed.

`$(cmd)` is the output as a string without one trailing newline; `@(cmd)`
is an array of its lines. `status(cmd)` runs a command and returns its exit
status without raising. A `$( )` or `@( )` holds one command list.

## Errors

In a script a failing command raises an error and stops the script, except
as a `while`/`if` condition, left of `&&`/`||`, or inside `status()`. A
pipeline fails if any stage fails (an upstream stage killed by SIGPIPE, as
in `yes | head`, does not count). `try { } catch (e) { }` gives `e.message`,
`e.status`, `e.file`, `e.line`, `e.column`. At the prompt errors are
reported and the shell carries on.

`finally { }` runs whatever happens in the body: success, a caught error, an
uncaught error, `return`, `break` or `continue`. `catch` is optional when
there is a `finally`. An error raised inside `finally` replaces the pending one.

```
try { mount $dev $point; backup($point) } finally { umount $point }
```

### Signals and cleanup

`trap("INT", fn(sig) { ... })` runs the function between statements when the
signal arrives (a blocking command finishes first). `trap("EXIT", fn)` runs
when the shell exits, after an error too. `trap("INT")` or `trap("INT", null)`
restores the default. `KILL` and `STOP` cannot be trapped. Signals: HUP INT
QUIT USR1 USR2 PIPE ALRM TERM CHLD CONT TSTP WINCH, by name, with or without
`SIG`, or by number.

### Subshells

`subshell { ... }` runs the block in a forked child: `cd`, variable
assignments, `env` changes and `exit` stay inside. A non-zero status raises
`subshell exited with status N`.

## Functions

```
fn greet(name, greeting = "Hello") { return "${greeting}, ${name}!" }
greet("Dakota")            # expression: returns the value
greet Dakota Howdy | cat   # command: arguments are strings, output is what it prints
```

Functions are closures that capture by reference and are hoisted within
their block. Recursion depth is limited to 600.

## Classes

```
class Mount { var point = ""; fn init(p) { self.point = p } }
class Usb extends Mount { fn init(p) { super.init(p) } }
```

Single inheritance. Fields must be declared; `init` of a child with a
parent must call `super.init`. `str(obj)` calls `toString()` if defined;
`isInstance(obj, Class)` follows inheritance.

## Modules

`import "lib/disks.dksh" as disks` runs a file once and binds its top-level
`const`, `fn` and `class` declarations. Relative paths (containing `/`)
resolve from the importing file; bare names search
`$XDG_DATA_HOME/dksh/lib` (default `~/.local/share/dksh/lib`) and
`/usr/share/dksh/lib`.

## Regular expressions

`regex(pattern, flags)` with flags `i m s x u`; methods `test`, `match`,
`matchAll`, `replace(s, repl, count)`, `split(s, limit)`. `s =~ re` and
`s !~ re` accept a regex or a string. The engine is linear time:
backreferences and lookaround are rejected when compiling. `u` enables
Unicode `\w \d \s \b`, case folding and `\p{..}`/`\P{..}`.

## Built-ins

Commands: `cd exit source jobs fg bg wait disown exec history type umask`.

Functions: `print printErr printf sprintf regex readLine readPassword type
int float str bool isInstance len push pop keys values sort map filter split
join trim startsWith endsWith contains replace upper lower exists isFile
isDir readFile writeFile appendFile baseName dirName glob cwd hostName pid
shortPath date exit error`, and:

| Function | Meaning |
|---|---|
| `readLines(path = "-")` | lines of a file, or of standard input for `"-"` / no argument (`\r\n` handled) |
| `readStdin()` | all of standard input as a string |
| `shellQuote(s)` | `s` as one word that `sh` and dksh both read back unchanged |
| `jsonParse(s)` | JSON to values (objects become maps, in order; integers that fit stay `int`) |
| `jsonStringify(v, indent = 0)` | values to JSON, compact or pretty-printed; functions and objects are errors |
| `kill(pid, sig = "TERM")` | send a signal (negative pid = process group); errors raise |
| `sleep(seconds)` | pause; an int or float |
| `now()` | seconds since the epoch, as a float |
| `time(fn)` | run `fn()` and return the seconds it took |
| `trap(sig, fn)` | see Signals and cleanup | `printf` follows C format strings (no `%n`).
`sort(arr, cmp)` returns a new array; `cmp(a, b)` returns a negative, zero
or positive int.

## Interactive use

Emacs keys, multi-line editing (an unclosed brace or quote continues),
history in `$XDG_STATE_HOME/dksh/history`, Ctrl-R search, Up/Down prefix
search, Tab completion (commands, files, `$vars`, `obj.members`). The prompt
is the value of your `prompt()` function.

Syntax colors: command words are green when they resolve to a function,
builtin or executable and red when they don't; keywords blue, quoted text
yellow, `$variables` cyan, comments grey. A grey **suggestion** from history
follows the cursor; Right, End or Ctrl-E accepts it. Both are off when
`NO_COLOR` is set or `TERM` is `dumb`.

**Per-command completion:** define `fn complete_<command>(words, word)` that
returns an array of candidate strings (`words` are the command's words so
far, `word` the one being completed); other characters in the command name
become `_`. Return `null` to fall back to file names.

```
fn complete_deploy(words, word) { return ["staging", "production"] }
``` Startup files:
`/etc/dksh/profile.dksh`, `$XDG_CONFIG_HOME/dksh/profile.dksh` (login) and
`/etc/dksh/dkshrc.dksh`, `$XDG_CONFIG_HOME/dksh/dkshrc.dksh` (interactive).
Job control: Ctrl-C, Ctrl-Z, `jobs`, `fg`, `bg`, `wait`, `disown`.

## Known limits

- A standalone `}` word always ends a command (`echo }` needs quotes).
- There are no aliases (use functions) and no streaming line iterator:
  `readLines` reads the whole input first.
- Functions used as commands run in-process; inside a pipeline or with a
  redirect applied to a background job they run in a forked child, so their
  variable changes do not persist.
- Memory is reclaimed by a conservative tracing collector, not reference
  counting; cycles are collected.
