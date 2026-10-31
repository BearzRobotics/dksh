"""Tiny pty driver for the interactive tests (SPEC 10)."""
import os, pty, select, time, signal, fcntl, termios, struct, re

class Session:
    def __init__(self, argv, env=None, cwd=None, cols=100):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            if cwd:
                os.chdir(cwd)
            e = dict(os.environ)
            e.update(env or {})
            os.execve(argv[0], argv, e)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, cols, 0, 0))
        self.buf = b""

    def send(self, data):
        if isinstance(data, str):
            data = data.encode()
        os.write(self.fd, data)

    def read(self, timeout=1.0):
        """Read whatever arrives until `timeout` seconds of silence."""
        out = b""
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    d = os.read(self.fd, 65536)
                except OSError:
                    break
                if not d:
                    break
                out += d
                end = time.time() + timeout
        self.buf += out
        return out.decode(errors="replace")

    def expect(self, text, timeout=3.0):
        end = time.time() + timeout
        while time.time() < end:
            if text.encode() in self.buf:
                return True
            self.read(0.2)
        return text.encode() in self.buf

    def clear(self):
        self.buf = b""

    def text(self):
        return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", self.buf.decode(errors="replace")).replace("\r", "")

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass
        os.close(self.fd)
