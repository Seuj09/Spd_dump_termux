#!/usr/bin/env python3
"""P0-5: the app side of --usb-fd-sock, for tests (Termux cannot run it).

Usage: fd-sock-server.py SOCK LOG MODE [FILE] -- CMD...

Binds a filesystem-path unix stream socket at SOCK, runs CMD (with the
socket listening, so CMD may connect to SOCK), answers it like the P0 app
stub, and writes one line per event to LOG:
    accept / line <text> / sent-fd / sent-no / eof / rc <n>
MODE:
    ok     HELLO -> 'F' + fd of FILE (opened O_RDWR); REACQ -> 'N' (the stub)
    offer  as ok, but REACQ is answered 'F' + an fd of FILE.reacq (the core
           must not use it: the yes-path is not in P0)
    nofd   HELLO -> 'N' with no fd (the app refused)
    eof    close the connection right after accept
The exit status is CMD's. The socket file is unlinked at the end, as the
app does after a session.
"""
import array
import os
import socket
import subprocess
import sys
import threading


def main():
    sep = sys.argv.index("--")
    sock_path, log_path, mode = sys.argv[1:4]
    target = sys.argv[4] if sep > 4 else None
    cmd = sys.argv[sep + 1:]
    log = open(log_path, "w", buffering=1)

    if os.path.exists(sock_path):
        os.unlink(sock_path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(1)
    srv.settimeout(30)

    def send_fd(path):
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            conn.sendmsg([b"F"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                   array.array("i", [fd]))])
        finally:
            os.close(fd)
        log.write("sent-fd\n")

    conn = None

    def serve():
        nonlocal conn
        try:
            conn, _ = srv.accept()
        except OSError:
            return
        log.write("accept\n")
        if mode == "eof":
            conn.close()
            log.write("closed\n")
            return
        buf = b""
        while True:
            try:
                data = conn.recv(256)
            except OSError:
                data = b""
            if not data:
                log.write("eof\n")
                break
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                text = line.decode("ascii", "replace")
                log.write("line %s\n" % text)
                if text.startswith("HELLO"):
                    if mode in ("ok", "offer"):
                        send_fd(target)
                    else:
                        conn.send(b"N")
                        log.write("sent-no\n")
                elif text.startswith("REACQ"):
                    if mode == "offer":
                        send_fd(target + ".reacq")  # a different file
                    else:
                        conn.send(b"N")
                        log.write("sent-no\n")
        conn.close()

    t = threading.Thread(target=serve, daemon=True)
    t.start()
    rc = subprocess.call(cmd)
    try:
        srv.shutdown(socket.SHUT_RDWR)  # wakes accept() when CMD never connected
    except OSError:
        pass
    srv.close()
    t.join(5)
    log.write("rc %d\n" % rc)
    try:
        os.unlink(sock_path)
    except OSError:
        pass
    sys.exit(rc)


if __name__ == "__main__":
    main()
