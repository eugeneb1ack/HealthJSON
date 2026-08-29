<p align="center">
  <img src="docs/assets/health-json-cover.png" alt="Health JSON: private Apple Health export from iPhone to JSON, CSV, and a secure API" width="100%">
</p>

<p align="center">
  <a href="README.md">Русский</a> · <strong>English</strong>
</p>

# Health JSON

**Private Apple Health export from iPhone to JSON, CSV, iCloud Drive, and your own HTTPS API.**

Health JSON is for people whose health data lives in the Apple Health app on an iPhone, but who need to work with it outside Apple Health: on a Mac, Linux computer, NAS, Raspberry Pi, home server, spreadsheet, custom application, or AI agent. It creates a compact 365-day snapshot and delivers it through a method chosen by the owner: iCloud Drive, the iOS Share sheet, or a private Tailscale API.

Health JSON is not a medical service and not a vendor cloud. It creates no account, sends nothing to a developer-operated server, and does not make medical recommendations. The iPhone owner controls the permissions, storage location, and optional receiver.

## What it is for

- **Personal analysis and spreadsheets.** Open the current CSV in Numbers, Excel, LibreOffice, or pandas to compare sleep, activity, workouts, and measurements.
- **Your own application or automation.** Consume structured JSON in a desktop app, database, or home service through a documented private HTTPS contract.
- **AI agents.** Give an agent a compact snapshot and subsequent changes, allowing it to build a personal baseline, identify trends, and prepare summaries. An agent must not diagnose or change treatment.
- **Devices without Apple Health.** Use the data on any compatible Tailscale receiver, not just a Mac: a computer, VM, server, NAS, or other device running the documented HTTPS service.

## How it works

```text
Apple Health on iPhone
          │  permitted read access through HealthKit
          ▼
      Health JSON
       │       │
       │       ├── iCloud Drive: JSON + CSV
       │       ├── Share sheet: a fresh JSON or CSV file
       │       └── Tailscale: optional private HTTPS API
       ▼
Spreadsheet · custom app · server · AI agent
```

The primary file is the complete `health-context.json` snapshot. A CSV sits beside it for spreadsheet tools, but JSON remains the canonical contract for software and APIs. The in-app **Health data** viewer reads this exact JSON instead of launching a second heavy HealthKit query, so the view matches the exported data.

## Documentation

The detailed operating guides are currently authored in Russian; the links below are explicit so an English-speaking integrator can translate only the relevant guide while the API names and examples remain language-neutral.

| Goal | Guide |
| --- | --- |
| Install on iPhone, grant Health access, choose iCloud, and make the first export | [Installation and first export (Russian)](docs/INSTALLATION_RU.md) |
| Configure a private receiver on any Tailscale node | [Tailscale and private API (Russian)](docs/TAILSCALE_RU.md) |
| Implement a receiver or iCloud reader in another application | [Integration contract (Russian)](docs/INTEGRATION.md) |
| Connect an AI agent safely to snapshots and deltas | [Agent instructions (Russian)](docs/AGENT_INSTRUCTIONS.md) |
| Understand queues, background refresh, and architecture | [Implementation notes](docs/IMPLEMENTATION.md) |
| Use the iPhone app step by step | [User guide (Russian)](docs/USER_GUIDE_RU.md) |

## Quick start

1. Open [`HealthJSON.xcodeproj`](HealthJSON.xcodeproj) in Xcode and install it on a **physical iPhone**. The Simulator cannot validate the required HealthKit workflow.
2. In the app, grant the intended Apple Health read permissions and select a private iCloud Drive folder.
3. Tap **Update data**. The app creates `Health JSON/Agent/health-context.json` and `health-context.csv`.
4. Use CSV for a spreadsheet. Use JSON and its `generatedAt` revision for an app, a database, or an agent.
5. If immediate private delivery is required, configure your own `.ts.net` receiver in **Tailscale and API**. The receiver address is never compiled into the app and can be changed at any time.

## Export, freshness, and reliability

