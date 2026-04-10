#!/usr/bin/env python3

import csv
import os
from collections import defaultdict
from pathlib import Path

from route_export_common import load_env_local, ors_request, tcx_text

INPUT_ROUTE_PLAN = Path("outputs/route_plan_ors/station_route_plan.csv")
INPUT_DAY_SUMMARY = Path("outputs/route_plan_ors/day_route_summary.csv")
OUTPUT_DIR = Path("outputs/super_14_tcx")

# Mapping of Super-Day (1-14) to original Day IDs
SUPER_DAY_MAPPING = {
    1: [1],
    2: [3, 4],
    3: [2, 7],
    4: [5, 10],
    5: [12, 13],
    6: [6, 8],
    7: [15, 26],
    8: [14, 17],
    9: [11, 18],
    10: [19, 16],
    11: [9, 20],
    12: [21, 23],
    13: [25, 27],
    14: [28, 22, 24]
}

def load_day_summaries():
    summaries = {}
    if not INPUT_DAY_SUMMARY.exists(): return summaries
    with INPUT_DAY_SUMMARY.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader: summaries[int(float(row["day"]))] = dict(row)
    return summaries

def load_super_days():
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
    
    super_days = {}
    for sd, original_days in SUPER_DAY_MAPPING.items():
        combined_rows = []
        for d in original_days:
            if d in by_day:
                day_rows = sorted(by_day[d], key=lambda r: r["_visit_order"])
                combined_rows.extend(day_rows)
        if combined_rows:
            super_days[sd] = combined_rows
    return super_days

def directions_split(key, rows):
    coords = [[row["_lon"], row["_lat"]] for row in rows]
    # ORS limit is 50 waypoints. Split and stitch.
    CHUNK_SIZE = 45 
    all_features = []
    
    for i in range(0, len(coords)-1, CHUNK_SIZE-1):
        chunk = coords[i : i + CHUNK_SIZE]
        if len(chunk) < 2: break
        resp = ors_request(
            "https://api.openrouteservice.org/v2/directions/cycling-regular/geojson",
            key, {"coordinates": chunk, "instructions": True}
        )
        all_features.append(resp["features"][0])
    
    # Stitch features
    base = all_features[0]
    for other in all_features[1:]:
        # Offset waypoint indices in steps
        coord_offset = len(base["geometry"]["coordinates"]) - 1
        base["geometry"]["coordinates"].extend(other["geometry"]["coordinates"][1:])
        
        for seg in other["properties"]["segments"]:
            for step in seg["steps"]:
                step["way_points"] = [wp + coord_offset for wp in step["way_points"]]
            base["properties"]["segments"].append(seg)
            
    # Update summary
    total_dist = sum(f["properties"]["summary"]["distance"] for f in all_features)
    total_dur = sum(f["properties"]["summary"]["duration"] for f in all_features)
    base["properties"]["summary"]["distance"] = total_dist
    base["properties"]["summary"]["duration"] = total_dur
    
    return {"features": [base]}

def main():
    load_env_local()
    key = os.environ.get("OPENROUTESERVICE_API_KEY")
    if not key: raise RuntimeError("OPENROUTESERVICE_API_KEY missing")
    
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    super_days = load_super_days()
    day_summaries = load_day_summaries()
    
    for sd in sorted(super_days):
        rows = super_days[sd]
        print(f"Generating Super Day {sd:02d} ({len(rows)} stations)...")
        feature = directions_split(key, rows)["features"][0]
        out = OUTPUT_DIR / f"super_day_{sd:02d}.tcx"
        
        # Use first original day's summary for the kickoff note
        original_days = SUPER_DAY_MAPPING.get(sd, [])
        first_day = original_days[0] if original_days else None
        summary = day_summaries.get(first_day) if first_day else None
        
        out.write_text(
            tcx_text(
                sd,
                rows,
                feature,
                day_summary=summary,
                course_name=f"Super Day {sd:02d}",
            ),
            encoding="utf-8",
        )

if __name__ == "__main__":
    main()
