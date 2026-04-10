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
OUTPUT_DIR = Path("outputs/route_plan_ors_tcx")
START_CABI_OFFSET_M = 16.1


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


def sanitize_name(text):
    out = "".join(ch.lower() if ch.isalnum() else "_" for ch in text.strip())
    while "__" in out:
        out = out.replace("__", "_")
    return out.strip("_")


def haversine(lon1, lat1, lon2, lat2):
    radius_m = 6371000.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = (
        math.sin(dphi / 2.0) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2.0) ** 2
    )
    return radius_m * 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))


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


def ors_request(url, key, body):
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Authorization": key, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        return json.load(resp)


def directions_for_day(key, rows):
    coords = [[row["_lon"], row["_lat"]] for row in rows]
    return ors_request(
        "https://api.openrouteservice.org/v2/directions/cycling-regular/geojson",
        key,
        {"coordinates": coords, "instructions": True},
    )


def point_type(step):
    t = step.get("type")
    if t in (0, 4):
        return "Left"
    if t in (1, 3, 5):
        return "Right"
    if t in (6, 7):
        return "Straight"
    return "Generic"


def rewrite_instruction(text):
    text = (text or "").strip()
    lower = text.lower()
    if lower.startswith("head "):
        return "Continue " + text[5:]
    return text


def get_street_name(step):
    instruction = (step.get("instruction") or "").strip()
    street = ""
    if " onto " in instruction:
        street = instruction.split(" onto ", 1)[1].strip()
    elif " on " in instruction:
        street = instruction.split(" on ", 1)[1].strip()
    else:
        street = (step.get("name") or "").strip()
    
    # Filter out generic instructions that aren't street names
    if street.lower() in ("the left", "the right", "the road", "the trail", "straight"):
        return ""
    return street


def station_points(rows):
    return [
        {
            "distance_m": None,
            "name": f"Station {idx:02d}",
            "notes": f"CaBi station: {row['station_name']}",
            "point_type": "Danger",
            "lat": row["_lat"],
            "lon": row["_lon"],
        }
        for idx, row in enumerate(rows, start=1)
    ]


def build_course_points(feature, rows, day_summary=None):
    coords = feature["geometry"]["coordinates"]
    segments = feature["properties"]["segments"]
    cps = []
    cumulative = 0.0

    cps.append(
        {
            "distance_m": 0.0,
            "name": "START",
            "notes": f"Go to {rows[0]['station_name']}",
            "point_type": "Danger",
            "lat": coords[0][1],
            "lon": coords[0][0],
            "wpt_idx": 0,
        }
    )

    cps.append(
        {
            "distance_m": START_CABI_OFFSET_M,
            "name": "Station 01",
            "notes": f"CaBi station: {rows[0]['station_name']}",
            "point_type": "Danger",
            "lat": rows[0]["_lat"],
            "lon": rows[0]["_lon"],
            "wpt_idx": 2 if len(coords) > 2 else (1 if len(coords) > 1 else 0),
        }
    )

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
            if street_name:
                last_street = street_name
            if step.get("type") in (10, 11):
                step_distance += float(step.get("distance", 0))
                continue
            wpt_idx = step.get("way_points", [0])[0]
            coord = coords[wpt_idx]
            cps.append(
                {
                    "distance_m": step_distance,
                    "name": f"Leg {seg_idx+1:02d} Step {step_idx:02d}",
                    "notes": rewrite_instruction(step.get("instruction", "")),
                    "point_type": point_type(step),
                    "lat": coord[1],
                    "lon": coord[0],
                    "wpt_idx": wpt_idx,
                }
            )
            if first_maneuver_idx is None:
                first_maneuver_idx = len(cps) - 1
            first_step_added = True
            step_distance += float(step.get("distance", 0))
        if not first_step_added and last_street:
            fallback_idx = segment.get("steps", [{"way_points": [0]}])[0].get("way_points", [0])[0]
            cps.append(
                {
                    "distance_m": cumulative + 2.0,
                    "name": f"Leg {seg_idx+1:02d} Continue",
                    "notes": f"Continue on {last_street}",
                    "point_type": "Straight",
                    "lat": coords[fallback_idx][1],
                    "lon": coords[fallback_idx][0],
                    "wpt_idx": fallback_idx,
                }
            )
            if first_maneuver_idx is None:
                first_maneuver_idx = len(cps) - 1
        cumulative += float(segment.get("distance", 0))
        cps.append(
            {
                "distance_m": cumulative,
                "name": f"Station {seg_idx+2:02d}",
                "notes": f"CaBi station: {rows[seg_idx+1]['station_name']}",
                "point_type": "Danger",
                "lat": rows[seg_idx+1]["_lat"],
                "lon": rows[seg_idx+1]["_lon"],
                "wpt_idx": segment.get("steps", [])[-1].get("way_points", [0, 0])[1] if segment.get("steps") else len(coords) - 1,
            }
        )
    if kickoff_note and first_maneuver_idx is not None:
        first_note = cps[first_maneuver_idx]["notes"]
        cps[first_maneuver_idx]["notes"] = f"{kickoff_note}. {first_note}"
    return cps


