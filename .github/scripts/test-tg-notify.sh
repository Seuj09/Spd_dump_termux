#!/usr/bin/env bash
# Local/CI test for .github/scripts/tg-notify.sh. No network, no real secrets.
#  - text building (--dry-run): escaping, the 120-char subject cut, the
#    1024/4096 limits with a very long special-character subject, markers;
#  - the skip paths (no secrets, no APK) exit 0 with a ::notice::;
#  - the send path against a dummy HTTP server: a stand-in `curl` first on
#    PATH rewrites https://api.telegram.org to the local server in the config
#    tg-notify.sh feeds on stdin, then runs the real curl. Nothing in the
#    script or the workflow changes for the test.
#  - the token never shows up in any output.
# Run: bash .github/scripts/test-tg-notify.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tg=$here/tg-notify.sh
tmp=$(mktemp -d); trap 'kill $srv 2>/dev/null; rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
# UTF-16 length, without the newline a here-string adds
u16() { python3 -c 'import sys; print(len(sys.stdin.read().rstrip("\n").encode("utf-16-le"))//2)'; }
export -f u16

TOKEN='123456:TEST-token_DoNotLeak'
CHAT='-1001234567890'
SHA=0123456789abcdef0123456789abcdef01234567
long=$(python3 -c 'print(("<b>&amp; fix(\"x\"): <script> & ünïcødé 🚀 " * 80).strip())')

# --- text building ---------------------------------------------------------
head -c 1000 /dev/zero > "$tmp/app.apk"
out=$(env -u TELEGRAM_BOT_TOKEN -u TELEGRAM_CHAT_ID "$tg" release --dry-run --tag spdhost-exp-x-0123456 \
	--sha $SHA --subject "fix(ci): a <b>&</b> c" --url 'https://github.com/o/r/releases/tag/t?a=1&b=2' \
	--file "$tmp/app.apk" --prerelease)
check "release: small APK goes as sendDocument" grep -qx 'method=sendDocument' <<<"$out"
check "release: pre-release marker, tag, short sha" bash -c 'grep -q "(pre-release)" <<<"$1" && grep -q "<code>spdhost-exp-x-0123456</code>" <<<"$1" && grep -q "<code>0123456</code>" <<<"$1"' _ "$out"
check "release: subject escaped for HTML" grep -qF 'fix(ci): a &lt;b&gt;&amp;&lt;/b&gt; c' <<<"$out"
check "release: sha256 of the APK" grep -qF "$(sha256sum "$tmp/app.apk" | cut -d' ' -f1)" <<<"$out"
check "release: release URL with & escaped" grep -qF 'https://github.com/o/r/releases/tag/t?a=1&amp;b=2' <<<"$out"
out=$("$tg" release --dry-run --tag t --sha $SHA --subject s --url u --file "$tmp/app.apk")
check "release without --prerelease says (release)" bash -c 'grep -q "(release)" <<<"$1" && ! grep -q "pre-release" <<<"$1"' _ "$out"

