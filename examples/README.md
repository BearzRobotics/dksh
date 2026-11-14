# Examples

Small, runnable dksh scripts. Run one with `dksh examples/NAME.dksh [args]`,
or `chmod +x` it and run it directly (each has a `#!/usr/bin/dksh` line).

| Script | Shows |
|---|---|
| `hello.dksh` | variables, interpolation, `args`, functions with defaults |
| `fizzbuzz.dksh` | `while`, `if`/`else if`, integer math |
| `collections.dksh` | arrays, maps, `map`/`filter`/`sort`, closures |
| `classes.dksh` | classes, `extends`, `super`, `isInstance` |
| `errors.dksh` | `try`/`catch`/`finally`, failed commands as errors |
| `regex.dksh` | the built-in regex engine: named groups, replace, split, `=~` |
| `pipeline.dksh` | pipes, redirection, `$(...)` and `@(...)` capture, `trap` |
| `json.dksh` | `jsonStringify` / `jsonParse` |
| `files.dksh` | a directory report using `find`, `stat` and a class |
| `trap_cleanup.dksh` | `trap("EXIT", ...)` cleanup that runs even on failure (exits 1 by design) |

See [docs/language.md](../docs/language.md) for the full reference.
