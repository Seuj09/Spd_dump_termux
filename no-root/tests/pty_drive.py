#!/usr/bin/env python3
"""Run a shell command on a fresh pty (controlling tty, like a Termux shell
under termux-usb -e) and answer prompts.
Usage: pty_drive.py TRANSCRIPT [--raw] [EXPECT SEND]... -- CMD
EXPECT is a substring waited for on the pty (20 s max); SEND is written with
\\r, \\n and \\x04 (EOF) escapes. --raw clears ICRNL so a typed CR reaches the
reader as-is. Exit status is the command's."""
import os, pty, select, sys, termios, time

def main():
    a = sys.argv[1:]
    out = a.pop(0)
    raw = a and a[0] == "--raw"
    if raw:
        a.pop(0)
    k = a.index("--")
    pairs, cmd = a[:k], a[k + 1:]
    pid, fd = pty.fork()
    if pid == 0:
        if raw:
            t = termios.tcgetattr(0)
            t[0] &= ~termios.ICRNL
            termios.tcsetattr(0, termios.TCSANOW, t)
        os.execvp("bash", ["bash", "-c", cmd[0]])
    buf = b""
    def pump(tmo):
        nonlocal buf
        r, _, _ = select.select([fd], [], [], tmo)
        if not r:
            return True
        try:
            d = os.read(fd, 4096)
        except OSError:
            return False
        if not d:
            return False
        buf += d
        return True
    for i in range(0, len(pairs), 2):
        want = pairs[i].encode()
        send = pairs[i + 1].encode().decode("unicode_escape").encode("latin-1")
        end = time.time() + 20
        while want not in buf and time.time() < end:
            if not pump(0.2):
                break
        if want not in buf:
            buf += b"\n[pty_drive: timeout waiting for %r]\n" % want
            break
        time.sleep(0.1)
        os.write(fd, send)
    end = time.time() + 60
    while time.time() < end and pump(0.5):
        pass
    if time.time() >= end:
        buf += b"\n[pty_drive: command still running after 60 s; killed]\n"
        os.kill(pid, 9)
    _, st = os.waitpid(pid, 0)
    open(out, "wb").write(buf)
    sys.exit(os.waitstatus_to_exitcode(st))

main()
