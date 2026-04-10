#!/usr/bin/env python3

import csv
import json
import math
import os
import urllib.request
from collections import defaultdict
from pathlib import Path
from xml.sax.saxutils import escape

INPUT_ROUTE_PLAN = Path("outputs/route_plan_ors/station_route_plan.csv")
INPUT_DAY_SUMMARY = Path("outputs/route_plan_ors/day_route_summary.csv")
OUTPUT_DIR = Path("outputs/super_14_tcx")
START_CABI_OFFSET_M = 160.9

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

def load_env_local():
    path = Path(".env.local")
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line: continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip())

def haversine(lon1, lat1, lon2, lat2):
    radius_m = 6371000.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi, dlambda = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dphi / 2.0) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2.0) ** 2
    return radius_m * 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))

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

def ors_request(url, key, body):
    req = urllib.request.Request(
        url, data=json.dumps(body).encode("utf-8"),
        headers={"Authorization": key, "Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        return json.load(resp)

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

def point_type(step):
    t = step.get("type")
    if t in (0, 4): return "Left"
    if t in (1, 3, 5): return "Right"
    if t in (6, 7): return "Straight"
    return "Generic"

def rewrite_instruction(text):
    text = (text or "").strip()
    if text.lower().startswith("head "): return "Continue " + text[5:]
    return text

def get_street_name(step):
    instruction = (step.get("instruction") or "").strip()
    street = ""
    if " onto " in instruction: street = instruction.split(" onto ", 1)[1].strip()
    elif " on " in instruction: street = instruction.split(" on ", 1)[1].strip()
    else: street = (step.get("name") or "").strip()
    if street.lower() in ("the left", "the right", "the road", "the trail", "straight"): return ""
    return street

def build_course_points(feature, rows, day_summary=None):
    coords = feature["geometry"]["coordinates"]
    segments = feature["properties"]["segments"]
    cps = []
    cumulative = 0.0

    # START Nudge (5m)
    cps.append({
        "distance_m": 5.0, "name": "START", "notes": f"Go to {rows[0]['station_name']}",
        "point_type": "Danger", "lat": coords[0][1], "lon": coords[0][0], "wpt_idx": 0,
    })

    kickoff_note = None
    if day_summary is not None:
        nearest_metro = (day_summary.get("nearest_metro_at_start") or "").strip()
        if nearest_metro:
            kickoff_note = f"Start from {nearest_metro} Metro Station"

    first_maneuver_idx = None
    last_street = ""
    for seg_idx, segment in enumerate(segments):
        step_distance = cumulative
        first_step_added = False
        for step_idx, step in enumerate(segment.get("steps", []), start=1):
            street_name = get_street_name(step)
            if street_name: last_street = street_name
            if step.get("type") in (10, 11):
                step_distance += float(step.get("distance", 0))
                continue
            wpt_idx = step.get("way_points", [0])[0]
            cps.append({
                "distance_m": step_distance, "name": f"Leg {seg_idx+1:02d} Step {step_idx:02d}",
                "notes": rewrite_instruction(step.get("instruction", "")),
                "point_type": point_type(step), "lat": coords[wpt_idx][1], "lon": coords[wpt_idx][0], "wpt_idx": wpt_idx,
            })
            if first_maneuver_idx is None:
                first_maneuver_idx = len(cps) - 1
            first_step_added = True
            step_distance += float(step.get("distance", 0))
            
        if not first_step_added and last_street:
            # Continue Nudge (40m further down track)
            fallback_idx = segment.get("steps", [{"way_points": [0]}])[0].get("way_points", [0])[0]
            new_idx = min(len(coords) - 1, fallback_idx + 10)
            cps.append({
                "distance_m": cumulative + 40.0, "name": f"Leg {seg_idx+1:02d} Continue",
                "notes": f"Continue on {last_street}", "point_type": "Straight",
                "lat": coords[new_idx][1], "lon": coords[new_idx][0], "wpt_idx": fallback_idx,
            })
            if first_maneuver_idx is None:
                first_maneuver_idx = len(cps) - 1
            
        cumulative += float(segment.get("distance", 0))
        cps.append({
            "distance_m": cumulative, "name": f"Station {seg_idx+2:02d}",
            "notes": f"CaBi station: {rows[seg_idx+1]['station_name']}",
            "point_type": "Danger", "lat": rows[seg_idx+1]["_lat"], "lon": rows[seg_idx+1]["_lon"],
            "wpt_idx": segment.get("steps", [])[-1].get("way_points", [0, 0])[1] if segment.get("steps") else len(coords) - 1,
        })

    if kickoff_note and first_maneuver_idx is not None:
        first_note = cps[first_maneuver_idx]["notes"]
        cps[first_maneuver_idx]["notes"] = f"{kickoff_note}. {first_note}"

    return cps

def tcx_text(day, rows, feature, day_summary=None):
    coords = feature["geometry"]["coordinates"]
    course_points = build_course_points(feature, rows, day_summary=day_summary)
    
    # Align track to stations
    for cp in course_points:
        if cp["name"].startswith("Station"):
            idx = cp["wpt_idx"]
            if 0 <= idx < len(coords): coords[idx] = [cp["lon"], cp["lat"]]

    trackpoints, current_dist = [], 0.0
    for idx, coord in enumerate(coords):
        if idx > 0:
            prev = coords[idx-1]
            current_dist += haversine(prev[0], prev[1], coord[0], coord[1])
        for cp in course_points:
            if cp["wpt_idx"] == idx:
                if cp["name"] == "START": cp["distance_m"] = 5.0
                elif "Continue" in cp["name"]: cp["distance_m"] = current_dist + 40.0
                else: cp["distance_m"] = current_dist
        trackpoints.append(
            f"<Trackpoint><Position><LatitudeDegrees>{coord[1]:.6f}</LatitudeDegrees>"
            f"<LongitudeDegrees>{coord[0]:.6f}</LongitudeDegrees></Position>"
            f"<DistanceMeters>{current_dist:.1f}</DistanceMeters></Trackpoint>"
        )

    cps_xml = []
    sorted_cps = sorted(course_points, key=lambda x: x.get("distance_m", 0))
    for idx, cp in enumerate(sorted_cps):
        cps_xml.append(
            f"<CoursePoint><Name>{escape(cp['name'])}</Name>"
            f"<Time>2000-01-01T00:00:{idx%60:02d}Z</Time>"
            f"<Position><LatitudeDegrees>{cp['lat']:.6f}</LatitudeDegrees>"
            f"<LongitudeDegrees>{cp['lon']:.6f}</LongitudeDegrees></Position>"
            f"<DistanceMeters>{cp['distance_m']:.1f}</DistanceMeters>"
            f"<PointType>{escape(cp['point_type'])}</PointType>"
            f"<Notes>{escape(cp['notes'])}</Notes></CoursePoint>"
        )

    course_name = f"Super Day {day:02d}"
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 '
        'http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd">\n'
        '  <Courses><Course>'
        f'    <Name>{escape(course_name)}</Name>'
        f'    <Lap><TotalTimeSeconds>0</TotalTimeSeconds><DistanceMeters>{current_dist:.1f}</DistanceMeters></Lap>'
        f'    <Track>{" ".join(trackpoints)}</Track>'
        f'    {" ".join(cps_xml)}'
        '  </Course></Courses></TrainingCenterDatabase>'
    )

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
        
        out.write_text(tcx_text(sd, rows, feature, day_summary=summary), encoding="utf-8")

if __name__ == "__main__":
    main()
