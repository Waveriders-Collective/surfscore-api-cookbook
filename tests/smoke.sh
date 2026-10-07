#!/usr/bin/env bash
# Run every example against the real API with your key and check what it wrote.
#
# Usage:   set -a; . ./.env; set +a                   # loads SS_KEY (and SS_API if set)
#          ./tests/smoke.sh [--webhooks] [session-id]  # default: your newest completed walk test
# Needs:   bash, curl, jq, python3, openssl.
#
# Read-only by default. --webhooks also tests registration: it creates one webhook
# endpoint on an unresolvable host (*.invalid, so no delivery can leave your org),
# checks it, and deletes it, even if the run is interrupted.
#
# Outputs (your org's data) go to a fresh temp directory outside the repo. The key and
# webhook secrets are never printed. Exit status is non-zero if any check fails; WARN
# lines are problems on the API side that do not fail the cookbook.
set -uo pipefail

API="${SS_API:-https://api.surfscore.live}"
: "${SS_KEY:?set SS_KEY (load .env first: set -a; . ./.env; set +a)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EX="$ROOT/examples"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/surfscore-smoke.XXXXXX")"
auth=(-H "Authorization: Bearer $SS_KEY")
pass=0; fail=0; skip=0; warn=0
WEBHOOKS=0; SID=""; HAS_WEBHOOKS=0; WID=""
for arg in "$@"; do
  case "$arg" in
    --webhooks) WEBHOOKS=1 ;;
    -h|--help)  sed -n '2,15p' "$0"; exit 0 ;;
    *)          SID="$arg" ;;
  esac
done
# Never leave a test webhook behind, however the run ends.
cleanup() { [ -n "$WID" ] && curl -s -o /dev/null -X DELETE "$API/v1/webhooks/$WID" "${auth[@]}"; }
trap cleanup EXIT
trap 'exit 130' INT TERM   # route Ctrl-C / kill through the EXIT trap

ok()   { printf '  PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }
skp()  { printf '  SKIP  %s\n' "$*"; skip=$((skip + 1)); }
wrn()  { printf '  WARN  %s\n' "$*"; warn=$((warn + 1)); }
note() { printf '        %s\n' "$*"; }

# GET a path; prints the HTTP status, body goes to $OUT/last.json.
status_of() { curl -sS --retry 3 -o "$OUT/last.json" -w '%{http_code}' "$API$1" "${auth[@]}"; }
problem()   { jq -r '(.type // "" | split("/") | last) + " " + (.detail // "")' "$OUT/last.json" 2>/dev/null; }

# Checks a CSV written by an example: header on line 1, attribution on the last line,
# no "cell not captured" rows exported as PCI 0. Prints row stats for the record.
check_csv() {  # <file> <expected-first-column>
  python3 -I - "$1" "$2" <<'PY'
import csv, sys
path, first = sys.argv[1], sys.argv[2]
lines = open(path, newline="").read().splitlines()
errors = []
if not lines or not lines[0].startswith(first + ","):
    errors.append(f"line 1 is not the header (starts {lines[0][:40]!r})" if lines else "file is empty")
if not lines or not lines[-1].startswith("# SurfScore"):
    errors.append("last line is not the attribution line (export incomplete?)")
rows = list(csv.DictReader(l for l in lines if not l.startswith("#")))
if rows and "pci" in rows[0]:
    bogus = sum(1 for r in rows if r["pci"] == "0" and not r.get("earfcn") and not r.get("nrarfcn"))
    if bogus:
        errors.append(f"{bogus} rows exported PCI 0 with no ARFCN")
    n = len(rows)
    pct = lambda k: f"{100 * k / n:.1f}%" if n else "n/a"
    no_cell = sum(1 for r in rows if not r["pci"] and not r.get("earfcn") and not r.get("nrarfcn"))
    unresolved = sum(1 for r in rows if r.get("band") == "Unresolved")
    no_pos = sum(1 for r in rows if not r.get("lat"))
    nr_sa = sum(1 for r in rows if r.get("protocol") == "NR SA")
    print(f"STATS rows={n} no_cell_id={no_cell} ({pct(no_cell)}) band_unresolved={unresolved} ({pct(unresolved)}) "
          f"no_position={no_pos} ({pct(no_pos)}) labelled_NR_SA={nr_sa} ({pct(nr_sa)})")
else:
    print(f"STATS rows={len(rows)}")
for e in errors:
    print("ERROR " + e)
sys.exit(1 if errors else 0)
PY
}

echo "SurfScore cookbook smoke test against $API"
echo "Outputs: $OUT"
echo

echo "1. Key and scopes"
code=$(status_of "/v1/sessions?limit=1")
if [ "$code" = 200 ]; then ok "key accepted (GET /v1/sessions)"; else bad "GET /v1/sessions -> $code $(problem)"; fi
for probe in "/v1/scans?limit=1|read:scans" "/v1/coverage/hexes?from=2100-01-01T00:00:00Z|read:scans (coverage)" "/v1/webhooks|manage:webhooks"; do
  path="${probe%|*}"; scope="${probe#*|}"
  code=$(status_of "$path")
  case "$code" in
    200) ok "$scope present"; [ "$scope" = manage:webhooks ] && HAS_WEBHOOKS=1;;
    403) note "$scope absent: $(problem)  (examples needing it are skipped)";;
    *)   bad "$path -> $code $(problem)";;
  esac
