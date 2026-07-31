# Health JSON

Health JSON is a private iPhone exporter for Apple Health data. Its primary output is one compact file for an AI health coach: **iCloud Drive → Health JSON → Agent → health-context.json**. It includes only populated, approved health metrics and replaces itself atomically after every sync.

The AI file covers the most recent 365 days. Cumulative metrics such as steps, distance, and energy are summed by day. Discrete measurements such as heart rate, oxygen saturation, HRV, respiratory rate, temperature, blood pressure, glucose, and body measurements include daily average, minimum, maximum, and latest values. Sleep is split into stages and duration, with activity rings, workouts, symptoms, ECG summaries, mental-state entries, and assessments where available. UUIDs, device details, source applications, and arbitrary metadata are omitted to save model context.

The canonical `health-context.json` is a complete snapshot. Automatic synchronization coalesces HealthKit events for up to five minutes and writes small immutable three-day window updates under `Agent/Inbox`, avoiding concurrent replacement and iCloud conflict copies. A daily full snapshot reconciles older corrections. Synchronization can be paused or resumed in the app; manual **Update single JSON** always writes a complete snapshot immediately.

## Architecture

1. The app requests read-only HealthKit access.
2. HealthKit statistics merge duplicate sources and generate compact daily health aggregates.
3. `HKObserverQuery` marks supported HealthKit changes as pending. Immediate background delivery writes a coalesced recent-window update when iOS grants execution time; `BGAppRefreshTask` retries pending work and performs periodic reconciliation.
4. The complete agent context is written atomically to one stable file, so readers never see a partial JSON document.
5. An optional technical raw archive remains available under **Health JSON → Exports** for detailed debugging, but an AI agent should read only the file under **Agent**.

There is intentionally no fixed timer. Five minutes is a coalescing interval, not a guaranteed deadline: iOS decides when background work runs and may throttle HealthKit delivery. Pending state survives an app restart, immutable update files are retained for seven days, and manual sync is always available.

## Run on an iPhone

1. Open `HealthJSON.xcodeproj` in Xcode 26 or newer.
2. Select the **HealthJSON** target, then select your Apple Developer team.
3. Change `PRODUCT_BUNDLE_IDENTIFIER` if Xcode reports that `com.johndoe.HealthJSON` is unavailable.
4. In **Signing & Capabilities**, confirm **HealthKit** and **Background Delivery**. No iCloud capability is required, so a free Personal Team can sign the app.
5. Build to a physical iPhone. HealthKit background delivery cannot be tested in Simulator.
6. Tap **Choose iCloud Drive folder**, select or create a private folder, grant Health access, then tap **Update single JSON for AI**.

The first export can take a long time for a large history. Keep the app open until it completes. Later exports are incremental.

## Agent JSON format

The file uses compact row arrays. Their column meanings are declared once in `rowFormats`, avoiding repeated field names and saving tokens:

```json
{
  "schemaVersion": 1,
  "kind": "health-agent-context",
  "rowFormats": {
    "cumulativeMetric": ["date", "sum"],
    "discreteMetric": ["date", "average", "minimum", "maximum", "latest"]
  },
  "metrics": {
    "oxygenSaturation": {
      "unit": "%",
      "aggregation": "dailyAverageMinMaxLatest",
      "daily": [["2026-07-11", 0.98, 0.95, 1.0, 0.99]]
    }
  }
}
```

Validate the file on the Mac with:

```sh
python3 mac/healthjson.py validate-agent \
  "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Health JSON/Agent/health-context.json"
```

Do not inject the full year into every model call. Generate a compact rolling window instead:

```sh
python3 mac/healthjson.py context \
  "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Health JSON/Agent/health-context.json" \
  --days 30
```

The real 7-day file in this project was reduced from about 432 KB to about 9 KB. See [the agent workflow](docs/AGENT_INSTRUCTIONS.md) for first ingestion, subsequent updates, and a ready system prompt.

For a persistent hourly agent, use the stateful delta command instead. The first call returns the baseline once; later calls return only changed rows, or a tiny `unchanged` response:

```sh
python3 mac/healthjson.py agent-delta \
  "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Health JSON/Agent/health-context.json" \
  --state "$HOME/.healthjson-agent/state.json" \
  --days 365
```

## Raw archive format

Every file is a self-contained change set:

```json
{
  "schemaVersion": 2,
  "mode": "changes",
  "exportedAt": "2026-07-11T12:00:00.000Z",
  "typeIdentifier": "HKCategoryTypeIdentifierSleepAnalysis",
  "added": [],
  "deleted": [{ "uuid": "..." }]
}
```

`mode: "changes"` contains additions/deletions since the previous HealthKit anchor. `mode: "snapshot"` replaces the previous value of non-anchored datasets such as characteristics, medications, and activity summaries.

## Use on the Mac

The files are directly readable in Finder. A dependency-free companion CLI validates them and materializes their current state:

```sh
EXPORTS="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Health JSON/Exports"
python3 mac/healthjson.py validate "$EXPORTS"
python3 mac/healthjson.py summary "$EXPORTS"
python3 mac/healthjson.py materialize "$EXPORTS" current-health.json
```

You can also drag the `Exports` folder into Terminal after typing the command to avoid locating the iCloud container path manually.

Quantity samples contain a numeric `value` and `unit` using HealthKit's preferred unit for the device. Source, device, metadata, dates, and subtype-specific fields are included where HealthKit exposes them.

## Privacy and limitations

- HealthKit never tells an app which read permissions were denied. Missing data does not prove that no data exists.
- A user can grant only a recent window of history.
- The export is unencrypted JSON inside the folder selected by the user. Protect the Apple ID and Mac account accordingly.
- ECG voltage points, workout route coordinates, and heartbeat beat-by-beat series are exported using their dedicated streaming HealthKit queries. A series-level error is recorded on the parent sample without losing the rest of the export.
- Clinical Health Records are deliberately not requested. They are FHIR records from hospital or laboratory patient portals and trigger a separate provider-account flow; they are not required for personal iPhone and Apple Watch health data.

## Build from the command line

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project HealthJSON.xcodeproj -target HealthJSON \
  -sdk iphonesimulator \
  CODE_SIGNING_ALLOWED=NO build
```
