# Notes for coding agents (Claude Code, Cursor, Codex, Copilot)

You are helping a user pull data from the SurfScore External API. Read this file
and `README.md`, then the relevant file in `examples/`. The full machine spec is
`openapi/openapi.json` (also live at `https://api.surfscore.live/v1/openapi.json`).

## Facts that are not obvious from the spec

- **Auth**: `Authorization: Bearer ss_live_…`. The key is bound to one
  organisation; there is no org parameter anywhere. Never put the key in a URL.
- **Scopes are per key**. A `403` with `type: …/insufficient-scope` means the user
  must mint a new key with the extra scope at surfscore.live → avatar → API Keys.
  Tell them which scope; do not retry. Other `403` types: `revoked` / `expired`
  (new key needed), `flag-disabled` (API access not switched on for the org:
  support@waveriders.live), `subscription-inactive` (plan lapsed).
- **Envelope**: rows live under `data.<collection>`; `data.next_cursor` drives
  pagination. GeoJSON (`?format=geojson`) is a bare `FeatureCollection` instead,
  with `next_cursor` as a top-level member next to `features`.
- **Cursors are opaque strings**, sometimes containing `+ / =` and newlines.
  Always URL-encode them. Stop when `next_cursor` is `null`.
- **Max `limit` is 1000** on every list endpoint. Telemetry defaults to 1000.
- **Rate limit** is 300 requests/minute/key. On `429` honour `Retry-After`
  (currently 60 s). Do not parallelise beyond ~4 concurrent requests.
- **`band` and `carrier` are server-resolved**, not the device's own labels.
  Raw inputs (`earfcn`, `nrarfcn`, `mcc`, `mnc`) are on the same row if the user
  wants to resolve differently. `"Unresolved"` / `"Unknown"` are literal values,
  never dropped, so counts reconcile. Band resolution uses US channel tables
  today: outside the US `band` can be `Unresolved` or wrong (n78 as n77, n1 as
  n66, n7 as n41), so for non-US sessions report `earfcn`/`nrarfcn` alongside it.
- **`pci` is not globally unique.** Always export it next to `earfcn`/`nrarfcn`.
  Android rows labelled `protocol = "NR SA"` may carry `pci = 0` with no ARFCN
  (app bug, fix pending; most are really NSA, so the label is wrong too):
  treat `pci == 0 && earfcn == null && nrarfcn == null` as unknown, not cell 0.
  The example exports write an empty PCI for these rows.
- **GPS**: `lat`/`lng` are `null` when the phone had no usable fix. The RF row is
  still present. `?format=geojson` omits those rows and reports the count in
  `omitted_indoor_count` (the name is historical; it covers any row without a
  position, indoor or not).
- **Indoor sessions** (`location_type = indoor_floorplan`) carry `x`/`y` in
  floorplan pixels and no lat/lng. The floorplan image itself is not served by
  the API.
- **Map ids**: there is no maps listing endpoint yet. `outdoor_map_id` /
  `floorplan_id` come from session objects, or from the dashboard URL
  (`/outdoor-maps/<id>/heatmap`). Group sessions by `outdoor_map_id` client-side.
- **CSV**: the API does not emit CSV. Build it from JSON; the examples show the
  column order we recommend. Put `attribution.text` as the last line.
- **Timeline** parameter is `bucket_seconds` (min 10). Over 5000 buckets → `400`.
- **Caching**: completed sessions and summaries return an `ETag`; everything
  else is `no-store`. The gateway does not answer `If-None-Match` with `304`
  yet, so conditional requests save nothing today.
- **Errors** are RFC 9457 `application/problem+json`: `type`, `title`, `status`,
  `detail`, plus `X-Request-Id` on every response. Quote the request id in bug
  reports. A response **without** `X-Request-Id` (often an HTML page) never
  reached the API: a proxy or the network edge refused it. Report the status,
  `Server` and `CF-Ray` headers instead.
- **User-Agent**: send a descriptive one that names your integration (the
  examples send `surfscore-cookbook/1.0 (+repo url)`). It makes your requests
  easy to find when you ask for support. Library defaults are accepted.
- **Webhooks**: `POST /v1/webhooks` returns a `whsec_` secret once. Payloads are
  signed; see `examples/webhook_listener.py` for verification.

## What the user usually wants

| Ask | Do |
|---|---|
| "Export session X" | `examples/export_session.sh X` → CSV with the recommended columns |
| "Everything from circuit/map Y" | `python3 examples/export_map.py Y` (key from `SS_KEY`; `--mode any` to include monitor sessions) → CSV + GeoJSON |
| "Summary for a partner" | `examples/session_report.sh X [MAP_ID]` → text summary + 10 m heatmap CSV |
| "Coverage map of our devices" | `examples/coverage_hexes.sh` → H3 res-9 cells with SurfScore |
| "Tell me when a test finishes" | `examples/webhook_listener.py` |

## Do not

- Do not write the key into files you commit. Read it from `SS_KEY`, which the
  user keeps in `.env` (gitignored; template in `.env.example`) and loads with
  `set -a; . ./.env; set +a`. Never print it or paste it into a URL or log.
- After changing an example, run `tests/smoke.sh` (real API, read-only) and
  report its PASS/FAIL/SKIP lines.
- Do not fabricate fields. If a field is absent in the spec, say so.
- Do not strip the attribution line when writing files for third parties.
- Do not assume `band` equals what the phone displayed; it is PLMN/ARFCN-resolved.
- Do not paste the user's data, keys, or session/map/device ids into issues or pull
  requests on this repo. It is public.

## Repo layout

```
README.md            human quickstart
AGENTS.md            this file
openapi/openapi.json mirror of the live spec (check the live one if in doubt)
examples/            runnable recipes, stdlib-only Python and curl+jq shell
llms.txt             agent index; to be served at https://api.surfscore.live/llms.txt
tests/smoke.sh       runs every example against the real API and checks the outputs
.env.example         template for .env (gitignored), which holds SS_KEY
```
