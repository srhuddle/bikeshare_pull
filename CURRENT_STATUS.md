# Current Status

This file is a lightweight handoff snapshot for continuing work on another machine or in a new Codex session.

## Read First

1. `AGENTS.md`
2. `OPERATIONS.md`
3. `README.md`

## User Preferences

- For operational setup or maintenance, proceed one step at a time and wait for confirmation.
- Default to doing terminal and file actions directly unless UI interaction, credentials, or approval are required.

## Project State

- Main working inventory file:
  - `station_inventory_scoring.csv`
- Weekly baseline:
  - `known_station_inventory.csv`
- Project-local Metro CSV:
  - `data/metro_stations_regional.csv`

## OSRM State

- Docker Desktop installed and working on the source machine
- Local OSRM extract present:
  - `data/osrm/dc-metro-region.osm.pbf`
- Processed OSRM files were built successfully in `data/osrm/`
- Local OSRM server was started successfully on port `5001`
- Health check succeeded for:
  - `http://localhost:5001/nearest/v1/cycling/-77.0434,38.9096`

Note:
- On a new machine, Docker may need to be installed again
- If processed `data/osrm/*.osrm*` files are already synced, only the OSRM server needs to be started

## Planner State

- `cabi_route_planner.R` supports:
  - haversine fallback cost model
  - OSRM route-time cost model
  - Metro accessibility scoring
  - Dupont Circle home anchor defaults
  - total day time estimation
  - day-cap scoring with `ROUTE_PLAN_MAX_TOTAL_DAY_MINUTES`
  - a first post-cluster repair pass

- `cabi_visit_map_app.R` supports:
  - selected-day route overlay
  - all-days route overlay
  - route summary text including estimated total time and route cost model

## Routing Rules Of The Road

- Start/end access should be treated as a strong soft constraint, not a strict Metro-only hard rule.
- Operational intent:
  - each route day should start and end at a station with reasonable access from Dupont Circle and/or Metro
  - routes should not be optimized into awkward waterfront or remote endpoints just to save a small amount of biking
- Working endpoint policy:
  - preferred endpoint access: within roughly `10-15` minutes
  - acceptable endpoint access: up to roughly `20` minutes
  - heavily penalize endpoint access beyond `20` minutes
  - avoid endpoint access around `45` minutes; treat that as operationally unacceptable except for deliberate remote-pocket exceptions
- Interpretation:
  - this is a soft optimization rule with a steep penalty curve, not a binary feasibility rule
  - Dupont Circle remains an allowed home-anchor special case alongside Metro-adjacent endpoints
- TCX station cue convention:
  - turn-by-turn TCX exports should include station markers as `CoursePoint`s with notes in the form `CaBi station: <station name>`
  - this note format was confirmed to render clearly in Ride with GPS cue lists
  - station markers should be additive to turn cues, not a replacement for them
  - avoid generic `Arrive` / `Depart` station phrasing when the goal is RWGPS visibility; prefer the explicit `CaBi station: ...` note text

## Latest Planner Run

Latest successful OSRM run used roughly:

```bash
ROUTE_PLAN_COST_MODEL=osrm
ROUTE_PLAN_OSRM_URL=http://localhost:5001
ROUTE_PLAN_OSRM_PROFILE=cycling
ROUTE_PLAN_METRO_FILE=data/metro_stations_regional.csv
ROUTE_PLAN_TARGET_STATIONS_PER_DAY=30
ROUTE_PLAN_MAX_TOTAL_DAY_MINUTES=300
ROUTE_PLAN_WRITE_MAPS=false
```

Current outputs:
- `outputs/route_plan/station_route_plan.csv`
- `outputs/route_plan/day_route_summary.csv`
- `outputs/route_plan/total_route_summary.csv`
- `outputs/route_plan/weak_transit_exits.csv`

## Current Best Baseline

Original preserved baseline on `2026-04-08`:
- Snapshot folder:
  - `outputs/route_plan_current_best_2026-04-08/`
- Metrics:
  - `planned_stations = 820`
  - `planned_days = 28`
  - `total_route_distance_mi = 448.34`
  - `total_estimated_bike_minutes = 3721.75`
  - `total_estimated_day_minutes = 4833.47`

Improved total-time run on `2026-04-08`:
- Snapshot folder:
  - `outputs/route_plan_current_best_2026-04-08_total_time/`
- Frozen files:
  - `outputs/route_plan_current_best_2026-04-08_total_time/station_route_plan.csv`
  - `outputs/route_plan_current_best_2026-04-08_total_time/day_route_summary.csv`
  - `outputs/route_plan_current_best_2026-04-08_total_time/total_route_summary.csv`
  - `outputs/route_plan_current_best_2026-04-08_total_time/weak_transit_exits.csv`
- Metrics:
  - `planned_stations = 820`
  - `planned_days = 28`
  - `total_route_distance_mi = 449.67`
  - `total_estimated_bike_minutes = 3730.68`
  - `total_estimated_day_minutes = 4827.82`
  - `smallest_day_stations = 4`
  - `largest_day_stations = 45`

Comparison vs original baseline:
- `total_estimated_day_minutes = -5.65`
- `total_estimated_bike_minutes = +8.94`
- `total_route_distance_mi = +1.33`

Interpretation:
- The primary optimization target is now explicitly `total_estimated_day_minutes`.
- The improved run beats the original baseline slightly by reducing commute/access time enough to offset slightly worse biking.

## Known Remaining Issues

The routing quality is materially better with OSRM, but a few local boundary artifacts may still remain.

Known examples:
- Day 6 / Day 15:
  - Montgomery still deserves review for whether `North Bethesda Metro` is best kept with the Rockville/Twinbrook day or shifted toward the Silver Spring / Wheaton side
- Global:
  - the repair pass now targets total day minutes directly, but improvement so far is modest, so larger gains probably require day-count or remote-pocket tradeoff changes rather than more local boundary cleanup

Interpretation:
- remaining opportunities are now mainly targeted boundary / objective-function improvements, not broad route-order problems

## Cleanup Already Done

- Top-level backup clutter was moved into `Archive/backups/`
- Main top-level inventory files now kept in place:
  - `station_inventory_scoring.csv`
  - `known_station_inventory.csv`

## Good Prompt For Next Codex Session

Use something like:

```text
Continue work on the Capital Bikeshare route-planning project in this repo.

Read these first:
- AGENTS.md
- OPERATIONS.md
- CURRENT_STATUS.md
- README.md

Start by summarizing the current project state from the repo and identifying the next best clustering improvement step.
```
