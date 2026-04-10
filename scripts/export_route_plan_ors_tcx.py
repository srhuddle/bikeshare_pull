import csv
import json
import os
from collections import defaultdict
from pathlib import Path
from route_export_common import load_env_local, ors_request, tcx_text


INPUT_ROUTE_PLAN = Path("outputs/route_plan_ors/station_route_plan.csv")
INPUT_DAY_SUMMARY = Path("outputs/route_plan_ors/day_route_summary.csv")
OUTPUT_DIR = Path("outputs/route_plan_ors_tcx")


def sanitize_name(text):
    out = "".join(ch.lower() if ch.isalnum() else "_" for ch in text.strip())
    while "__" in out:
        out = out.replace("__", "_")
    return out.strip("_")


def load_days():
    by_day = defaultdict(list)
    with INPUT_ROUTE_PLAN.open(newline="", encoding="utf-8") as f:
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


def load_day_summaries():
    summaries = {}
    if not INPUT_DAY_SUMMARY.exists():
        return summaries
    with INPUT_DAY_SUMMARY.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            summaries[int(float(row["day"]))] = dict(row)
    return summaries
def directions_for_day(key, rows):
    coords = [[row["_lon"], row["_lat"]] for row in rows]
    return ors_request(
        "https://api.openrouteservice.org/v2/directions/cycling-regular/geojson",
        key,
        {"coordinates": coords, "instructions": True},
    )
def main():
    load_env_local()
    key = os.environ.get("OPENROUTESERVICE_API_KEY")
    if not key:
        raise RuntimeError("OPENROUTESERVICE_API_KEY missing")
    day_filter = os.environ.get("ROUTE_PLAN_DAY")
    day_filter = int(day_filter) if day_filter and day_filter.strip() else None
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    days = load_days()
    day_summaries = load_day_summaries()

    manifest = []
    for day in sorted(days):
        if day_filter is not None and day != day_filter:
            continue
        rows = days[day]
        feature = directions_for_day(key, rows)["features"][0]
        start_name = sanitize_name(rows[0]["station_name"])

        tcx_out = OUTPUT_DIR / f"day_{day:02d}_{start_name}.tcx"
        tcx_out.write_text(tcx_text(day, rows, feature, day_summary=day_summaries.get(day)), encoding="utf-8")

        manifest.append(
            {
                "day": day,
                "tcx_file": str(tcx_out),
                "stations": len(rows),
                "distance_m": feature["properties"]["summary"]["distance"],
                "duration_s": feature["properties"]["summary"]["duration"],
            }
        )

    (OUTPUT_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
