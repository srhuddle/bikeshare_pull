#!/usr/bin/env python3

import argparse
import csv
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path


TCX_NS = {"tcx": "http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"}
STATION_RE = re.compile(r"^Station\s+(\d+)\b")


def parse_args():
    parser = argparse.ArgumentParser(description="Export a CaBi app route JSON from route plan CSV + TCX.")
    parser.add_argument("--day", type=int, required=True, help="Route day number to export")
    parser.add_argument(
        "--route-plan",
        default="outputs/route_plan/station_route_plan.csv",
        help="Station route plan CSV path",
    )
    parser.add_argument(
        "--tcx",
        required=True,
        help="TCX path for the day",
    )
    parser.add_argument(
        "--out",
        required=True,
        help="Output JSON path",
    )
    return parser.parse_args()


def load_stations(route_plan_path, day):
    stations = []
    with Path(route_plan_path).open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            if int(row["day"]) != day:
                continue
            stations.append(
                {
                    "station_id": row["station_id"],
                    "name": row["station_name"],
                    "lat": float(row["lat"]),
                    "lng": float(row["lon"]),
                    "visit_order": int(row["visit_order"]),
                }
            )
    stations.sort(key=lambda row: row["visit_order"])
    return stations


def load_tcx(tcx_path):
    root = ET.parse(tcx_path).getroot()
    course = root.find("tcx:Courses/tcx:Course", TCX_NS)
    if course is None:
        raise RuntimeError(f"No TCX course found in {tcx_path}")

    course_name = course.findtext("tcx:Name", default="", namespaces=TCX_NS)

    track = []
    for tp in course.findall("tcx:Track/tcx:Trackpoint", TCX_NS):
        pos = tp.find("tcx:Position", TCX_NS)
        if pos is None:
            continue
        track.append(
            {
                "lat": float(pos.findtext("tcx:LatitudeDegrees", default="0", namespaces=TCX_NS)),
                "lng": float(pos.findtext("tcx:LongitudeDegrees", default="0", namespaces=TCX_NS)),
                "distance_m": float(tp.findtext("tcx:DistanceMeters", default="0", namespaces=TCX_NS)),
            }
        )

    course_points = []
    for cp in course.findall("tcx:CoursePoint", TCX_NS):
        pos = cp.find("tcx:Position", TCX_NS)
        if pos is None:
            continue
        course_points.append(
            {
                "name": cp.findtext("tcx:Name", default="", namespaces=TCX_NS),
                "text": cp.findtext("tcx:Notes", default="", namespaces=TCX_NS),
                "point_type": cp.findtext("tcx:PointType", default="", namespaces=TCX_NS),
                "lat": float(pos.findtext("tcx:LatitudeDegrees", default="0", namespaces=TCX_NS)),
                "lng": float(pos.findtext("tcx:LongitudeDegrees", default="0", namespaces=TCX_NS)),
                "distance_m": float(cp.findtext("tcx:DistanceMeters", default="0", namespaces=TCX_NS)),
            }
        )

    return course_name, track, course_points


def build_cues_by_target(course_points, station_count):
    station_cp_indices = {}
    for idx, cp in enumerate(course_points):
        match = STATION_RE.match(cp["name"])
        if match:
            station_number = int(match.group(1))
            station_cp_indices[station_number] = idx

    cues_by_target = {}
    for station_number in range(1, station_count):
        start_idx = station_cp_indices.get(station_number)
        end_idx = station_cp_indices.get(station_number + 1)
        if start_idx is None or end_idx is None or end_idx <= start_idx:
            continue

        target_idx = station_number
        cues = []
        for cue_idx, cp in enumerate(course_points[start_idx + 1 : end_idx + 1], start=1):
            cues.append(
                {
                    "id": f"d{station_number:02d}_{cue_idx:02d}",
                    "text": cp["text"],
                    "lat": cp["lat"],
                    "lng": cp["lng"],
                    "distance_m": cp["distance_m"],
                    "point_type": cp["point_type"],
                }
            )
        cues_by_target[str(target_idx)] = cues

    return cues_by_target


def main():
    args = parse_args()
    stations = load_stations(args.route_plan, args.day)
    if not stations:
        raise RuntimeError(f"No stations found for day {args.day}")

    course_name, track, course_points = load_tcx(args.tcx)
    cues_by_target = build_cues_by_target(course_points, len(stations))

    payload = {
        "name": course_name or f"CaBi Day {args.day:02d}",
        "day": args.day,
        "stations": [
            {"station_id": s["station_id"], "name": s["name"], "lat": s["lat"], "lng": s["lng"]}
            for s in stations
        ],
        "track": track,
        "cuesByTarget": cues_by_target,
        "metadata": {
            "source_tcx": str(args.tcx),
            "source_route_plan": str(args.route_plan),
            "station_count": len(stations),
            "trackpoint_count": len(track),
            "coursepoint_count": len(course_points),
        },
    }

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
