#!/usr/bin/env python3
"""Listening end of the spdhost fd hand-off, for tests/emit-fd.sh.

The reacquire path works by having spdhost re-exec itself as the termux-usb
launcher with SPDHOST_EMIT_SOCK set; spd_usb_emit_fd() then sends the USB
descriptor over that socket. This fixture is the parent half: it binds the
socket, runs the child, and reports what arrived.

The descriptor is checked by content, not just by number. Everything under
test is a real open fd here, so a bug that forwards the wrong descriptor (or
a closed one) still connects and still reports success if the test only
compares integers.

Usage: emit-fd-fixture.py SOCKET OUT_JSON -- CHILD [ARG...]
Writes {"connected": bool, "fd": int|null, "target": str|null,
        "rc": int, "stderr": str}
"""

import json
import os
import socket
import struct
import subprocess
import sys


def recv_fd(conn):
    """recvmsg(2) with SCM_RIGHTS, like spd_usb_emit_fd()'s peer."""
    msg, ancdata, _flags, _addr = conn.recvmsg(1, socket.CMSG_SPACE(4))
    for level, ctype, data in ancdata:
        if level == socket.SOL_SOCKET and ctype == socket.SCM_RIGHTS:
            return struct.unpack("i", data[:4])[0]
    return None


def main():
    sock_path, out_path = sys.argv[1], sys.argv[2]
    child = sys.argv[sys.argv.index("--") + 1:]

    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(1)
    # A refusing child exits without connecting; the caller shortens this so
    # those cases do not cost ten seconds each.
    srv.settimeout(float(os.environ.get("EMIT_FD_ACCEPT_TIMEOUT", "10")))

    env = dict(os.environ)
    env["SPDHOST_EMIT_SOCK"] = sock_path
    # close_fds=False on purpose: the descriptor under test is one the caller
    # opened and expects to reach the child, exactly as termux-usb hands its
    # own open device node to the launcher. Popen's default would close it and
    # every case would look like the "not open" refusal.
    proc = subprocess.Popen(child, env=env, close_fds=False,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    result = {"connected": False, "fd": None, "target": None, "rc": None,
              "stderr": ""}
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        conn = None

    if conn is not None:
        result["connected"] = True
        fd = recv_fd(conn)
        conn.close()
        result["fd"] = fd
        if fd is not None:
            try:
                result["target"] = os.readlink("/proc/self/fd/%d" % fd)
            except OSError as e:
                result["target"] = "unreadable: %s" % e
            try:
                os.close(fd)
            except OSError:
                pass

    err = proc.stderr.read().decode("utf-8", "replace")
    result["rc"] = proc.wait()
    result["stderr"] = err

    srv.close()
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass

    with open(out_path, "w") as f:
        json.dump(result, f)


if __name__ == "__main__":
    main()
