#!/usr/bin/env bash
# .github/scripts/tg-notify.sh -- post a CI result or a release APK to Telegram.
# Used by .github/workflows/build.yml (the APK release post and the notify job).
#
#   tg-notify.sh release --tag TAG --sha SHA --subject S --url RELEASE_URL
#                        --file APK [--prerelease] [--dry-run]
#   tg-notify.sh status  --result pass|fail --branch B --sha SHA --subject S
#                        --run-url URL [--failed "job (result), ..."] [--dry-run]
#
# Reads TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID from the environment. If either
# is missing, or `release` has no APK file, it prints a ::notice:: and exits 0.
# --dry-run builds the text and prints it with the method it would use; it
# sends nothing and needs no secrets (tests use it).
#
# The token is never printed, never in a file and never in an argv: the API URL
# goes to curl on stdin (`curl -K -`, from bash's builtin printf). There is no
# `set -x` here and the URL is never echoed. Telegram's reply is checked for
# "ok": true; anything else (or an HTTP/curl error) exits 1 with Telegram's
# "description", which never contains the token.
#
# Text is HTML (parse_mode=HTML): every dynamic field is escaped (& < >). The
# commit subject is cut to 120 characters (ending in "…" when cut) and cut
# further if the whole text would pass Telegram's limit: 1024 for a document
# caption, 4096 for a message, counted in UTF-16 units as Telegram counts.
# The Bot API takes uploads up to 50 MB; a bigger APK is announced with
# sendMessage and the release link instead.
set -euo pipefail

API=https://api.telegram.org
UPLOAD_CAP=50000000   # bytes; the Bot API's 50 MB cap, read conservatively

kind=${1:-}; shift || true
tag='' sha='' subject='' url='' file='' pre=0 dry=0 result='' branch='' run_url='' failed=''
while [ $# -gt 0 ]; do
	case $1 in
	--tag) tag=$2; shift 2 ;;
	--sha) sha=$2; shift 2 ;;
	--subject) subject=$2; shift 2 ;;
	--url) url=$2; shift 2 ;;
	--file) file=$2; shift 2 ;;
	--prerelease) pre=1; shift ;;
	--result) result=$2; shift 2 ;;
	--branch) branch=$2; shift 2 ;;
	--run-url) run_url=$2; shift 2 ;;
	--failed) failed=$2; shift 2 ;;
	--dry-run) dry=1; shift ;;
	*) echo "tg-notify: unknown argument: $1" >&2; exit 2 ;;
	esac
done
case $kind in release|status) ;; *) echo "usage: tg-notify.sh release|status ..." >&2; exit 2 ;; esac

notice() { echo "::notice title=Telegram::$*"; }

# Secrets first: no secrets is a clean skip, not an error.
if [ "$dry" = 0 ]; then
	if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
		notice "TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is not set; not posting the $kind message"
		exit 0
	fi
	# The token is a secret, so Actions masks it already; the chat id is
	# masked too in case it is ever passed as a plain variable.
	[ "${GITHUB_ACTIONS:-}" = true ] && echo "::add-mask::$TELEGRAM_CHAT_ID"
fi

method=sendMessage size=0 hash=''
if [ "$kind" = release ]; then
	if [ -z "$file" ] || [ ! -f "$file" ]; then
		notice "no APK was produced (no android/ app project yet); nothing to post"
		exit 0
	fi
	size=$(stat -c %s "$file")
	hash=$(sha256sum "$file" | cut -d' ' -f1)
	if [ "$size" -le "$UPLOAD_CAP" ]; then method=sendDocument; fi
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Build the text. python3 for exact UTF-16 counting and safe trimming; all
# inputs travel in the environment, never through a shell-quoted string.
limit=4096; [ "$method" = sendDocument ] && limit=1024
TGN_KIND=$kind TGN_TAG=$tag TGN_SHA=$sha TGN_SUBJECT=$subject TGN_URL=$url TGN_PRE=$pre \
TGN_SIZE=$size TGN_HASH=$hash TGN_METHOD=$method TGN_RESULT=$result TGN_BRANCH=$branch \
TGN_RUN_URL=$run_url TGN_FAILED=$failed TGN_LIMIT=$limit TGN_FILE=$(basename "${file:-none}") \
python3 - >"$work/text" <<'PY'
import os, sys, html
e = os.environ
def esc(s): return html.escape(s, quote=False)
def u16(s): return len(s.encode('utf-16-le')) // 2
def trim(s, n):
    s = ' '.join(s.split())            # one line, no control characters
    if len(s) <= n: return s
    return (s[:max(n - 1, 0)].rstrip() + '…') if n > 0 else ''