done
# Regression check: customers call the API from many HTTP libraries, and every one of
# these must be accepted. A refusal without X-Request-Id never reached the API gateway:
# the network edge (or a proxy) rejected that client.
for ua in "Python-urllib/3.12" "python-requests/2.32.3" "Go-http-client/1.1" "node" "surfscore-cookbook/1.0"; do
  code=$(curl -sS --retry 2 -o /dev/null -D "$OUT/ua.headers" -w '%{http_code}' -A "$ua" "$API/v1/sessions?limit=1" "${auth[@]}")
  if [ "$code" = 200 ]; then ok "User-Agent '$ua' accepted"
  elif grep -qi '^x-request-id:' "$OUT/ua.headers"; then bad "User-Agent '$ua' -> $code from the API"
  else wrn "User-Agent '$ua' -> $code before reaching the API ($(grep -i '^server:' "$OUT/ua.headers" | tail -1 | tr -d '\r')): clients using it are refused at the edge"
  fi
done
for probe in "/llms.txt" "/v1/openapi.json"; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' "$API$probe")
  note "public $probe -> $code"
done

echo
echo "2. Pick a session"
if [ -z "$SID" ]; then
  status_of "/v1/sessions?mode=walk_test&status=completed&limit=1" >/dev/null
  SID=$(jq -r '.data.sessions[0].id // empty' "$OUT/last.json")
fi
if [ -z "$SID" ]; then
  skp "no completed walk-test session in this org: session examples not exercised"
else
  status_of "/v1/sessions/$SID" >/dev/null
  MAP=$(jq -r '.data.outdoor_map_id // .data.floorplan_id // empty' "$OUT/last.json")
  status_of "/v1/sessions/$SID/summary" >/dev/null
  EXPECT=$(jq -r '.data.row_count // empty' "$OUT/last.json")
  note "session $SID, map ${MAP:-none}, summary row_count ${EXPECT:-?}"

  echo
  echo "3. export_session.sh"
  if bash "$EX/export_session.sh" "$SID" > "$OUT/session.csv" 2> "$OUT/session.err"; then
    ok "exit 0"
  else
    bad "exit $? ($(tail -1 "$OUT/session.err"))"
  fi
  if res=$(check_csv "$OUT/session.csv" recorded_at); then ok "CSV shape"; else bad "CSV shape"; fi
  printf '%s\n' "$res" | sed 's/^/        /'
  got=$(printf '%s\n' "$res" | sed -n 's/^STATS rows=\([0-9]*\).*/\1/p')
  if [ -n "$EXPECT" ] && [ "$got" = "$EXPECT" ]; then ok "rows match summary ($got)"
  elif [ -n "$EXPECT" ]; then bad "rows $got, summary says $EXPECT"; fi

  echo
  echo "4. export_map.py"
  if [ -z "$MAP" ]; then
    skp "session has no map id"
  elif (cd "$OUT" && python3 "$EX/export_map.py" "$MAP" --out map > map.log 2>&1); then
    ok "exit 0 ($(tail -1 "$OUT/map.log"))"
    if res=$(check_csv "$OUT/map.csv" session_id); then ok "CSV shape"; else bad "CSV shape"; fi
    printf '%s\n' "$res" | sed 's/^/        /'
    if python3 -I -c "import json,sys;d=json.load(open(sys.argv[1]));assert d['type']=='FeatureCollection' and d['attribution']" "$OUT/map.geojson"; then
      ok "GeoJSON parses, attribution present"; else bad "GeoJSON"; fi
  else
    bad "exit non-zero:"
    tail -5 "$OUT/map.log" | sed 's/^/        /'
  fi

  echo
  echo "5. session_report.sh"
  if (cd "$OUT" && bash "$EX/session_report.sh" "$SID" > report.txt 2> report.err); then
    hm=$(ls "$OUT"/heatmap_*.csv 2>/dev/null | head -1)
    if [ -n "$hm" ] && tail -1 "$hm" | grep -q '^# SurfScore'; then ok "exit 0, heatmap $(basename "$hm") written"
    else bad "heatmap file missing or without attribution"; fi
  else
    bad "exit non-zero: $(tail -1 "$OUT/report.err")"
  fi
fi

