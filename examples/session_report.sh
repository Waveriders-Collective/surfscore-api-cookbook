#!/usr/bin/env bash
# One-page rollup for a session plus a 10 m heatmap grid you can drop into QGIS / kepler.gl.
#
# Usage:  SS_KEY=ss_live_... ./session_report.sh <session-id> [<map-id>] [<cell-metres>]
# Needs:  curl, jq. Key scopes: read:sessions, read:reports.
#
# <map-id> defaults to the session's own outdoor_map_id (or floorplan_id). For a floorplan the
# cell unit is pixels, not metres, and the grid has cell_x/cell_y instead of cell_lat/cell_lng.
set -euo pipefail

API="${SS_API:-https://api.surfscore.live}"
SID="${1:?usage: session_report.sh <session-id> [map-id] [cell]}"
: "${SS_KEY:?set SS_KEY to your ss_live_... key}"
auth=(-H "Authorization: Bearer $SS_KEY")
# --retry covers 429 (curl waits for Retry-After) and transient 5xx / timeouts.
curl() { command curl --retry 5 --retry-max-time 300 "$@"; }

session=$(curl -fsS "$API/v1/sessions/$SID" "${auth[@]}" | jq .data)
map_id="${2:-$(jq -r '.outdoor_map_id // .floorplan_id' <<<"$session")}"
kind=$(jq -r 'if .location_type == "indoor_floorplan" then "floorplan" else "outdoor" end' <<<"$session")
cell="${3:-$([ "$kind" = outdoor ] && echo 10 || echo 16)}"

echo "## Session"
jq -r '"id: \(.id)\ndevice: \(.device_label // "-")\nstarted: \(.started_at)\nended: \(.ended_at // "-")\nlocation: \(.location_type)\nmap: \(.outdoor_map_id // .floorplan_id // "-")"' <<<"$session"

echo; echo "## Summary"
curl -fsS "$API/v1/sessions/$SID/summary" "${auth[@]}" \
  | jq -r '.data | "rows: \(.row_count)  devices: \(.device_count)  duration_s: \(.duration_seconds)\nRSRP avg/p50: \(.rsrp_avg)/\(.rsrp_p50) dBm   RSRQ avg: \(.rsrq_avg) dB   SINR avg: \(.sinr_avg) dB\nSurfScore avg/p50: \(.surf_score_avg)/\(.surf_score_p50)  (\(.score_version))\ncarriers: \(.carriers | join(", "))\nbands: \(.bands | join(", "))"'

echo; echo "## Timeline (60 s buckets, per device)"
curl -fsS "$API/v1/sessions/$SID/timeline?bucket_seconds=60" "${auth[@]}" \
  | jq -r '.data.buckets[] | [.bucket_start, .device_id, .sample_count, .rsrp_avg, .sinr_avg, .surf_score_avg] | @tsv' \
  | if command -v column >/dev/null; then column -t; else cat; fi

out="heatmap_${SID}_${cell}.csv"
echo; echo "## Heatmap → $out  (kind=$kind, cell=$cell)"
resp=$(curl -fsS "$API/v1/maps/$map_id/heatmap?kind=$kind&session_ids=$SID&cell=$cell" "${auth[@]}")
if [ "$kind" = outdoor ]; then
  { echo "cell_lat,cell_lng,sample_count,avg_rsrp,avg_rsrq,avg_sinr,avg_bandwidth";
    jq -r '.data.cells[] | [.cell_lat,.cell_lng,.sample_count,.avg_rsrp,.avg_rsrq,.avg_sinr,.avg_bandwidth] | @csv' <<<"$resp"; } > "$out"
else
  { echo "cell_x,cell_y,sample_count,avg_rsrp,avg_rsrq,avg_sinr,avg_bandwidth";
    jq -r '.data.cells[] | [.cell_x,.cell_y,.sample_count,.avg_rsrp,.avg_rsrq,.avg_sinr,.avg_bandwidth] | @csv' <<<"$resp"; } > "$out"
fi
jq -r '"# " + .attribution.text + " " + .attribution.url' <<<"$resp" >> "$out"
jq -r '.data.facets[] | "  \(.operator) · \(.band) · \(.device_id)\(.modem_id // "" | if . == "" then "" else "/" + . end): \(.sample_count) samples"' <<<"$resp"
echo "$(( $(wc -l < "$out") - 2 )) cells written"