sha7 = e['TGN_SHA'][:7]
def build(n):
    subj = trim(e['TGN_SUBJECT'], n)
    commit = '<b>commit</b> <code>%s</code>' % esc(sha7) + (' — ' + esc(subj) if subj else '')
    if e['TGN_KIND'] == 'release':
        mark = 'pre-release' if e['TGN_PRE'] == '1' else 'release'
        lines = ['📦 <b>spdhost APK</b> (%s)' % mark,
                 '<b>tag</b> <code>%s</code>' % esc(e['TGN_TAG']),
                 commit,
                 '<b>sha256</b> <code>%s</code>' % esc(e['TGN_HASH'])]
        if e['TGN_METHOD'] == 'sendMessage':
            mb = int(e['TGN_SIZE']) / 1e6
            lines.append('%s is %.1f MB, over the Bot API 50 MB upload cap: download it from the release.'
                         % (esc(e['TGN_FILE']), mb))
        lines.append(esc(e['TGN_URL']))
    else:
        ok = e['TGN_RESULT'] == 'pass'
        lines = [('✅ PASS' if ok else '❌ FAIL') + ' — <b>spdhost CI</b>',
                 '<b>branch</b> <code>%s</code>' % esc(e['TGN_BRANCH']),
                 commit]
        if not ok and e['TGN_FAILED']:
            lines.append('<b>failed</b> ' + esc(e['TGN_FAILED']))
        lines.append('<b>run</b> ' + esc(e['TGN_RUN_URL']))
    return '\n'.join(lines)
limit = int(e['TGN_LIMIT'])
for n in range(120, -1, -1):
    t = build(n)
    if u16(t) <= limit:
        sys.stdout.write(t); sys.exit(0)
sys.stderr.write('tg-notify: the text is over %d characters even without the subject\n' % limit)
sys.exit(1)
PY

if [ "$dry" = 1 ]; then
	echo "method=$method"
	cat "$work/text"; echo
	exit 0
fi

# Send. The URL (with the token) and the chat id reach curl on stdin only.
code=0
if [ "$method" = sendDocument ]; then
	printf 'url = "%s/bot%s/%s"\nform-string = "chat_id=%s"\nform-string = "parse_mode=HTML"\n' \
		"$API" "$TELEGRAM_BOT_TOKEN" "$method" "$TELEGRAM_CHAT_ID" |
		curl -sS -K - --max-time 300 -o "$work/resp" -w '%{http_code}' \
			-F "caption=<$work/text" -F "document=@$file" >"$work/http" || code=$?
else
	printf 'url = "%s/bot%s/%s"\ndata-urlencode = "chat_id=%s"\ndata = "parse_mode=HTML"\ndata = "disable_web_page_preview=true"\n' \
		"$API" "$TELEGRAM_BOT_TOKEN" "$method" "$TELEGRAM_CHAT_ID" |
		curl -sS -K - --max-time 60 -o "$work/resp" -w '%{http_code}' \
			--data-urlencode "text@$work/text" >"$work/http" || code=$?
fi
http=$(cat "$work/http" 2>/dev/null || true)
if [ "$code" != 0 ]; then
	echo "::error title=Telegram::$method: curl failed (exit $code, HTTP ${http:-none})"
	exit 1
fi
if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("ok") is True else 1)' "$work/resp" 2>/dev/null; then
	echo "Telegram $method: ok (HTTP $http)"
	exit 0
fi
desc=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("description", "")[:300])
except Exception: print("reply was not JSON")' "$work/resp" 2>/dev/null || true)
echo "::error title=Telegram::$method: not ok (HTTP ${http:-?}): ${desc:-no description}"
exit 1