echo
echo "6. coverage_hexes.sh"
if status_of "/v1/scans?limit=1" | grep -q 200; then
  if bash "$EX/coverage_hexes.sh" > "$OUT/hexes.csv" 2> "$OUT/hexes.err"; then
    rows=$(grep -vc '^#' "$OUT/hexes.csv"); rows=$((rows - 1))
    if head -1 "$OUT/hexes.csv" | grep -q '^h3_cell_9,' && tail -1 "$OUT/hexes.csv" | grep -q '^# SurfScore'; then
      ok "exit 0, $rows hexes, header + attribution"; else bad "CSV shape"; fi
  else
    bad "exit non-zero: $(tail -1 "$OUT/hexes.err")"
  fi
else
  skp "key lacks read:scans"
fi

echo
echo "7. webhook_listener.py (local only: signs test payloads itself, never calls the API)"
PORT=$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
WEBHOOK_SECRET=whsec_smoke python3 "$EX/webhook_listener.py" "$PORT" > "$OUT/webhook.log" 2>&1 &
wpid=$!
sleep 1
body='{"event":"session.completed","session":{"id":"smoke","session_mode":"walk_test","status":"completed","tenant_id":"t","started_at":"x","ended_at":"y"}}'
t=$(date +%s)
sig=$(printf '%s' "$t.$body" | openssl dgst -sha256 -hmac whsec_smoke | awk '{print $NF}')
post() { curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT" -H "X-Surfscore-Signature: $1" -H "X-Surfscore-Delivery: d$RANDOM" --data-binary "$body"; }
[ "$(post "t=$t,v1=$sig")" = 204 ] && ok "valid signature -> 204" || bad "valid signature not accepted"
[ "$(post "t=$t,v1=00")" = 401 ] && ok "wrong signature -> 401" || bad "wrong signature not rejected"
[ "$(post "")" = 401 ] && ok "missing signature -> 401" || bad "missing signature not rejected"
[ "$(post "t=$((t - 600)),v1=$sig")" = 401 ] && ok "stale timestamp -> 401" || bad "stale timestamp not rejected"
kill "$wpid" 2>/dev/null

echo
echo "8. Webhook registration"
if [ "$WEBHOOKS" != 1 ]; then
  skp "not requested (run with --webhooks)"
elif [ "$HAS_WEBHOOKS" != 1 ]; then
  skp "key lacks manage:webhooks"
else
  post_json() { curl -sS -o "$OUT/last.json" -w '%{http_code}' -X POST "$API/v1/webhooks" "${auth[@]}" -H 'Content-Type: application/json' -d "$1"; }
  status_of "/v1/webhooks" >/dev/null
  n=$(jq '.data.webhooks | length' "$OUT/last.json")
  if [ "$n" -ge 10 ]; then
    skp "org already has $n endpoints (the limit is 10)"
  else
    code=$(post_json '{"url":"http://surfscore-smoke.invalid/hook"}')
    [ "$code" = 400 ] && ok "http:// URL rejected (400)" || bad "http:// URL -> $code (expected 400)"
    # .invalid never resolves (RFC 2606), so no delivery to this endpoint can leave the org.
    code=$(post_json "{\"url\":\"https://surfscore-smoke-$(date +%s).invalid/hook\",\"events\":[\"session.completed\"]}")
    WID=$(jq -r '.data.id // empty' "$OUT/last.json")
    if [ "$code" = 201 ] && [ -n "$WID" ]; then ok "created (201)"; else bad "create -> $code $(problem)"; fi
    if jq -e '.data.secret | startswith("whsec_")' "$OUT/last.json" >/dev/null 2>&1; then
      ok "signing secret returned once (whsec_..., not printed)"
    else
      bad "no whsec_ secret in the create response"
    fi
    rm -f "$OUT/last.json"   # it held the secret
    if [ -n "$WID" ]; then
      status_of "/v1/webhooks" >/dev/null
      jq -e --arg id "$WID" '.data.webhooks | any(.id == $id)' "$OUT/last.json" >/dev/null && ok "listed" || bad "not in GET /v1/webhooks"
      jq -e '.data.webhooks | all(has("secret") | not)' "$OUT/last.json" >/dev/null && ok "list never includes secrets" || bad "list includes a secret"
      gone="$WID"
      code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$API/v1/webhooks/$WID" "${auth[@]}")
      if [ "$code" = 204 ]; then ok "deleted (204)"; WID=""; else bad "delete -> $code"; fi
      status_of "/v1/webhooks" >/dev/null
      jq -e --arg id "$gone" '.data.webhooks | any(.id == $id) | not' "$OUT/last.json" >/dev/null && ok "gone from the list" || bad "still listed after delete"
      code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$API/v1/webhooks/$gone" "${auth[@]}")
      [ "$code" = 404 ] && ok "second delete -> 404" || bad "second delete -> $code (expected 404)"
    fi
  fi
fi
note "Delivery end to end needs a public HTTPS URL and a session starting or ending: see examples/webhook_listener.py."

echo
echo "Result: $pass passed, $fail failed, $warn warnings, $skip skipped. Outputs in $OUT (your org's data: delete when done)."
[ "$fail" -eq 0 ]
