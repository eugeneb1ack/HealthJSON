# Implementation notes

## Apple platform constraints

- HealthKit access is per data type and read-only authorization is intentionally opaque.
- Observer queries must be installed on launch and their completion handler must be called after processing.
- Background delivery is a maximum frequency, not a schedule. Some data types are throttled by the system.
- Anchors are committed only after the corresponding JSON file is durable, providing at-least-once delivery if the app is terminated during export.
- Schema v2 explicitly distinguishes anchored `changes` from replace-all `snapshot` datasets. The Mac materializer applies additions and deletions idempotently by HealthKit UUID.
- The user selects an iCloud Drive or local Files folder through `UIDocumentPickerViewController`. A security-scoped bookmark preserves access across launches without the paid iCloud app-container entitlement. If folder access is unavailable, exports fall back to local app Documents and the UI reports that state.

## Coverage

The catalog is generated from public HealthKit types in the iOS 26 SDK:

- 120 quantity types
- 70 category types
- 2 correlation types
- workouts and workout routes
- audiograms, ECGs, heartbeat series, state of mind, medication dose events
- user-annotated medications and their clinical coding snapshot
- activity ring summaries, CDA documents, and vision prescriptions
- six characteristic values (date of birth, biological sex, blood type, skin type, wheelchair use, activity move mode)

Generic samples, quantities, categories, correlations, workouts, audiograms, scored assessments, medication dose events, and state-of-mind values have subtype-aware JSON encoding. ECG voltage measurements, workout route locations, and heartbeat series are fetched through Apple's async sequence query descriptors. Specialized series are paged one parent sample per JSON file to bound peak memory usage. Clinical FHIR records are excluded from the default product because they require separate hospital/provider accounts and are not part of the user's Apple Watch/iPhone history.
