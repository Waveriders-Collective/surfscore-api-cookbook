# SurfScore External API — cookbook

Working examples for pulling your organisation's cellular coverage data out of
[SurfScore](https://surfscore.live): walk-test and drive-test sessions, per-second
telemetry (RSRP, RSRQ, SINR, PCI, band, ARFCN, GPS), heatmaps, SurfScan scan
sessions and H3 coverage rollups.

- Base URL: `https://api.surfscore.live`
- Interactive docs: <https://api.surfscore.live/v1/docs>
- Machine spec: <https://api.surfscore.live/v1/openapi.json> (mirrored in [`openapi/`](openapi/))
- For coding agents: read [`AGENTS.md`](AGENTS.md) first.

Everything here is read-only against **your own org's data**. Nothing in this repo
can see another organisation.

## 1. Get a key (one minute)

1. Sign in at <https://surfscore.live>, open the avatar menu → **API Keys**.
   You need the org **admin** role, an active Team subscription, and API access
   switched on for your org. If the page says API access isn't enabled, email
   <support@waveriders.live>.
2. Create a key. Pick scopes:
   - `read:sessions` — list sessions, per-session summary and timeline
   - `read:telemetry` — raw per-second rows (this is the one you want for exports)
   - `read:reports` — heatmaps, operator-compare and expert reports
   - `read:scans` — SurfScan QSCAN scan sessions, H3 coverage, sensor rollups
   - `manage:webhooks` — register session-lifecycle webhooks
3. Copy the key once. It looks like `ss_live_…` and is never shown again.

```bash
export SS_KEY='ss_live_...'
curl -s https://api.surfscore.live/v1/sessions?limit=3 \
  -H "Authorization: Bearer $SS_KEY" | jq .
```

To keep the key out of your shell history, copy `.env.example` to `.env`
(gitignored), put the key there, and load it with `set -a; . ./.env; set +a`.

If you see `401`, the key is wrong. A `403` says why in the last part of its
`type` URL:

| `type` ends in | Meaning |
|---|---|
| `insufficient-scope` | The key lacks the scope that endpoint needs. Create a key with it |
| `revoked`, `expired` | The key was revoked or has expired. Create a new one |
| `flag-disabled` | API access isn't switched on for your org |
| `subscription-inactive` | The org's plan has lapsed |

## 2. The three rules

1. **Envelope.** Every JSON response is `{ "data": …, "attribution": {…}, "meta": {"request_id": …} }`.
   Your rows are under `data`. GeoJSON responses are a bare `FeatureCollection`
   with `attribution` and `meta` as extra top-level members.
2. **Pagination.** List endpoints return `data.next_cursor`. Pass it back as
   `?cursor=` until it is `null`. Cursors are opaque; URL-encode them. Max
   `limit` is 1000.
3. **Attribution.** The `attribution.text` string ("SurfScore(TM) - Waveriders
   Collective Inc.") must accompany any data you redistribute, for example as the
   last line of a CSV you hand to a partner.

Rate limit: 300 requests per minute per key. A `429` carries `Retry-After`.

## 3. Recipes

| Goal | Example | Scopes |
|---|---|---|
| Export one session to CSV, every second, with PCI/band/ARFCN/GPS | [`examples/export_session.sh`](examples/export_session.sh) | `read:sessions`, `read:telemetry` |
| Export every session on one map/circuit to CSV + GeoJSON | [`examples/export_map.py`](examples/export_map.py) | `read:sessions`, `read:telemetry` |
| One-page rollup for a session + 10 m heatmap grid | [`examples/session_report.sh`](examples/session_report.sh) | `read:sessions`, `read:reports` |
| Get notified when a session completes | [`examples/webhook_listener.py`](examples/webhook_listener.py) | `manage:webhooks` |
| Org-wide H3 coverage with SurfScore per hex | [`examples/coverage_hexes.sh`](examples/coverage_hexes.sh) | `read:scans` |

All Python examples use only the standard library (Python 3.9+). Shell examples
need `curl` and `jq`. A CSV the scripts write ends with the attribution line;
if that line is missing, the export stopped early.

### Quickest path: a session to CSV

```bash
export SS_KEY='ss_live_...'
# find the session
curl -s "https://api.surfscore.live/v1/sessions?mode=walk_test&status=completed&limit=20" \
  -H "Authorization: Bearer $SS_KEY" \
  | jq -r '.data.sessions[] | [.id, .started_at, .device_label, .location_type] | @tsv'

# export it
./examples/export_session.sh <session-id> > session.csv
```

## 4. What a telemetry row contains

Each row from `GET /v1/sessions/{id}/telemetry` has the raw device metrics plus
server-resolved names. The important ones:

| Field | Meaning |
|---|---|
| `recorded_at` | UTC timestamp of the sample (about one per second for phone walk tests) |
| `device_id`, `modem_id` | Which phone/router and which modem produced it |
| `lat`, `lng`, `accuracy_m`, `speed`, `heading` | GPS. `lat`/`lng` are `null` when the device had no usable fix; the row is still kept |
| `x`, `y` | Indoor floorplan pixel position (indoor sessions only) |
| `rsrp`, `rsrq`, `sinr`, `rssi` | dBm / dB as reported by the device |
| `pci` | Physical cell id. Not globally unique: pair it with `earfcn`/`nrarfcn` |
| `earfcn`, `nrarfcn` | Raw LTE / NR channel numbers from the device |
| `band` | **Resolved** 3GPP band (e.g. `B66`, `n41`) derived from the ARFCN, not the device label. `Unresolved` when no ARFCN was captured. Outside the US, see the caveats below |
| `carrier`, `mcc`, `mnc` | **Resolved** operator name from the PLMN, plus the raw PLMN |
| `protocol` | `LTE`, `NR NSA`, `NR SA` as the device labelled it. See the caveats below |
| `surf_score` | Server-computed 0–100 composite (formula version in `meta.score_version`) |
| `rtt_ms`, `jitter_ms`, `packet_loss_pct`, `dl_mbps`, `ul_mbps` | QoE fields when the source measures them |

### Known caveats (October 2026)

- **Android 5G rows without a cell.** The Android app can label a sample
  `NR SA` and upload it with `pci = 0` and no `earfcn` or `nrarfcn`. Most of
  these come from phones that were really on 5G NSA, so the `protocol` label is
  wrong as well. The RSRP is real, but the cell is unknown and `band` is
  `Unresolved`. On some phone models this is a large share of rows. Treat
  `pci == 0` with both ARFCNs null as "cell not captured", not PCI 0; the
  example exports write an empty PCI for these rows. A fix is in progress in
  the SurfScan Connect app.
- **Bands outside the US.** Band resolution currently uses US channel tables.
  For sessions in Europe and elsewhere, `band` can be `Unresolved` or wrong (for
  example n78 shown as n77, n1 as n66, n7 as n41). Use `earfcn` / `nrarfcn`,
  which are what the phone reported, until the server-side fix lands.
- **Rows without a position.** `lat`/`lng` are null when the phone had no usable
  GPS fix (on some phones a large share of a drive). The row is kept. Fields
  saying how each position was obtained (`position_source`, `fix_age_ms`) are
  coming; add them to your column list when they appear.
- **Operator names can change** when the registry is corrected. For example,
  310-830 is T-Mobile's satellite service (`T-Satellite`), and older rows may
  still say `Sprint` until they are corrected. Keep `mcc`/`mnc` in exports so
  rows can be re-labelled later.

## 5. Other endpoints

See the [interactive docs](https://api.surfscore.live/v1/docs). In short:

- `GET /v1/sessions`, `/v1/sessions/{id}`, `/summary`, `/telemetry`, `/timeline`
- `GET /v1/maps/{id}/heatmap?kind=outdoor|floorplan&session_ids=…&cell=…`
- `GET /v1/scans`, `GET /v1/coverage/hexes`, `GET /v1/reports/operator-compare`, `GET /v1/reports/expert`
- `GET /v1/sessions/{id}/sensors`, `GET /v1/sensors/{deviceId}/timeseries`
- `POST|GET|DELETE /v1/webhooks`

## 6. Check your setup

`tests/smoke.sh` runs every example against the API with your key and checks
what it wrote: header row first, attribution last, row count equal to the
session summary, no fake PCI 0. It also prints how many rows have no cell
identity, an `Unresolved` band, or no position. It only reads, never prints
the key, and writes its output to a temp directory outside the repo.

```bash
set -a; . ./.env; set +a
./tests/smoke.sh                 # your newest completed walk test
./tests/smoke.sh <session-id>    # or a specific session
./tests/smoke.sh --webhooks      # also test webhook registration (needs manage:webhooks)
```

`--webhooks` creates one webhook endpoint on a hostname that can never resolve
(`*.invalid`), so no delivery can leave your org. It checks the create, list and
delete responses, then deletes the endpoint, even if you interrupt the run.

Needs `bash`, `curl`, `jq`, `python3` and `openssl`. Examples whose scope your key
lacks, or whose data your org doesn't have, are reported as SKIP. WARN lines are
problems on the API side, for example a client library refused at the network
edge; they don't fail the run.

## 7. Support

Open an issue in this repo for cookbook bugs or missing recipes. For account,
key or data questions email <support@waveriders.live>.

Licensed under Apache-2.0. SurfScore is a trademark of Waveriders Collective Inc.
