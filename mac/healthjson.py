#!/usr/bin/env python3
"""Validate and materialize Health JSON change-set files on macOS."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable, Iterator
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


SUPPORTED_SCHEMA_VERSIONS = {1, 2}
MAX_SLEEP_INTERVALS = 10_000
MAX_SLEEP_INTERVAL_DURATION = timedelta(hours=36)
SLEEP_INTERVAL_VALUES = frozenset({
    "inBed", "asleepUnspecified", "awake", "asleepCore", "asleepDeep", "asleepREM",
})


class ExportValidationError(ValueError):
    pass


@dataclass(frozen=True)
class ExportFile:
    path: Path
    exported_at: str
    type_identifier: str
    mode: str
    added: list[dict[str, Any]]
    deleted: list[dict[str, Any]]


def discover_json_files(root: Path) -> list[Path]:
    if root.is_file():
        return [root] if root.suffix.lower() == ".json" else []
    return sorted(path for path in root.rglob("*.json") if path.is_file())


def load_export(path: Path) -> ExportFile:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ExportValidationError(f"{path}: invalid JSON: {error}") from error

    if not isinstance(raw, dict):
        raise ExportValidationError(f"{path}: top-level value must be an object")

    version = raw.get("schemaVersion")
    if version not in SUPPORTED_SCHEMA_VERSIONS:
        raise ExportValidationError(f"{path}: unsupported schemaVersion {version!r}")

    required = ("exportedAt", "typeIdentifier", "added", "deleted")
    missing = [key for key in required if key not in raw]
    if missing:
        raise ExportValidationError(f"{path}: missing fields: {', '.join(missing)}")

    exported_at = raw["exportedAt"]
    type_identifier = raw["typeIdentifier"]
    added = raw["added"]
    deleted = raw["deleted"]
    if not isinstance(exported_at, str) or not exported_at:
        raise ExportValidationError(f"{path}: exportedAt must be a non-empty string")
    try:
        datetime.fromisoformat(exported_at.replace("Z", "+00:00"))
    except ValueError as error:
        raise ExportValidationError(f"{path}: exportedAt is not an ISO-8601 timestamp") from error
    if not isinstance(type_identifier, str) or not type_identifier:
        raise ExportValidationError(f"{path}: typeIdentifier must be a non-empty string")
    if not isinstance(added, list) or not all(isinstance(item, dict) for item in added):
        raise ExportValidationError(f"{path}: added must be an array of objects")
    if not isinstance(deleted, list) or not all(isinstance(item, dict) for item in deleted):
        raise ExportValidationError(f"{path}: deleted must be an array of objects")

    # Version 1 only emitted anchored changes. Version 2 declares semantics explicitly.
    mode = raw.get("mode", "changes")
    if mode not in {"changes", "snapshot"}:
        raise ExportValidationError(f"{path}: mode must be 'changes' or 'snapshot'")
    if version >= 2 and "mode" not in raw:
        raise ExportValidationError(f"{path}: schemaVersion 2 requires mode")

    for item in deleted:
        if not isinstance(item.get("uuid"), str) or not item["uuid"]:
            raise ExportValidationError(f"{path}: every deleted item must contain a UUID")
    if mode == "changes":
        for item in added:
            if not isinstance(item.get("uuid"), str) or not item["uuid"]:
                raise ExportValidationError(f"{path}: every added change must contain a UUID")

    return ExportFile(path, exported_at, type_identifier, mode, added, deleted)


def iter_exports(root: Path) -> Iterator[ExportFile]:
    files = discover_json_files(root)
    if not files:
        raise ExportValidationError(f"{root}: no JSON export files found")
    modes: dict[str, str] = {}
    for path in files:
        export = load_export(path)
        previous = modes.setdefault(export.type_identifier, export.mode)
        if previous != export.mode:
            raise ExportValidationError(
                f"{root}: {export.type_identifier} mixes '{previous}' and '{export.mode}' modes"
            )
        yield export


def load_all(root: Path) -> list[ExportFile]:
    """Load exports for materialization, which requires chronological ordering."""
    return sorted(iter_exports(root), key=lambda item: (item.exported_at, str(item.path)))


def validate_directory(root: Path) -> tuple[int, int]:
    """Validate one file at a time so large Health histories do not exhaust RAM."""
    file_count = 0
    type_identifiers: set[str] = set()
    for export in iter_exports(root):
        file_count += 1
        type_identifiers.add(export.type_identifier)
    return file_count, len(type_identifiers)


def load_agent_context(path: Path) -> dict[str, Any]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ExportValidationError(f"{path}: invalid agent JSON: {error}") from error
    if not isinstance(raw, dict):
        raise ExportValidationError(f"{path}: agent context must be an object")
    if raw.get("schemaVersion") != 1 or raw.get("kind") != "health-agent-context":
        raise ExportValidationError(f"{path}: unsupported agent context schema")
    for key, expected_type in (
        ("generatedAt", str),
        ("period", dict),
        ("rowFormats", dict),
        ("profile", dict),
        ("metrics", dict),
        ("categories", dict),
        ("activityRings", list),
        ("workouts", list),
        ("special", dict),
    ):
        if not isinstance(raw.get(key), expected_type):
            raise ExportValidationError(f"{path}: {key} has an invalid type")
    if "sleepIntervals" in raw:
        intervals = raw["sleepIntervals"]
        if not isinstance(intervals, list) or len(intervals) > MAX_SLEEP_INTERVALS:
            raise ExportValidationError(f"{path}: sleepIntervals has an invalid type or count")
        if raw["rowFormats"].get("sleepInterval") != ["start", "end", "value"]:
            raise ExportValidationError(f"{path}: rowFormats.sleepInterval is invalid")
        for row in intervals:
            if not isinstance(row, list) or len(row) != 3:
                raise ExportValidationError(f"{path}: sleepIntervals rows must contain exactly 3 values")
            start = _aware_timestamp(row[0], f"{path}: sleep interval start")
            end = _aware_timestamp(row[1], f"{path}: sleep interval end")
            if end <= start or end - start > MAX_SLEEP_INTERVAL_DURATION:
                raise ExportValidationError(f"{path}: sleep interval has an invalid duration")
            if row[2] not in SLEEP_INTERVAL_VALUES:
                raise ExportValidationError(f"{path}: sleep interval has an unknown value")
    return raw


def _aware_timestamp(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or len(value) > 64:
        raise ExportValidationError(f"{label} must be a timezone-aware ISO-8601 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ExportValidationError(f"{label} must be a timezone-aware ISO-8601 timestamp") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ExportValidationError(f"{label} must be a timezone-aware ISO-8601 timestamp")
    return parsed


def compact_agent_context(context: dict[str, Any], days: int) -> dict[str, Any]:
    if days < 1:
        raise ExportValidationError("days must be greater than zero")
    try:
        end = datetime.fromisoformat(context["period"]["end"]).date()
    except (KeyError, TypeError, ValueError) as error:
        raise ExportValidationError("agent context has an invalid period.end") from error
    cutoff = (end - timedelta(days=days - 1)).isoformat()

    sleep_intervals: list[Any] = []
    if context.get("sleepIntervals"):
        try:
            period_zone = ZoneInfo(context["period"]["timeZone"])
        except (KeyError, TypeError, ZoneInfoNotFoundError) as error:
            raise ExportValidationError("agent context has an invalid period.timeZone") from error
        window_start = datetime.combine(datetime.fromisoformat(cutoff).date(), datetime.min.time(), period_zone)
        window_end = datetime.combine(end + timedelta(days=1), datetime.min.time(), period_zone)
        sleep_intervals = [
            row for row in context["sleepIntervals"]
            if _aware_timestamp(row[1], "sleep interval end") > window_start
            and _aware_timestamp(row[0], "sleep interval start") < window_end
        ]

    metrics: dict[str, Any] = {}
    for name, metric in context["metrics"].items():
        rows = [row for row in metric.get("daily", []) if row and row[0] >= cutoff]
        if rows:
            metrics[name] = {
                "unit": metric.get("unit"),
                "aggregation": metric.get("aggregation"),
                "daily": rows,
            }

    categories: dict[str, Any] = {}
    for name, category in context["categories"].items():
        rows = [row for row in category.get("daily", []) if row and row[0] >= cutoff]
        if rows:
            categories[name] = {"daily": rows}

    activity = [row for row in context["activityRings"] if row.get("date", "") >= cutoff]
    workouts = [row for row in context["workouts"] if row.get("start", "")[:10] >= cutoff]
    special = {
        name: [row for row in rows if row.get("start", "")[:10] >= cutoff]
        for name, rows in context["special"].items()
    }
    special = {name: rows for name, rows in special.items() if rows}

    return {
        "kind": "health-agent-context-window",
        "sourceGeneratedAt": context["generatedAt"],
        "window": {"start": cutoff, "end": end.isoformat(), "days": days},
        "rowFormats": context["rowFormats"],
        "profile": context["profile"],
        "metrics": metrics,
        "categories": categories,
        "activityRings": activity,
        "workouts": workouts,
        "special": special,
        "sleepIntervals": sleep_intervals,
    }


def _canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def _list_delta(previous: list[Any], current: list[Any]) -> dict[str, list[Any]]:
    previous_keys = {_canonical(item) for item in previous}
    current_keys = {_canonical(item) for item in current}
    return {
        "added": [item for item in current if _canonical(item) not in previous_keys],
        "removed": [item for item in previous if _canonical(item) not in current_keys],
    }


def build_agent_delta(previous: dict[str, Any], current: dict[str, Any]) -> dict[str, Any]:
    metrics: dict[str, Any] = {}
    for name in sorted(set(previous["metrics"]) | set(current["metrics"])):
        old_metric = previous["metrics"].get(name, {})
        new_metric = current["metrics"].get(name, {})
        rows = _list_delta(old_metric.get("daily", []), new_metric.get("daily", []))
        if rows["added"] or rows["removed"]:
            metrics[name] = {
                "unit": new_metric.get("unit", old_metric.get("unit")),
                "aggregation": new_metric.get("aggregation", old_metric.get("aggregation")),
                **rows,
            }

    categories: dict[str, Any] = {}
    for name in sorted(set(previous["categories"]) | set(current["categories"])):
        rows = _list_delta(
            previous["categories"].get(name, {}).get("daily", []),
            current["categories"].get(name, {}).get("daily", []),
        )
        if rows["added"] or rows["removed"]:
            categories[name] = rows

    activity = _list_delta(previous["activityRings"], current["activityRings"])
    workouts = _list_delta(previous["workouts"], current["workouts"])
    sleep_intervals = _list_delta(previous.get("sleepIntervals", []), current.get("sleepIntervals", []))
    special: dict[str, Any] = {}
    for name in sorted(set(previous["special"]) | set(current["special"])):
        rows = _list_delta(previous["special"].get(name, []), current["special"].get(name, []))
        if rows["added"] or rows["removed"]:
            special[name] = rows

    profile = None
    if previous["profile"] != current["profile"]:
        profile = {"before": previous["profile"], "after": current["profile"]}

    has_changes = bool(
        metrics or categories or special or profile
        or activity["added"] or activity["removed"]
        or workouts["added"] or workouts["removed"]
        or sleep_intervals["added"] or sleep_intervals["removed"]
    )
    return {
        "kind": "health-agent-delta",
        "status": "changed",
        "hasDataChanges": has_changes,
        "previousGeneratedAt": previous["sourceGeneratedAt"],
        "sourceGeneratedAt": current["sourceGeneratedAt"],
        "window": current["window"],
        "rowFormats": current["rowFormats"],
        "profileChange": profile,
        "metrics": metrics,
        "categories": categories,
        "activityRings": activity,
        "workouts": workouts,
        "special": special,
        "sleepIntervals": sleep_intervals,
    }


def write_json_atomic(destination: Path, payload: dict[str, Any]) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(destination)


def agent_delta(context_path: Path, state_path: Path, days: int) -> dict[str, Any]:
    current = compact_agent_context(load_agent_context(context_path), days)
    if not state_path.exists():
        result = {
            "kind": "health-agent-delta",
            "status": "initial",
            "hasDataChanges": True,
            "sourceGeneratedAt": current["sourceGeneratedAt"],
            "context": current,
        }
        write_json_atomic(state_path, current)
        return result

    try:
        previous = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ExportValidationError(f"{state_path}: invalid agent state: {error}") from error
    if not isinstance(previous, dict) or previous.get("kind") != "health-agent-context-window":
        raise ExportValidationError(f"{state_path}: unsupported agent state")
    if previous.get("sourceGeneratedAt") == current["sourceGeneratedAt"]:
        return {
            "kind": "health-agent-delta",
            "status": "unchanged",
            "hasDataChanges": False,
            "sourceGeneratedAt": current["sourceGeneratedAt"],
        }

    result = build_agent_delta(previous, current)
    write_json_atomic(state_path, current)
    return result


def materialize(exports: Iterable[ExportFile]) -> dict[str, list[dict[str, Any]]]:
    changes: dict[str, dict[str, dict[str, Any]]] = {}
    snapshots: dict[str, list[dict[str, Any]]] = {}

    for export in exports:
        if export.mode == "snapshot":
            snapshots[export.type_identifier] = export.added
            continue

        current = changes.setdefault(export.type_identifier, {})
        for item in export.added:
            current[item["uuid"].lower()] = item
        for item in export.deleted:
            current.pop(item["uuid"].lower(), None)

    result = {type_id: list(items.values()) for type_id, items in changes.items()}
    result.update(snapshots)
    return {key: result[key] for key in sorted(result)}


def summary(exports: Iterable[ExportFile]) -> dict[str, dict[str, int]]:
    report: dict[str, dict[str, int]] = {}
    for export in exports:
        item = report.setdefault(export.type_identifier, {"files": 0, "added": 0, "deleted": 0})
        item["files"] += 1
        item["added"] += len(export.added)
        item["deleted"] += len(export.deleted)
    return report


def write_materialized(destination: Path, state: dict[str, list[dict[str, Any]]]) -> None:
    payload = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "types": state,
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(destination)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("validate", "summary"):
        command = subparsers.add_parser(name)
        command.add_argument("exports", type=Path)
    materialize_command = subparsers.add_parser("materialize")
    materialize_command.add_argument("exports", type=Path)
    materialize_command.add_argument("output", type=Path)
    agent_command = subparsers.add_parser("validate-agent")
    agent_command.add_argument("file", type=Path)
    context_command = subparsers.add_parser("context")
    context_command.add_argument("file", type=Path)
    context_command.add_argument("--days", type=int, default=30)
    context_command.add_argument("--pretty", action="store_true")
    delta_command = subparsers.add_parser("agent-delta")
    delta_command.add_argument("file", type=Path)
    delta_command.add_argument("--state", type=Path, required=True)
    delta_command.add_argument("--days", type=int, default=365)
    delta_command.add_argument("--pretty", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "validate-agent":
            context = load_agent_context(args.file.expanduser())
            print(
                f"OK: {len(context['metrics'])} metrics, "
                f"{len(context['categories'])} categories, "
                f"{len(context['activityRings'])} activity days, "
                f"{len(context['workouts'])} workouts"
            )
            return 0
        if args.command == "context":
            context = compact_agent_context(load_agent_context(args.file.expanduser()), args.days)
            if args.pretty:
                print(json.dumps(context, ensure_ascii=False, indent=2, sort_keys=True))
            else:
                print(json.dumps(context, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
            return 0
        if args.command == "agent-delta":
            delta = agent_delta(args.file.expanduser(), args.state.expanduser(), args.days)
            if args.pretty:
                print(json.dumps(delta, ensure_ascii=False, indent=2, sort_keys=True))
            else:
                print(json.dumps(delta, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
            return 0
        root = args.exports.expanduser()
        if args.command == "validate":
            file_count, type_count = validate_directory(root)
            print(f"OK: {file_count} files, {type_count} types")
        elif args.command == "summary":
            for type_identifier, values in summary(iter_exports(root)).items():
                print(
                    f"{type_identifier}\tfiles={values['files']}\t"
                    f"added={values['added']}\tdeleted={values['deleted']}"
                )
        else:
            destination = args.output.expanduser()
            write_materialized(destination, materialize(load_all(root)))
            print(f"Wrote {destination}")
    except ExportValidationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