out=$("$tg" release --dry-run --tag spdhost-exp-x-0123456 --sha $SHA --subject "$long" --url https://example.invalid/r --file "$tmp/app.apk" --prerelease)
cap=$(sed 1d <<<"$out")
subj=$(sed -n 's/^<b>commit<\/b> <code>0123456<\/code> — //p' <<<"$cap" | python3 -c 'import html,sys; print(len(html.unescape(sys.stdin.read().rstrip("\n"))))')
check "long subject: cut to 120 characters, ending in …" bash -c '[ "$1" -le 120 ] && grep -q "…$" <<<"$(grep "^<b>commit" <<<"$2")"' _ "$subj" "$cap"
check "long subject: no raw < or & from the subject survives" bash -c '! grep "^<b>commit" <<<"$1" | sed "s/<b>commit<\/b> <code>0123456<\/code>//" | grep -qE "<|&[^a-z#]"' _ "$cap"
check "long subject: caption within 1024 UTF-16 units ($(u16 <<<"$cap"))" bash -c '[ "$(u16 <<<"$1")" -le 1024 ]' _ "$cap"
# A tag and URL so long that the 120-char subject no longer fits: the subject
# is cut further, the caption still fits.
bigurl="https://github.com/o/r/releases/tag/$(printf 'x%.0s' $(seq 1 700))"
out=$("$tg" release --dry-run --tag spdhost-exp-x-0123456 --sha $SHA --subject "$long" --url "$bigurl" --file "$tmp/app.apk" --prerelease)
cap=$(sed 1d <<<"$out")
check "huge URL: subject cut below 120 and caption still <= 1024 ($(u16 <<<"$cap"))" bash -c '[ "$(u16 <<<"$1")" -le 1024 ] && grep -q "$2" <<<"$1"' _ "$cap" "$bigurl"
out=$("$tg" release --dry-run --tag t --sha $SHA --subject s --url "https://x/$(printf 'y%.0s' $(seq 1 1100))" --file "$tmp/app.apk" 2>&1); rc=$?
check "impossible caption (URL alone > 1024) is an error, not a truncated link (rc $rc)" bash -c '[ $1 != 0 ] && grep -q "over 1024" <<<"$2"' _ $rc "$out"

truncate -s 50000001 "$tmp/big.apk"
out=$("$tg" release --dry-run --tag t --sha $SHA --subject s --url https://example.invalid/r --file "$tmp/big.apk" --prerelease)
check "APK over 50 MB goes as sendMessage with the release link" bash -c 'grep -qx method=sendMessage <<<"$1" && grep -q "over the Bot API 50 MB upload cap" <<<"$1" && grep -q "https://example.invalid/r" <<<"$1" && grep -q "<b>sha256</b>" <<<"$1"' _ "$out"

out=$("$tg" status --dry-run --result pass --branch experiment/brom-hello-diagnostics --sha $SHA --subject "$long" --run-url https://github.com/o/r/actions/runs/1)
check "status pass: ✅ PASS, branch, sha, run link, no failed line" bash -c 'grep -q "^✅ PASS" <<<"$1" && grep -q "<code>experiment/brom-hello-diagnostics</code>" <<<"$1" && grep -q "<code>0123456</code>" <<<"$1" && grep -q "actions/runs/1$" <<<"$1" && ! grep -q "<b>failed" <<<"$1"' _ "$out"
out=$("$tg" status --dry-run --result fail --branch b --sha $SHA --subject "x" --run-url u --failed "no-root test suite (failure), apk (cancelled)")
check "status fail: ❌ FAIL and the failed jobs" bash -c 'grep -q "^❌ FAIL" <<<"$1" && grep -q "<b>failed</b> no-root test suite (failure), apk (cancelled)" <<<"$1"' _ "$out"

# --- skip paths ------------------------------------------------------------
out=$(env -u TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID=$CHAT "$tg" status --result pass --branch b --sha $SHA --subject s --run-url u 2>&1); rc=$?
check "no token: ::notice:: and exit 0" bash -c '[ $1 = 0 ] && grep -q "^::notice" <<<"$2"' _ $rc "$out"
out=$(TELEGRAM_BOT_TOKEN=$TOKEN TELEGRAM_CHAT_ID= "$tg" status --result pass --branch b --sha $SHA --subject s --run-url u 2>&1); rc=$?
check "empty chat id: ::notice:: and exit 0" bash -c '[ $1 = 0 ] && grep -q "^::notice" <<<"$2"' _ $rc "$out"
out=$(TELEGRAM_BOT_TOKEN=$TOKEN TELEGRAM_CHAT_ID=$CHAT "$tg" release --tag t --sha $SHA --subject s --url u --file "$tmp/none.apk" 2>&1); rc=$?
check "no APK: ::notice:: and exit 0" bash -c '[ $1 = 0 ] && grep -q "^::notice.*no APK" <<<"$2"' _ $rc "$out"

# --- send path against a dummy server --------------------------------------
cat > "$tmp/srv.py" <<'PY'
import http.server, json, sys, os, email, urllib.parse
rec = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        ct = self.headers.get('Content-Type', '')
        fields, files = {}, {}
        if ct.startswith('multipart/'):
            msg = email.message_from_bytes(b'Content-Type: ' + ct.encode() + b'\r\n\r\n' + body)
            for p in msg.get_payload():
                name = p.get_param('name', header='content-disposition')
                data = p.get_payload(decode=True)
                if p.get_filename(): files[name] = {'filename': p.get_filename(), 'size': len(data)}
                else: fields[name] = data.decode()
        else:
            fields = {k: v[0] for k, v in urllib.parse.parse_qs(body.decode()).items()}
        mode = open(os.path.join(os.path.dirname(rec), 'mode')).read().strip()
        with open(rec, 'w') as f: json.dump({'path': self.path, 'fields': fields, 'files': files}, f)
        if mode == 'ok': code, out = 200, {'ok': True, 'result': {}}
        elif mode == 'notok': code, out = 400, {'ok': False, 'description': 'Bad Request: chat not found'}
        else: code, out = 502, None
        self.send_response(code); self.send_header('Content-Type', 'application/json'); self.end_headers()
        self.wfile.write(json.dumps(out).encode() if out else b'<html>bad gateway</html>')
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open(sys.argv[1], 'w').write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$tmp/srv.py" "$tmp/port" "$tmp/rec.json" & srv=$!
for _ in $(seq 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
port=$(cat "$tmp/port")
real_curl=$(command -v curl)
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<SH
#!/usr/bin/env bash
# test stand-in: point the stdin config at the dummy server, then run curl
sed 's#https://api.telegram.org/#http://127.0.0.1:$port/#' | exec "$real_curl" "\$@"
SH
chmod +x "$tmp/bin/curl"
send() { PATH="$tmp/bin:$PATH" TELEGRAM_BOT_TOKEN=$TOKEN TELEGRAM_CHAT_ID=$CHAT "$tg" "$@"; }
field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$tmp/rec.json" "$1"; }

echo ok > "$tmp/mode"
out=$(send release --tag spdhost-exp-x-0123456 --sha $SHA --subject "$long" --url https://example.invalid/r --file "$tmp/app.apk" --prerelease 2>&1); rc=$?
check "sendDocument: ok reply, rc 0" bash -c '[ $1 = 0 ] && grep -q "sendDocument: ok" <<<"$2"' _ $rc "$out"
check "sendDocument: path is /bot<token>/sendDocument" bash -c '[ "$1" = "/bot$2/sendDocument" ]' _ "$(field "d['path']")" "$TOKEN"
check "sendDocument: chat_id, parse_mode=HTML, the APK as document" bash -c '[ "$1" = "$2" ] && [ "$3" = HTML ] && [ "$4" = 1000 ]' _ \
	"$(field "d['fields']['chat_id']")" "$CHAT" "$(field "d['fields']['parse_mode']")" "$(field "d['files']['document']['size']")"
check "sendDocument: caption received intact and <= 1024" bash -c 'grep -q "(pre-release)" <<<"$1" && [ "$(u16 <<<"$1")" -le 1024 ]' _ "$(field "d['fields']['caption']")"
check "token not in the output" bash -c '! grep -qF "$1" <<<"$2"' _ "$TOKEN" "$out"

out=$(send release --tag t --sha $SHA --subject s --url https://example.invalid/r --file "$tmp/big.apk" 2>&1); rc=$?
check "over 50 MB: sendMessage, no upload, text has the link" bash -c '[ $1 = 0 ] && [ "$2" = "/bot$4/sendMessage" ] && grep -q "https://example.invalid/r" <<<"$3"' _ $rc \
	"$(field "d['path']")" "$(field "d['fields']['text']")" "$TOKEN"

out=$(send status --result fail --branch b --sha $SHA --subject 'a & b <c>' --run-url https://x/runs/9 --failed 'build (failure)' 2>&1); rc=$?
check "status sendMessage: ok, text escaped, failed job named" bash -c '[ $1 = 0 ] && grep -qF "a &amp; b &lt;c&gt;" <<<"$2" && grep -q "build (failure)" <<<"$2" && [ "$3" = HTML ]' _ $rc \
	"$(field "d['fields']['text']")" "$(field "d['fields']['parse_mode']")"

echo notok > "$tmp/mode"
out=$(send status --result pass --branch b --sha $SHA --subject s --run-url u 2>&1); rc=$?
check "ok:false reply fails the step with Telegram's description (rc $rc)" bash -c '[ $1 = 1 ] && grep -q "::error.*chat not found" <<<"$2" && ! grep -qF "$3" <<<"$2"' _ $rc "$out" "$TOKEN"
echo http502 > "$tmp/mode"
out=$(send release --tag t --sha $SHA --subject s --url u --file "$tmp/app.apk" 2>&1); rc=$?
check "HTTP 502 non-JSON fails the step (rc $rc), token not shown" bash -c '[ $1 = 1 ] && grep -q "::error.*HTTP 502" <<<"$2" && ! grep -qF "$3" <<<"$2"' _ $rc "$out" "$TOKEN"
kill $srv 2>/dev/null; wait $srv 2>/dev/null
out=$(send status --result pass --branch b --sha $SHA --subject s --run-url u 2>&1); rc=$?
check "server down: curl error fails the step (rc $rc), token not shown" bash -c '[ $1 = 1 ] && grep -q "::error.*curl failed" <<<"$2" && ! grep -qF "$3" <<<"$2"' _ $rc "$out" "$TOKEN"
check "the script has no set -x and never echoes the URL" bash -c '! grep -nE "^[^#]*set -[a-z]*x|echo[^\n]*bot\\\$|echo.*TELEGRAM_BOT_TOKEN" "$1"' _ "$tg"

echo "test-tg-notify: $pass passed, $fail failed"
(( fail == 0 ))
