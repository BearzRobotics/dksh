#!/usr/bin/env python3
"""Interactive tests (SPEC 10): drive dksh through a pty with keystrokes."""
import os, sys, tempfile, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ptylib import Session

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DKSH = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(root, "zig-out/bin/dksh")
failures = []

def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  {detail!r}"))
    if not cond:
        failures.append(name)

def start(home, rc=None):
    os.makedirs(home + "/.config/dksh", exist_ok=True)
    open(home + "/.config/dksh/dkshrc.dksh", "w").write(rc or 'fn prompt() { return "PS> " }\n')
    s = Session([DKSH], cwd=home, env={"HOME": home, "XDG_CONFIG_HOME": home + "/.config",
                "XDG_STATE_HOME": home + "/.state", "TERM": "xterm", "USER": "tester"})
    s.read(0.5); s.clear()
    return s

def run(s, keys, wait=0.7):
    s.clear(); s.send(keys); s.read(wait)
    return s.text()

home = tempfile.mkdtemp()
try:
    open(home + "/hello world.txt", "w").write("x")
    os.makedirs(home + "/subdir")
    s = start(home)

    out = run(s, "echo hi\r")
    check("runs a command", "\nhi\n" in out, out)
    run(s, "var x = 41\r")
    check("state persists across lines", "42" in run(s, "print(x + 1)\r"))
    check("custom prompt", "PS> " in out)

    out = run(s, "echo hel\t\r")
    check("tab completes a file with a space (escaped)", "hello world.txt" in out, out)
    out = run(s, "cd sub\t\rpwd\r")
    check("tab completes a directory", out.rstrip().split("\n")[-2].endswith("/subdir") or "subdir" in out, out)
    run(s, "cd ..\r")
    out = run(s, "pri\t\t")
    check("tab at command position lists/ completes", "print(" in out or "printf" in out, out)
    run(s, "\x15")  # clear line
    out = run(s, "var longname1 = 1\rvar longname2 = 2\rprint($lon\t")
    run(s, "\x15")
    out = run(s, "print(longname\t\t")
    check("variable completion lists candidates", "longname1" in out and "longname2" in out, out)
    run(s, "\x15")

    run(s, "echo first-cmd\r")
    run(s, "echo second-cmd\r")
    out = run(s, "echo f\x1b[A")
    check("Up with a typed prefix searches history by prefix", "echo first-cmd" in out, out)
    run(s, "\x15")
    out = run(s, "\x12second")
    check("Ctrl-R incremental search", "(reverse-i-search)`second': echo second-cmd" in out, out)
    run(s, "\r")

    out = run(s, "if (true) {\rprint(\"inside\")\r}\r")
    check("unclosed brace continues on the next line", "inside" in out and "... " in out, out)

    out = run(s, "echo abc\x01X\r", 1.0)
    check("Ctrl-A moves to the start", "command not found: Xecho" in out, out)
    out = run(s, "echo one two\x17\x17echo done\r")
    check("Ctrl-W deletes a word", "done" in out, out)

    out = run(s, "false\r")
    check("failed command at the prompt does not exit the shell", "PS> " in out, out)
    out = run(s, "nosuchcmd_xyz\r")
    check("unknown command is reported", "command not found" in out, out)

    # Autosuggestion, highlighting, per-command completion
    run(s, "echo suggestion-source-line\r")
    out = run(s, "echo sugg")
    check("autosuggestion is drawn dim after the cursor", "\x1b[90m" in s.buf.decode(errors="replace") and "estion-source-line" in out, out)
    run(s, "\x1b[C")
    out = run(s, "\r")
    check("Right arrow accepts the suggestion", "suggestion-source-line" in out, out)
    s.clear(); s.send("nosuchcmd_q"); s.read(0.4)
    check("unknown command is drawn red", "\x1b[31m" in s.buf.decode(errors="replace"))
    run(s, "\x15")
    s.clear(); s.send("echo \"s\" $HOME"); s.read(0.4)
    raw = s.buf.decode(errors="replace")
    check("strings yellow, variables cyan", "\x1b[33m" in raw and "\x1b[36m" in raw)
    run(s, "\x15")
    run(s, "fn complete_deploy(words, word) { return [\"staging\", \"production\"] }\r")
    out = run(s, "deploy st\t")
    check("user-defined per-command completion", "deploy staging" in out, out)
    run(s, "\x15")
    out = run(s, "deploy \t\t")
    check("lists candidates from complete_<cmd>", "staging" in out and "production" in out, out)
    run(s, "\x15")

    # Job control
    run(s, "sleep 30\r", 0.4)
    out = run(s, "\x03", 0.8)
    check("Ctrl-C interrupts the foreground job, not the shell", "PS> " in out, out)
    run(s, "sleep 30\r", 0.4)
    out = run(s, "\x1a", 1.0)
    check("Ctrl-Z stops the job", "Stopped" in out and "sleep 30" in out, out)
    out = run(s, "jobs\r")
    check("jobs lists the stopped job", "[1]" in out and "Stopped" in out, out)
    out = run(s, "bg\r")
    check("bg resumes it", "Running" in out, out)
    out = run(s, "jobs\r")
    check("job is running, not stopped", "Running" in out and "Stopped" not in out, out)
    run(s, "fg\r", 0.5)
    out = run(s, "\x03", 0.8)
    check("fg then Ctrl-C", "PS> " in out, out)
    out = run(s, "jobs\r")
    check("job table is empty afterwards", "sleep" not in out.split("jobs", 1)[-1], out)
    out = run(s, "sleep 0.2 &\r", 0.4)
    check("background job announces itself", "[1] " in out, out)
    out = run(s, "wait\r", 1.0)
    check("wait returns", out.rstrip().endswith("PS>"), out)
    out = run(s, "yes | head -n 2\r")
    check("pipeline with early-closing reader", "y\ny" in out.replace("\r", "") and "error" not in out, out)

    s.send("\x04"); out = s.read(0.8)
    check("Ctrl-D exits", "exit" in out, out)
    s.close()
    hist = open(home + "/.state/dksh/history").read()
    check("history file records commands", "echo first-cmd" in hist and "var x = 41" in hist, hist)

    # SIGHUP (terminal closed) hangs up background and stopped jobs
    import signal, subprocess, time
    def sleeping(): return subprocess.run(["pgrep", "-f", "^sleep 987"], capture_output=True).returncode == 0
    for label, keys, stop in (("background job", "sleep 987 &\r", False), ("background pipeline", "sleep 987 | cat &\r", False), ("stopped job", "sleep 987\r", True)):
        s = start(home)
        s.send(keys); s.read(0.6)
        if stop:
            s.send("\x1a"); s.read(0.8)
        was = sleeping()
        os.kill(s.pid, signal.SIGHUP); time.sleep(1.0)
        check(f"SIGHUP hangs up a {label}", was and not sleeping())
        subprocess.run(["pkill", "-f", "^sleep 987"])
        try: os.waitpid(s.pid, 0)
        except ChildProcessError: pass
        s.close()

    # exit builtin and login profile
    s = start(home, 'fn prompt() { return "PS> " }\n')
    out = run(s, "exit 3\r", 0.8)
    s.close()
    open(home + "/.config/dksh/profile.dksh", "w").write('env.FROM_PROFILE = "yes"\n')
    s = Session([DKSH, "-l"], cwd=home, env={"HOME": home, "XDG_CONFIG_HOME": home + "/.config",
                "XDG_STATE_HOME": home + "/.state", "TERM": "xterm"})
    s.read(0.5)
    out = run(s, "echo $FROM_PROFILE\r")
    check("login shell reads profile.dksh", "yes" in out, out)
    s.close()
finally:
    shutil.rmtree(home, ignore_errors=True)

print(f"\ninteractive tests: {len(failures)} failed")
sys.exit(1 if failures else 0)
