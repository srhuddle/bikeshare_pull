#!/usr/bin/env python3

import json
import math
import os
import urllib.request
from pathlib import Path
from xml.sax.saxutils import escape


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


def ors_request(url, key, body):
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Authorization": key, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        return json.load(resp)


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

    if street.lower() in ("the left", "the right", "the road", "the trail", "straight"):
        return ""
    return street


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
                "wpt_idx": (
                    segment.get("steps", [])[-1].get("way_points", [0, 0])[1]
                    if segment.get("steps")
                    else len(coords) - 1
                ),
            }
        )
    if kickoff_note and first_maneuver_idx is not None:
        first_note = cps[first_maneuver_idx]["notes"]
        cps[first_maneuver_idx]["notes"] = f"{kickoff_note}. {first_note}"
    return cps


def tcx_text(day_label, rows, feature, day_summary=None, course_name=None):
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
            if cp["wpt_idx"] == idx:
                if cp["name"] == "START":
                    cp["distance_m"] = 5.0
                elif "Continue" in cp["name"]:
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

    course_name = course_name or f"CaBi Day {day_label:02d}"
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
