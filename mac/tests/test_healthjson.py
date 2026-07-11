import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "healthjson.py"
SPEC = importlib.util.spec_from_file_location("healthjson", MODULE_PATH)
healthjson = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = healthjson
SPEC.loader.exec_module(healthjson)


class HealthJSONTests(unittest.TestCase):
    def write_export(self, root: Path, name: str, payload: dict) -> Path:
        path = root / name
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def changes(self, exported_at: str, added=None, deleted=None) -> dict:
        return {
            "schemaVersion": 2,
            "mode": "changes",
            "exportedAt": exported_at,
            "typeIdentifier": "HKCategoryTypeIdentifierSleepAnalysis",
            "added": added or [],
            "deleted": deleted or [],
        }

    def test_materialize_applies_add_update_and_delete_in_time_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_export(root, "later.json", self.changes(
                "2026-07-11T10:01:00.000Z",
                added=[{"uuid": "B", "value": 3}, {"uuid": "A", "value": 2}],
            ))
            self.write_export(root, "first.json", self.changes(
                "2026-07-11T10:00:00.000Z",
                added=[{"uuid": "A", "value": 1}],
            ))
            self.write_export(root, "delete.json", self.changes(
                "2026-07-11T10:02:00.000Z",
                deleted=[{"uuid": "A"}],
            ))

            state = healthjson.materialize(healthjson.load_all(root))

            self.assertEqual(
                state["HKCategoryTypeIdentifierSleepAnalysis"],
                [{"uuid": "B", "value": 3}],
            )

    def test_latest_snapshot_replaces_previous_snapshot(self):
        exports = [
            healthjson.ExportFile(Path("a"), "1", "HealthKitCharacteristics", "snapshot", [{"bloodType": 1}], []),
            healthjson.ExportFile(Path("b"), "2", "HealthKitCharacteristics", "snapshot", [{"bloodType": 2}], []),
        ]
        self.assertEqual(
            healthjson.materialize(exports)["HealthKitCharacteristics"],
            [{"bloodType": 2}],
        )

    def test_validation_rejects_change_without_uuid(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_export(
                Path(directory),
                "bad.json",
                self.changes("2026-07-11T10:00:00.000Z", added=[{"value": 1}]),
            )
            with self.assertRaises(healthjson.ExportValidationError):
                healthjson.load_export(path)

    def test_schema_one_is_read_as_changes_for_backward_compatibility(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = self.changes("2026-07-11T10:00:00.000Z", added=[{"uuid": "A"}])
            payload["schemaVersion"] = 1
            payload.pop("mode")
            path = self.write_export(Path(directory), "old.json", payload)
            self.assertEqual(healthjson.load_export(path).mode, "changes")

    def test_validation_rejects_invalid_timestamp(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_export(
                Path(directory),
                "bad-date.json",
                self.changes("not-a-date", added=[{"uuid": "A"}]),
            )
            with self.assertRaises(healthjson.ExportValidationError):
                healthjson.load_export(path)

    def test_validation_rejects_mixed_modes_for_one_type(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_export(root, "changes.json", self.changes(
                "2026-07-11T10:00:00.000Z", added=[{"uuid": "A"}]
            ))
            snapshot = self.changes("2026-07-11T10:01:00.000Z")
            snapshot["mode"] = "snapshot"
            self.write_export(root, "snapshot.json", snapshot)
            with self.assertRaises(healthjson.ExportValidationError):
                healthjson.load_all(root)

    def test_streaming_directory_validation_counts_files_and_types(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_export(root, "one.json", self.changes(
                "2026-07-11T10:00:00.000Z", added=[{"uuid": "A"}]
            ))
            second = self.changes("2026-07-11T10:01:00.000Z", added=[{"uuid": "B"}])
            second["typeIdentifier"] = "HKQuantityTypeIdentifierStepCount"
            self.write_export(root, "two.json", second)

            self.assertEqual(healthjson.validate_directory(root), (2, 2))

    def test_agent_context_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_export(Path(directory), "health-context.json", {
                "schemaVersion": 1,
                "kind": "health-agent-context",
                "generatedAt": "2026-07-11T10:00:00Z",
                "period": {},
                "rowFormats": {},
                "profile": {},
                "metrics": {"oxygenSaturation": {}},
                "categories": {"sleepAnalysis": {}},
                "activityRings": [],
                "workouts": [],
                "special": {},
            })
            context = healthjson.load_agent_context(path)
            self.assertIn("oxygenSaturation", context["metrics"])

    def test_compact_agent_context_filters_old_days(self):
        context = {
            "generatedAt": "2026-07-11T10:00:00Z",
            "period": {"end": "2026-07-11"},
            "rowFormats": {},
            "profile": {},
            "metrics": {"heartRate": {
                "unit": "count/min",
                "aggregation": "dailyAverageMinMaxLatest",
                "daily": [["2026-06-01", 60], ["2026-07-10", 62]],
            }},
            "categories": {},
            "activityRings": [],
            "workouts": [],
            "special": {},
        }
        compact = healthjson.compact_agent_context(context, 7)
        self.assertEqual(compact["metrics"]["heartRate"]["daily"], [["2026-07-10", 62]])

    def test_agent_delta_initial_unchanged_and_changed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "health-context.json"
            state = root / "state.json"

            def write_context(generated_at, rows):
                self.write_export(root, source.name, {
                    "schemaVersion": 1,
                    "kind": "health-agent-context",
                    "generatedAt": generated_at,
                    "period": {"end": "2026-07-11"},
                    "rowFormats": {"cumulativeMetric": ["date", "sum"]},
                    "profile": {},
                    "metrics": {"stepCount": {
                        "unit": "count",
                        "aggregation": "dailySum",
                        "daily": rows,
                    }},
                    "categories": {},
                    "activityRings": [],
                    "workouts": [],
                    "special": {},
                })

            write_context("2026-07-11T10:00:00Z", [["2026-07-10", 8000]])
            initial = healthjson.agent_delta(source, state, 365)
            self.assertEqual(initial["status"], "initial")
            self.assertTrue(state.exists())

            unchanged = healthjson.agent_delta(source, state, 365)
            self.assertEqual(unchanged["status"], "unchanged")
            self.assertFalse(unchanged["hasDataChanges"])

            write_context("2026-07-11T11:00:00Z", [["2026-07-10", 8100], ["2026-07-11", 1200]])
            changed = healthjson.agent_delta(source, state, 365)
            self.assertEqual(changed["status"], "changed")
            self.assertTrue(changed["hasDataChanges"])
            self.assertEqual(
                changed["metrics"]["stepCount"]["added"],
                [["2026-07-10", 8100], ["2026-07-11", 1200]],
            )
            self.assertEqual(
                changed["metrics"]["stepCount"]["removed"],
                [["2026-07-10", 8000]],
            )


if __name__ == "__main__":
    unittest.main()
