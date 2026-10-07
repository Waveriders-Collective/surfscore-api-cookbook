#!/usr/bin/env python3
"""Export every completed session on one map (outdoor map or floorplan) to CSV + GeoJSON.

Usage:
    SS_KEY=ss_live_... python3 export_map.py <map-id> [--since 2026-09-01] [--mode walk_test|monitor|any] [--out circuit]

Key scopes: read:sessions, read:telemetry. Standard library only (Python 3.9+).

The map id is the outdoor_map_id / floorplan_id you see on session objects, or in a
dashboard URL such as https://dashboard.surfscore.live/outdoor-maps/<id>/heatmap.
"""
import argparse
import csv
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = os.environ.get("SS_API", "https://api.surfscore.live")
KEY = os.environ.get("SS_KEY")
# Name the client, so its requests are easy to find when asking for support.
USER_AGENT = "surfscore-cookbook/1.0 (+https://github.com/Waveriders-Collective/surfscore-api-cookbook)"

COLS = [
    "session_id", "device_label", "recorded_at", "device_id", "modem_id",
    "lat", "lng", "accuracy_m", "speed", "heading",
    "protocol", "carrier", "mcc", "mnc", "band", "earfcn", "nrarfcn", "pci",
    "rsrp", "rsrq", "sinr", "rssi", "bandwidth", "surf_score",
    "rtt_ms", "jitter_ms", "packet_loss_pct",
]


def get(path, **params):
    """GET with bearer auth, retrying on 429. Returns the parsed JSON body."""
    qs = urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
    url = f"{API}{path}" + (f"?{qs}" if qs else "")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {KEY}", "User-Agent": USER_AGENT})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < 4:
                time.sleep(int(e.headers.get("Retry-After", "60")))
                continue
            body = e.read().decode(errors="replace")
            rid = e.headers.get("X-Request-Id")
            if rid:  # an API error: RFC 9457 problem+json
                sys.exit(f"{e.code} on {path}: {body[:400]}\n(request id: {rid})")
            # Every API response carries X-Request-Id, so this one came from somewhere else.
            first = " ".join(body.split())[:200]
            sys.exit(f"{e.code} on {path} did not come from the SurfScore API (no X-Request-Id; "
                     f"server={e.headers.get('Server')}, cf-ray={e.headers.get('CF-Ray')}). "
                     f"Likely refused by a proxy or the network edge. Body starts: {first}")


def paged(path, collection, **params):
    """Yield items from a cursor-paginated list endpoint."""
    cursor = None
    while True:
        body = get(path, limit=1000, cursor=cursor, **params)
        yield from body["data"][collection]
        cursor = body["data"].get("next_cursor")
        if not cursor:
            return


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("map_id")
    ap.add_argument("--since", help="ISO date/time lower bound on started_at")
    ap.add_argument("--mode", default="walk_test", choices=["walk_test", "monitor", "any"],
                    help="session mode to include (default walk_test: drive and walk tests)")
    ap.add_argument("--out", default="map_export", help="output file stem")
    args = ap.parse_args()
    if not KEY:
        sys.exit("set SS_KEY to your ss_live_... key")

    sessions = [
        s for s in paged("/v1/sessions", "sessions", status="completed", **{
            "mode": None if args.mode == "any" else args.mode, "from": args.since})
        if args.map_id in (s.get("outdoor_map_id"), s.get("floorplan_id"))
    ]
    print(f"{len(sessions)} completed sessions on map {args.map_id}", file=sys.stderr)
    if not sessions:
        return

    attribution = None
    features = []
    rows = 0
    with open(f"{args.out}.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS, extrasaction="ignore")
        w.writeheader()
        for s in sessions:
            cursor = None
            while True:
                body = get(f"/v1/sessions/{s['id']}/telemetry", limit=1000, cursor=cursor)
                attribution = body["attribution"]
                for row in body["data"]["telemetry"]:
                    # pci 0 with no EARFCN and no NR-ARFCN means the Android app did not
                    # capture the cell (README §4), not PCI 0: export it as empty.
                    if row.get("pci") == 0 and row.get("earfcn") is None and row.get("nrarfcn") is None:
                        row["pci"] = None
                    row["session_id"] = s["id"]
                    row["device_label"] = s.get("device_label")
                    w.writerow(row)
                    rows += 1
                    if row.get("lat") is not None and row.get("lng") is not None:
                        features.append({
                            "type": "Feature",
                            "geometry": {"type": "Point", "coordinates": [row["lng"], row["lat"]]},
                            "properties": {k: row.get(k) for k in COLS},
                        })
                cursor = body["data"].get("next_cursor")
                if not cursor:
                    break
            print(f"  {s['id']} {s.get('device_label') or ''} ok", file=sys.stderr)
        f.write(f"# {attribution['text']} {attribution['url']}\n")

    with open(f"{args.out}.geojson", "w") as f:
        json.dump({
            "type": "FeatureCollection",
            "features": features,
            "attribution": attribution,
            "unplaced_rows": rows - len(features),
        }, f)
    print(f"wrote {rows} rows → {args.out}.csv, {len(features)} placed points → {args.out}.geojson", file=sys.stderr)


if __name__ == "__main__":
    main()
