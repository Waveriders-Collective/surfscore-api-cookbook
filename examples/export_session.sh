#!/usr/bin/env bash
# Export one SurfScore session to CSV, one row per telemetry sample.
#
# Usage:   SS_KEY=ss_live_... ./export_session.sh <session-id> > session.csv
# Needs:   curl, jq. Key scopes: read:sessions, read:telemetry.
#
# Columns are the ones a partner usually wants. Add more from the row object
# (see README §4) by extending COLS and the jq array in the same order.
#
# The header row is line 1 so Excel, QGIS and pandas detect it. The session
# details and the attribution follow the data as "# " lines. A file that does
# not end with the attribution line is incomplete: the script stopped early.
set -euo pipefail

API="${SS_API:-https://api.surfscore.live}"
SID="${1:?usage: export_session.sh <session-id>}"
: "${SS_KEY:?set SS_KEY to your ss_live_... key}"

auth=(-H "Authorization: Bearer $SS_KEY")
# --retry covers 429 (curl waits for Retry-After) and transient 5xx / timeouts.
get=(curl -fsS --retry 5 --retry-max-time 300)

# Session details, written after the data so the header row stays on line 1.
session=$("${get[@]}" "$API/v1/sessions/$SID" "${auth[@]}" \
  | jq -r '.data | "# session_id=\(.id) started_at=\(.started_at) ended_at=\(.ended_at // "") device_label=\(.device_label // "") location_type=\(.location_type) map_id=\(.outdoor_map_id // .floorplan_id // "")"')

COLS="recorded_at,device_id,modem_id,lat,lng,accuracy_m,speed,heading,protocol,carrier,mcc,mnc,band,earfcn,nrarfcn,pci,rsrp,rsrq,sinr,rssi,bandwidth,surf_score,rtt_ms,jitter_ms,packet_loss_pct"
echo "$COLS"

cursor=""
attribution=""
while :; do
  url="$API/v1/sessions/$SID/telemetry?limit=1000"
  if [ -n "$cursor" ]; then
    url="$url&cursor=$(printf %s "$cursor" | jq -sRr @uri)"
  fi
  resp=$("${get[@]}" "$url" "${auth[@]}")
  # pci 0 with no EARFCN and no NR-ARFCN means the Android app did not capture the
  # cell (README §4), not PCI 0, so it is written as an empty cell.
  printf '%s' "$resp" | jq -r '.data.telemetry[] |
    (if .pci == 0 and .earfcn == null and .nrarfcn == null then null else .pci end) as $pci |
    [.recorded_at,.device_id,.modem_id,.lat,.lng,.accuracy_m,.speed,.heading,.protocol,.carrier,.mcc,.mnc,
     .band,.earfcn,.nrarfcn,$pci,.rsrp,.rsrq,.sinr,.rssi,.bandwidth,.surf_score,.rtt_ms,.jitter_ms,.packet_loss_pct] | @csv'
  attribution=$(printf '%s' "$resp" | jq -r '.attribution.text + " " + .attribution.url')
  cursor=$(printf '%s' "$resp" | jq -r '.data.next_cursor // empty')
  [ -z "$cursor" ] && break
done

echo "$session"
# Required on redistribution. Always the last line.
echo "# $attribution"