def tcx_text(day, rows, feature, day_summary=None):
    coords = feature["geometry"]["coordinates"]
    course_points = build_course_points(feature, rows, day_summary=day_summary)

    for cp in course_points:
        if cp["name"].startswith("Station"):
            idx = cp["wpt_idx"]
            if 0 <= idx < len(coords):
                coords[idx] = [cp["lon"], cp["lat"]]

    trackpoints = []
    current_dist = 0.0
    for idx, coord in enumerate(coords):
        if idx > 0:
            prev = coords[idx - 1]
            current_dist += haversine(prev[0], prev[1], coord[0], coord[1])

        for cp in course_points:
            # Advance "Continue" cues a few waypoints down the track to avoid Lat/Lon overlap with stations
            target_idx = idx
            if "Continue" in cp["name"]:
                target_idx = max(0, cp["wpt_idx"] - 5) # Match logic below
            
            if cp["wpt_idx"] == idx:
                if cp["name"] == "START":
                    cp["distance_m"] = 5.0
                elif "Continue" in cp["name"]:
                    # Physically move the cue 10 points down the track to avoid overlap
                    shift = 10
                    new_idx = min(len(coords) - 1, idx + shift)
                    coord_shift = coords[new_idx]
                    cp["lat"] = coord_shift[1]
                    cp["lon"] = coord_shift[0]
                    cp["distance_m"] = current_dist + 40.0
                    cp["point_type"] = "Straight"
                else:
                    cp["distance_m"] = current_dist

        trackpoints.append(
            "<Trackpoint><Position>"
            f"<LatitudeDegrees>{coord[1]:.6f}</LatitudeDegrees>"
            f"<LongitudeDegrees>{coord[0]:.6f}</LongitudeDegrees>"
            "</Position>"
            f"<DistanceMeters>{current_dist:.1f}</DistanceMeters>"
            "</Trackpoint>"
        )

    cps = []
    # IMPORTANT: TCX CoursePoints must be sorted by distance_m or they will be ignored by RideWithGPS
    sorted_course_points = sorted(course_points, key=lambda x: x.get("distance_m", 0))
    for idx, cp in enumerate(sorted_course_points):
        cps.append(
            "<CoursePoint>"
            f"<Name>{escape(cp['name'])}</Name>"
            f"<Time>2000-01-01T00:00:{idx%60:02d}Z</Time>"
            "<Position>"
            f"<LatitudeDegrees>{cp['lat']:.6f}</LatitudeDegrees>"
            f"<LongitudeDegrees>{cp['lon']:.6f}</LongitudeDegrees>"
            "</Position>"
            f"<DistanceMeters>{cp['distance_m']:.1f}</DistanceMeters>"
            f"<PointType>{escape(cp['point_type'])}</PointType>"
            f"<Notes>{escape(cp['notes'])}</Notes>"
            "</CoursePoint>"
        )

    course_name = f"CaBi Day {day:02d}"
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 '
        'http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd">\n'
        "  <Courses>\n"
        "    <Course>\n"
        f"      <Name>{escape(course_name)}</Name>\n"
        "      <Lap>\n"
        "        <TotalTimeSeconds>0</TotalTimeSeconds>\n"
        f"        <DistanceMeters>{current_dist:.1f}</DistanceMeters>\n"
        "      </Lap>\n"
        "      <Track>\n"
        f"        {' '.join(trackpoints)}\n"
        "      </Track>\n"
        f"      {' '.join(cps)}\n"
        "    </Course>\n"
        "  </Courses>\n"
        "</TrainingCenterDatabase>\n"
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
