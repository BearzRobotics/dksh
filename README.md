# dksh

A classic interactive Unix shell (pipelines, redirection, job control, tab
completion) with a scripting language that reads like C instead of `sh`:
declared variables, real types, braces, functions with named parameters,
classes, a built-in linear-time regex engine, and errors that stop the script
instead of being silently ignored.

```
#!/usr/bin/dksh

fn backup(src, dest = "/mnt/backup") {
    if (!isDir(src)) { error("not a directory: ${src}") }
    mkdir -p $dest
    tar -czf "${dest}/${baseName(src)}.tar.gz" $src
}

for (d in @(ls -d /etc /home/*)) { backup(d) }
```

It is one static binary written in pure Zig with **no libc and no
dependencies**, so it keeps working on a rescue system even when `/usr/lib`
is damaged. Linux only (x86_64 and aarch64).

**Status:** early. All milestones in [SPEC.md](SPEC.md) are implemented, but
it has had very little real-world use. Do not make it the login shell of a
machine you cannot recover.

## Build

Needs Zig 0.17.0.

```
zig build                      # zig-out/bin/dksh
zig build -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-linux-none
```

## Test

```
zig build test                 # unit tests (parser, regex, glob, time, GC)
zig build spec                 # golden tests in tests/spec
zig build cli                  # command-line option tests
python3 tests/interactive/run.py    # line editor and job control through a pty
python3 tests/fuzz_parser.py zig-out/bin/dksh 2000   # parser fuzzing
DKSH_GC_STRESS=3 tests/run_spec.sh zig-out/bin/dksh   # golden tests with a GC every 3 allocations
```

## Use

```
dksh                       interactive shell
dksh script.dksh a b       run a script (args is ["a", "b"])
dksh -c 'source'           run a string
dksh -n script.dksh        parse and check only
dksh -x script.dksh        trace each command, expanded, to stderr
dksh --tree script.dksh    draw the syntax tree as ASCII art
dksh --help                all options
```

Documentation: [language guide](docs/language.md), [grammar](docs/grammar.ebnf),
[man page](docs/dksh.1), and the full design in [SPEC.md](SPEC.md).

## A note on AI

**This project was written by an AI.** The code, tests, documentation and
this README were produced by Claude (Anthropic's AI model, via Claude Code)
working from a specification and under the direction of the repository owner,
who set the goals, made the design decisions in `SPEC.md`, and reviewed the
results at the level of behavior, not line by line.

What that means for you:

- **It has not had a full human code review.** The test suites, a mutation
  fuzzer and a garbage-collector stress mode found real bugs during
  development, and they all pass, but passing tests are not proof of
  correctness. Expect bugs, especially in the garbage collector
  (`src/gc.zig`), which is hand-written and conservative, and in the line
  editor.
- **Treat it as untrusted for anything important.** Read the code before
  using it on systems where a wrong `rm`, a hung terminal or a crash would
  matter.
- **Some tests encode the AI's own reading of the spec.** Expected outputs
  were checked by eye, so the tests show the shell is consistent, not that
  every behavior is right.
- **Copyright and licensing of AI-generated code are unsettled** in many
  jurisdictions. No license has been chosen yet, so by default all rights are
  reserved; ask the owner before reusing it.

Bug reports and reviews are very welcome.

## Third-party data

`data/ucd/` holds unmodified files from the Unicode Character Database
(version in `data/ucd/VERSION`), used at build time to generate the regex
Unicode tables. They are © Unicode, Inc. and distributed under the
[Unicode License](https://www.unicode.org/license.txt).
