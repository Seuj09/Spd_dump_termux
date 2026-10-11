#!/usr/bin/env python3
"""P0-3 test helper (tests/events.sh): run a command with an event pipe on
fd 9 and a reader that behaves one way, then report how the command ended.

usage: events_reader.py MODE OUT -- CMD...
  MODE  all     read everything as it comes
        never   pipe shrunk to 4096 bytes with 3900 of them already taken
                (room for about one line), never read while CMD runs
        closed  read end closed before CMD starts (EPIPE on first write)
        slow    pipe shrunk to 4096 bytes, 3000 already taken, then read
                64 bytes every 20 ms
OUT gets every byte CMD wrote that the reader saw (for never: what sat in
the pipe at the end); the filler is not included. OUT.rc gets
`rc=N sec=S` (N negative = killed by that signal). CMD keeps the helper's
stdin/stdout/stderr, plus fd 7 when open (the mock's --usb-fd)."""
import fcntl, os, subprocess, sys, threading, time

F_SETPIPE_SZ = 1031
mode, out = sys.argv[1], sys.argv[2]
cmd = sys.argv[sys.argv.index("--") + 1:]
r, w = os.pipe()
filler = {"never": 3900, "slow": 3000}.get(mode, 0)
if filler:
    fcntl.fcntl(w, F_SETPIPE_SZ, 4096)
    os.write(w, b"#" * (filler - 1) + b"\n")
if w != 9:
    os.dup2(w, 9)
    os.close(w)
    w = 9
os.set_inheritable(9, True)
got = bytearray()
stop = threading.Event()

def reader():
    while True:
        if mode == "slow":
            time.sleep(0.02)
            b = os.read(r, 64)
        else:
            b = os.read(r, 65536)
        if not b:
            return
        got.extend(b)

if mode == "closed":
    os.close(r)
t = None
if mode in ("all", "slow"):
    t = threading.Thread(target=reader, daemon=True)
    t.start()
t0 = time.monotonic()
keep = [9]
try:
    os.fstat(7)  # the mock's --usb-fd 7 stays open for CMD
    keep.append(7)
except OSError:
    pass
p = subprocess.Popen(cmd, pass_fds=keep)
rc = p.wait()
sec = time.monotonic() - t0
os.close(9)
if mode == "never":
    fl = fcntl.fcntl(r, fcntl.F_GETFL)
    fcntl.fcntl(r, fcntl.F_SETFL, fl | os.O_NONBLOCK)
    try:
        while True:
            b = os.read(r, 65536)
            if not b:
                break
            got.extend(b)
    except BlockingIOError:
        pass
if t:
    t.join(timeout=60)
if filler:
    assert got[:filler] == b"#" * (filler - 1) + b"\n"
open(out, "wb").write(bytes(got[filler:]))
open(out + ".rc", "w").write("rc=%d sec=%.3f\n" % (rc, sec))