- **Full snapshot.** The manual update button, the viewer's refresh button, and Share all build a new 365-day snapshot. CSV is written first and JSON second; if the CSV write fails, the authoritative JSON revision is not advanced.
- **Automatic updates.** `HKObserverQuery` marks HealthKit changes. Nearby events are coalesced for up to five minutes. This is not a fixed timer: iOS decides when an app gets background time.
- **Daily reconciliation.** A complete snapshot picks up corrections that arrive later from HealthKit sources.
- **No export pile-up.** At most eight heavy HealthKit queries run concurrently, an individual query is stopped after 30 seconds, and manual exports serialize instead of competing for device resources.
- **Private delivery queue.** If the receiver is unavailable, JSON/CSV remain available through iCloud Drive. The pending API payload is protected on the iPhone and retried with backoff. Queued items are tied to the configured endpoint, so switching receivers never sends old health data to the new one.

## Data in the snapshot

When HealthKit permission and source data are available, Health JSON produces daily aggregates for cumulative values such as steps, distance, and energy. For discrete measurements such as heart rate, HRV, oxygen saturation, respiratory rate, temperature, blood pressure, glucose, and body measurements, it includes daily average, minimum, maximum, and latest values. Sleep, Activity Rings, workouts, symptoms, ECG summaries, state-of-mind entries, and special records are included where HealthKit makes them available.

To keep the agent snapshot compact, it omits source app names, device details, UUIDs, and arbitrary metadata. The more detailed technical HealthKit archive is stored under `Health JSON/Exports` and is not intended for routine model context.

## JSON, CSV, and API

### JSON — the software contract

`health-context.json` uses `schemaVersion: 1` and `kind: "health-agent-context"`. `rowFormats` declares the order of compact values once, so a receiver must read that declaration rather than guess columns. `generatedAt` is the complete snapshot revision; if it is unchanged, an integration should skip processing.

```json
{
  "schemaVersion": 1,
  "kind": "health-agent-context",
  "rowFormats": {
    "cumulativeMetric": ["date", "sum"],
    "discreteMetric": ["date", "average", "minimum", "maximum", "latest"]
  }
}
```

### CSV — the spreadsheet export

`health-context.csv` is UTF-8, CRLF, and RFC 4180-escaped. It has common columns for the period, record type, metric key, unit, and values. Complex rows such as workouts, Activity Rings, and special records keep their detailed representation in `details_json`.

CSV is for people and tabular tools; it is not the transport API. Use JSON for a receiver because it retains the typed and nested structure needed for safe idempotent processing.

### Private Tailscale API

The iPhone calls:

```http
GET  /health-json/health
POST /health-json/v1/import
```

The app accepts only an `https://…ts.net` receiver and normalizes it to the import endpoint. This is a private HTTPS route inside a tailnet, not a public webhook and not the Tailscale Admin API. Do not expose health data with Tailscale Funnel.

The receiver validates the JSON, processes full snapshots atomically, replaces data only inside a delta's declared window, and deduplicates by payload revision/digest. `X-HealthJSON-Request-ID` is useful for request tracing but is not a stable payload identity. See the [integration contract](docs/INTEGRATION.md) for exact status codes and iCloud reader rules.

## Privacy and limits

- HealthKit does not tell an app which **read** permissions were denied. A missing value does not prove the user has no such health data.
- iCloud files are ordinary JSON and CSV in the folder chosen by the owner. Protect the Apple ID, devices, and folder access.
- Tailscale delivery is restricted to the tailnet, but the owner must still restrict tailnet ACLs and validate every payload on the receiver.
- Clinical FHIR records are intentionally not requested. Workout routes, ECG records, and heartbeat series may be especially sensitive.
- Health JSON is not a medical device. Potentially concerning symptoms or values require assessment from an appropriate clinician or emergency service.

## Build

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project HealthJSON.xcodeproj -target HealthJSON \
  -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

The dependency-free companion CLI can validate a snapshot and prepare rolling context on a Mac:

```sh
python3 mac/healthjson.py validate-agent \
  "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Health JSON/Agent/health-context.json"

python3 mac/healthjson.py agent-delta \
  "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Health JSON/Agent/health-context.json" \
  --state "$HOME/.healthjson-agent/state.json" --days 365
```
