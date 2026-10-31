#!/usr/bin/env python3
"""Mutation fuzzer for the parser (SPEC 10): `dksh -n` must exit 0 or 2 and
never crash or hang, whatever the input. Seeds are the golden test scripts."""
import glob, os, random, subprocess, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
dksh = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "zig-out/bin/dksh")
iters = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
seed = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
rnd = random.Random(seed)
seeds = [open(f, "rb").read() for f in glob.glob(os.path.join(root, "tests/spec/*.dksh"))]
tokens = [b"{", b"}", b"(", b")", b"[", b"]", b'"', b"'", b'"""', b"$(", b"@(", b"${", b"\\", b"|", b"&", b"&&",
          b"||", b";", b"\n", b">", b"<", b"<<<", b"2>&1", b"=", b"==", b"=~", b"fn ", b"if ", b"class ", b"var ",
          b"for (", b"while ", b"try {", b"catch (e) {", b"import ", b"extends ", b"#", b"\x00", b"\xff", b"\xc3",
          b"0x", b"1e", b"..", b"?", b":", b"super.", b"self.", b"status(", b"~", b"*", b"@x", b"$x"]

def mutate(data):
    d = bytearray(data)
    for _ in range(rnd.randint(1, 6)):
        op = rnd.randrange(6)
        pos = rnd.randrange(len(d) + 1)
        if op == 0 and d:
            del d[pos % len(d):pos % len(d) + rnd.randint(1, 8)]
        elif op == 1:
            d[pos:pos] = rnd.choice(tokens)
        elif op == 2 and d:
            d[pos % len(d)] = rnd.randrange(256)
        elif op == 3 and d:
            a = rnd.randrange(len(d)); b = min(len(d), a + rnd.randint(1, 40))
            d[pos:pos] = d[a:b]
        elif op == 4:
            d = d[:pos]
        else:
            d[pos:pos] = bytes(rnd.randrange(256) for _ in range(rnd.randint(1, 4)))
    return bytes(d)

bad = 0
for i in range(iters):
    data = mutate(rnd.choice(seeds))
    try:
        r = subprocess.run([dksh, "-n", "/dev/stdin"], input=data, capture_output=True, timeout=5)
    except subprocess.TimeoutExpired:
        print(f"HANG (seed {seed}, iter {i})"); open(f"/tmp/dksh-fuzz-hang-{i}.dksh", "wb").write(data); bad += 1; continue
    if r.returncode not in (0, 2):
        print(f"CRASH rc={r.returncode} (seed {seed}, iter {i}): {r.stderr[-200:]!r}")
        open(f"/tmp/dksh-fuzz-crash-{i}.dksh", "wb").write(data); bad += 1
print(f"fuzz: {iters} inputs, {bad} problems (seed {seed})")
sys.exit(1 if bad else 0)
