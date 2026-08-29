# Implementation notes

## Apple platform constraints

- HealthKit access is per data type and read-only authorization is intentionally opaque.
- Observer queries must be installed on launch and their completion handler must be called after processing.
- Background delivery is a maximum frequency, not a schedule. Some data types are throttled by the system.
- Anchors are committed only after the corresponding JSON file is durable, providing at-least-once delivery if the app is terminated during export.
- Schema v2 explicitly distinguishes anchored `changes` from replace-all `snapshot` datasets. The Mac materializer applies additions and deletions idempotently by HealthKit UUID.
- The user selects an iCloud Drive or local Files folder through `UIDocumentPickerViewController`. A security-scoped bookmark preserves access across launches without the paid iCloud app-container entitlement. If folder access is unavailable, exports fall back to local app Documents and the UI reports that state.
- A full agent snapshot writes both `Agent/health-context.csv` and the canonical `Agent/health-context.json` through `NSFileCoordinator` and atomic replacement. CSV is written first: if it fails, the previous JSON revision remains authoritative rather than advancing only one public format.
- Agent aggregation caps concurrent HealthKit queries at eight. Each statistics or sample query has a 30-second timeout and is stopped on timeout; an unavailable type is skipped rather than making the whole snapshot wait indefinitely. HealthKit observer delivery remains event-driven and coalesced, so no periodic high-frequency polling is introduced.

## Coverage

The catalog is generated from public HealthKit types in the iOS 26 SDK and covers quantity and category data, workouts and routes, audiograms, ECGs, heartbeat series, state of mind, scored assessments, activity rings, and six characteristic values (date of birth, biological sex, blood type, skin type, wheelchair use, and activity move mode).

Correlation types, user-annotated medications, medication dose events, and vision prescriptions are intentionally omitted from the automatic export path while their individual HealthKit query behaviour is isolated on the target OS. This is a reliability boundary: one specialised type must not hold the complete health snapshot open. The generic encoder keeps the corresponding model support for a future isolated route.

Generic samples, quantities, categories, workouts, audiograms, scored assessments, and state-of-mind values have subtype-aware JSON encoding. ECG voltage measurements, workout route locations, and heartbeat series are fetched through Apple's async sequence query descriptors. Specialized series are paged one parent sample per JSON file to bound peak memory usage. Clinical FHIR records are excluded from the default product because they require separate hospital/provider accounts and are not part of the user's Apple Watch/iPhone history.
