#!/usr/bin/env bash
# Org-wide H3 (resolution 9, ~174 m) coverage rollup from SurfScan router scans, as CSV.
#
# Usage:  SS_KEY=ss_live_... ./coverage_hexes.sh [from-iso] [to-iso] [device_id,device_id,...] > hexes.csv
# Needs:  curl, jq. Key scope: read:scans.
#
# Each row: h3 cell, centroid, SurfScore (0-100), scan/session/operator counts. Not paginated.
# Load the CSV into kepler.gl (it understands an h3 column) or convert cells to polygons with h3-py.
set -euo pipefail

API="${SS_API:-https://api.surfscore.live}"
: "${SS_KEY:?set SS_KEY to your ss_live_... key}"
q=""
[ -n "${1:-}" ] && q="$q&from=$(printf %s "$1" | jq -sRr @uri)"
[ -n "${2:-}" ] && q="$q&to=$(printf %s "$2" | jq -sRr @uri)"
[ -n "${3:-}" ] && q="$q&device_ids=$(printf %s "$3" | jq -sRr @uri)"

resp=$(curl -fsS --retry 5 --retry-max-time 300 "$API/v1/coverage/hexes?${q#&}" -H "Authorization: Bearer $SS_KEY")
echo "h3_cell_9,latitude,longitude,surfscore,scan_count,session_count,operator_count"
jq -r '.data.hexes[] | [.h3_cell_9,.latitude,.longitude,.surfscore,.scan_count,.session_count,.operator_count] | @csv' <<<"$resp"
jq -r '"# " + .attribution.text + " " + .attribution.url + "  score_version=" + (.data.hexes[0].score_version // "n/a")' <<<"$resp"
