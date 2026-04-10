#!/usr/bin/env python3

import csv
import json
import math
import os
import urllib.request
from collections import defaultdict
from pathlib import Path


INPUT_DIR = Path("outputs/route_plan")
OUTPUT_DIR = Path("outputs/route_plan_ors")
ROUTE_PLAN_FILE = INPUT_DIR / "station_route_plan.csv"
DAY_SUMMARY_FILE = INPUT_DIR / "day_route_summary.csv"


def load_env_local():
    path = Path(".env.local")
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


def read_station_rows():
    by_day = defaultdict(list)
    with ROUTE_PLAN_FILE.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            day = int(float(row["day"]))
            row = dict(row)
            row["_day"] = day
            row["_visit_order"] = int(float(row["visit_order"]))
            row["_lat"] = float(row["lat"])
            row["_lon"] = float(row["lon"])
            by_day[day].append(row)
    for day in by_day:
        by_day[day].sort(key=lambda r: r["_visit_order"])
    return by_day


def read_day_summaries():
    rows = {}
    with DAY_SUMMARY_FILE.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows[int(float(row["day"]))] = dict(row)
    return rows


def ors_request(url, key, body):
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Authorization": key, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        return json.load(resp)


def optimize_day(key, rows, start_name, end_name):
    by_name = {row["station_name"]: row for row in rows}
    start = by_name[start_name]
    end = by_name[end_name]
    jobs = []
    lookup = {}
    next_id = 1
    for row in rows:
        if row["station_name"] in (start_name, end_name):
            continue
        jobs.append({"id": next_id, "location": [row["_lon"], row["_lat"]]})
        lookup[next_id] = row
        next_id += 1

    payload = ors_request(
        "https://api.openrouteservice.org/optimization",
        key,
        {
            "jobs": jobs,
            "vehicles": [
                {
                    "id": 1,
                    "profile": "cycling-regular",
                    "start": [start["_lon"], start["_lat"]],
                    "end": [end["_lon"], end["_lat"]],
                }
            ],
            "options": {"g": True},
        },
    )

    ordered = [start]
    for step in payload["routes"][0]["steps"]:
        if step["type"] == "job":
            ordered.append(lookup[step["id"]])
    ordered.append(end)
    return ordered, payload


def directions_day(key, ordered):
    coords = [[row["_lon"], row["_lat"]] for row in ordered]
    return ors_request(
        "https://api.openrouteservice.org/v2/directions/cycling-regular/geojson",
        key,
        {"coordinates": coords, "instructions": True},
    )


def to_bool(value):
    return str(value).strip().upper() == "TRUE"


def fmt_num(value):
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    return str(value)


def maybe_float(value):
    try:
        return float(value)
    except Exception:
        return None


def write_station_plan(all_rows):
    fieldnames = [
        "day",
        "visit_order",
        "station_id",
        "station_name",
        "lat",
        "lon",
        "nearest_metro",
        "nearest_metro_distance_m",
        "nearest_metro_walk_min",
        "endPointScore",
        "visited",
        "source_row",
        "access_from_home_min",
        "access_to_home_min",
        "home_bike_min",
    ]
    out = OUTPUT_DIR / "station_route_plan.csv"
    with out.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in all_rows:
            writer.writerow({k: row.get(k, "") for k in fieldnames})


def write_day_summary(day_rows):
    if not day_rows:
        return
    fieldnames = list(day_rows[0].keys())
    out = OUTPUT_DIR / "day_route_summary.csv"
    with out.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(day_rows)


def write_total_summary(day_rows):
    totals = {
        "planned_stations": sum(int(row["stations"]) for row in day_rows),
        "planned_days": len(day_rows),
        "total_route_distance_km": sum(float(row["route_distance_km"]) for row in day_rows),
        "total_route_distance_mi": sum(float(row["route_distance_mi"]) for row in day_rows),
        "total_estimated_bike_minutes": sum(float(row["estimated_bike_minutes"]) for row in day_rows),
        "total_estimated_day_minutes": sum(float(row["estimated_total_day_minutes"]) for row in day_rows),
    }
    totals["average_stations_per_day"] = totals["planned_stations"] / max(1, totals["planned_days"])
    totals["smallest_day_stations"] = min(int(row["stations"]) for row in day_rows)
    totals["largest_day_stations"] = max(int(row["stations"]) for row in day_rows)
    sorted_by_score = sorted(day_rows, key=lambda row: float(row["route_score"]))
    totals["best_day_by_score"] = sorted_by_score[0]["day"]
    totals["worst_day_by_score"] = sorted_by_score[-1]["day"]
    totals["weak_transit_start_count"] = sum(0 if to_bool(row["start_metro_access_ok"]) else 1 for row in day_rows)
    totals["weak_transit_exit_count"] = sum(0 if to_bool(row["end_metro_access_ok"]) else 1 for row in day_rows)
    totals["double_back_exit_count"] = sum(1 for row in day_rows if row["end_exit_strategy"] == "double_back")

    out = OUTPUT_DIR / "total_route_summary.csv"
    with out.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(totals.keys()))
        writer.writeheader()
        writer.writerow({k: fmt_num(v) for k, v in totals.items()})


def write_manifest(manifest):
    (OUTPUT_DIR / "ors_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")


def main():
    load_env_local()
    key = os.environ.get("OPENROUTESERVICE_API_KEY")
    if not key:
        raise RuntimeError("OPENROUTESERVICE_API_KEY missing")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    station_rows = read_station_rows()
    day_summaries = read_day_summaries()
    all_station_rows = []
    all_day_rows = []
    manifest = []

    for day in sorted(day_summaries):
        summary = dict(day_summaries[day])
        rows = station_rows[day]
        ordered, opt_payload = optimize_day(
            key,
            rows,
            summary["start_station_name"],
            summary["end_station_name"],
        )
        directions = directions_day(key, ordered)
        feature = directions["features"][0]
        route_distance_m = float(feature["properties"]["summary"]["distance"])
        route_duration_s = float(feature["properties"]["summary"]["duration"])
        bike_minutes = route_duration_s / 60.0
        total_access = float(summary["total_access_overhead_min_est"])
        total_minutes = bike_minutes + total_access

        for idx, row in enumerate(ordered, start=1):
            out_row = dict(row)
            out_row["day"] = str(day)
            out_row["visit_order"] = str(idx)
            out_row["lat"] = row["lat"]
            out_row["lon"] = row["lon"]
            all_station_rows.append(out_row)

        summary["stations"] = str(len(ordered))
        summary["route_distance_km"] = f"{route_distance_m / 1000.0:.4f}"
        summary["route_distance_mi"] = f"{route_distance_m / 1609.344:.10f}"
        summary["estimated_bike_minutes"] = f"{bike_minutes:.12f}"
        summary["estimated_total_day_minutes"] = f"{total_minutes:.12f}"
        summary["route_score"] = f"{total_minutes:.12f}"
        summary["route_cost_model"] = "ors"
        all_day_rows.append(summary)

        manifest.append(
            {
                "day": day,
                "start_station_name": summary["start_station_name"],
                "end_station_name": summary["end_station_name"],
                "stations": len(ordered),
                "optimization_distance_m": opt_payload["summary"]["distance"],
                "optimization_duration_s": opt_payload["summary"]["duration"],
                "directions_distance_m": route_distance_m,
                "directions_duration_s": route_duration_s,
            }
        )

    write_station_plan(all_station_rows)
    write_day_summary(all_day_rows)
    write_total_summary(all_day_rows)
    write_manifest(manifest)


if __name__ == "__main__":
    main()
