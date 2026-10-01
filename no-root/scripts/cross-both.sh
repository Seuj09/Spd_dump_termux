#!/usr/bin/env bash
# Build static arm32 and arm64 packages, then one zip with both trees.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
"$here/cross-arm32.sh"
"$here/cross-arm64.sh"
sha=$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)
short=$(printf '%s' "$sha" | cut -c1-7)
out=$root/dist
zipname=spdhost-arm32-arm64-static-$short.zip
python3 - "$out/$zipname" "$out/arm32/pkg" "$out/arm64/pkg" <<'PY'
import os, sys, zipfile
out, arm32, arm64 = sys.argv[1:]
def add(z, src, rootname):
    for d, _, fs in os.walk(src):
        for f in sorted(fs):
            p = os.path.join(d, f)
            rel = os.path.relpath(p, src)
            info = zipfile.ZipInfo.from_file(p, arcname=os.path.join(rootname, rel))
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(p, "rb") as fh:
                z.writestr(info, fh.read())
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    add(z, arm32, "spdhost-arm32")
    add(z, arm64, "spdhost-arm64")
print(out)
PY
( cd "$out" && sha256sum \
	arm32/spdhost arm32/spd_dump arm32/spdhost-arm32-static-"$short".zip \
	arm64/spdhost arm64/spd_dump arm64/spdhost-arm64-static-"$short".zip \
	"$zipname" >SHA256SUMS )
echo
echo "both -> $out/$zipname"
cat "$out/SHA256SUMS"
