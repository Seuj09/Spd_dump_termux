#!/usr/bin/env python3
"""P0-3 test helper (tests/events.sh): check an --events stream.

  events_check.py schema FILE    every line a JSON object with the envelope
                                 (v=1, t, ev; seq on all but `dropped`, rising)
  events_check.py account FILE   seq gaps == dropped counts; with an `end`
                                 line: delivered + end.dropped == end.seq
                                 Prints `delivered=N dropped=D end=yes|no`.
  events_check.py summary FILE   one plain line per event (progress: only
                                 the final done==total ones), for diffing.
Exit 1 with a reason on stderr when a check fails."""
import json, sys

def load(path):
    evs = []
    with open(path, "rb") as f:
        for n, raw in enumerate(f, 1):
            if not raw.endswith(b"\n"):
                sys.exit("line %d: not newline-terminated" % n)
            try:
                o = json.loads(raw)
            except ValueError as e:
                sys.exit("line %d: not JSON: %s" % (n, e))
            if not isinstance(o, dict):
                sys.exit("line %d: not an object" % n)
            evs.append(o)
    return evs

def schema(evs):
    last = 0
    for o in evs:
        if o.get("v") != 1 or not isinstance(o.get("t"), int) or o["t"] < 0 or not isinstance(o.get("ev"), str):
            sys.exit("bad envelope: %r" % o)
        if o["ev"] == "dropped":
            if "seq" in o or not isinstance(o.get("count"), int) or o["count"] < 1:
                sys.exit("bad dropped: %r" % o)
            continue
        s = o.get("seq")
        if not isinstance(s, int) or s <= last:
            sys.exit("seq not rising: %r after %d" % (o, last))
        last = s

def account(evs):
    last, gaps, notes, end = 0, 0, 0, None
    for o in evs:
        if o["ev"] == "dropped":
            notes += o["count"]
            continue
        gaps += o["seq"] - last - 1
        last = o["seq"]
        if notes != gaps:
            sys.exit("before seq %d: %d events missing but dropped notices say %d" % (last, gaps, notes))
        if o["ev"] == "end":
            end = o
    delivered = sum(1 for o in evs if o["ev"] != "dropped")
    if end is not None:
        if end["dropped"] != notes:
            sys.exit("end.dropped %d != dropped notices %d" % (end["dropped"], notes))
        if delivered + end["dropped"] != end["seq"]:
            sys.exit("delivered %d + dropped %d != end.seq %d" % (delivered, end["dropped"], end["seq"]))
    print("delivered=%d dropped=%d end=%s" % (delivered, notes, "yes" if end else "no"))

def summary(evs):
    for o in evs:
        e = o["ev"]
        if e == "start":
            print("start protocol=%s dirty=%s sha=%s" % (o["protocol"], o["build_dirty"], o["build_sha"]))
        elif e == "session":
            print("session usb=%s" % o["usb"])
        elif e == "stage":
            print("stage %s" % o["stage"])
        elif e == "cmd":
            print("cmd %s %s" % (o["name"], o["state"]))
        elif e == "hello":
            print("hello %s try=%d/%d %s%s" % (o["stage"], o["try"], o["of"], o["result"], " ms" if "ms" in o else ""))
        elif e == "progress":
            if o["done"] >= o["total"]:
                print("progress %s %s %d/%d" % (o["op"], o["name"], o["done"], o["total"]))
        elif e == "status":
            print("status %s=%s" % (o["key"], o["value"]))
        elif e == "usb":
            print("usb %s" % o["state"])
        elif e == "end":
            print("end rc=%d dropped=%d" % (o["rc"], o["dropped"]))
        elif e == "dropped":
            print("dropped %d" % o["count"])
        else:
            print("other %s" % e)

mode, path = sys.argv[1], sys.argv[2]
evs = load(path)
schema(evs)
if mode == "account":
    account(evs)
elif mode == "summary":
    summary(evs)
