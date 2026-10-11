#!/usr/bin/env bash
# P0-6: fdl-pack-<sha7>.zip -- the fdl/ tree with its index, for the app's
# loader import (Decision 6: sha-pinned in the APK). Deterministic: sorted
# entries, fixed timestamps and modes, so the same tree always gives the same
# zip sha256. Refuses a stale fdl/index.
#   scripts/fdl-pack.sh OUTDIR [SHORT_SHA]
# Writes OUTDIR/fdl-pack-<short>.zip and OUTDIR/fdl-pack-<short>.zip.sha256.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
out=${1:?usage: fdl-pack.sh OUTDIR [SHORT_SHA]}
short=${2:-$(git -C "$root" rev-parse HEAD 2>/dev/null | cut -c1-7 || true)}
[[ -n $short ]] || short=unknown
"$here/gen-fdl-index.sh" --check "$root/fdl" >/dev/null
mkdir -p "$out"
zip=$out/fdl-pack-$short.zip
python3 - "$zip" "$root/fdl" <<'PY'
import os, sys, zipfile
out, src = sys.argv[1:]
paths = []
for d, ds, fs in os.walk(src):
    ds.sort()
    for f in fs:
        p = os.path.join(d, f)
        if os.path.islink(p) or not os.path.isfile(p):
            sys.exit("fdl-pack: not a regular file: " + p)
        paths.append(os.path.relpath(p, src))
paths.sort()
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for rel in paths:
        info = zipfile.ZipInfo("fdl/" + rel, date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = (0o100644 & 0xFFFF) << 16
        info.create_system = 3
        with open(os.path.join(src, rel), "rb") as fh:
            z.writestr(info, fh.read())
PY
( cd "$out" && sha256sum "fdl-pack-$short.zip" >"fdl-pack-$short.zip.sha256" )
cat "$out/fdl-pack-$short.zip.sha256"
