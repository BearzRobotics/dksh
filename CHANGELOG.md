# Changelog

## 0.0.1

First tagged release. Everything in [SPEC.md](SPEC.md) is implemented.

**Shell and language**
- Command mode and expression mode; pipelines, redirection, globbing, job control.
- Values and types, closures, classes with single inheritance, modules.
- `try` / `catch` / `finally`, `trap()`, `subshell { }`, `! cmd`, `status()`.
- Regex engine (Pike VM, linear time, Unicode 16.0), `printf`, JSON, string and file helpers.
- Errors with file, line, column and the source line.

**Interactive**
- Line editor, history, Ctrl-R, prefix search, tab completion, history suggestions and colors.
- `PS1` / `PS2` with bash escapes, `prompt()`, `precmd()`, `preexec()`.
- Login shell support: profiles in every mode, SIGHUP to jobs, `ulimit`, `umask`.

**Tooling**
- Options: `-c -l -i -n -x -e/+e --dump-ast --tree -v -h`.
- Scripts with a foreign `#!` line (bash, sh, python, `env X`) are handed to that interpreter.
- Man page (`docs/dksh.1`) and language guide (`docs/language.md`).

**Known limits**
- Little real-world use; written by an AI under human direction (see the README).
- The aarch64 build has been cross-compiled and checked as a static ELF, but not run.
- The garbage collector (`src/gc.zig`) is conservative and hand-written.
- POSIX shell syntax sent to `$SHELL -c` by other tools is not understood.
- No aliases, here-documents, `eval`, brace expansion or process substitution.
